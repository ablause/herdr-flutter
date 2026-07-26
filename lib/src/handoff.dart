import 'dart:io';

import 'herdr_cli.dart';

/// Why a handoff to the agent could not happen.
enum HandoffRefusal { noAgent, several, failed }

class HandoffResult {
  HandoffResult.sent(this.agentPaneId, this.reportPath)
    : refusal = null,
      message = null;
  HandoffResult.refused(this.refusal, this.message, {this.reportPath})
    : agentPaneId = null;

  final String? agentPaneId;
  final String? reportPath;
  final HandoffRefusal? refusal;
  final String? message;

  bool get sent => refusal == null;
}

/// The agent pane a report should go to.
///
/// The sole agent in the sidebar's own tab wins; otherwise the sole agent in
/// its workspace. Zero or several candidates refuse, because guessing would put
/// a report in the wrong conversation. Panes without an `agent` field are not
/// candidates, and the sidebar never targets itself.
PaneInfo? pickAgent(
  List<PaneInfo> panes, {
  String? tabId,
  String? workspaceId,
  String? selfPaneId,
}) {
  // Tab ids are workspace-scoped in herdr, but matching the workspace as well
  // keeps a foreign pane from ever being a candidate.
  List<PaneInfo> scope(String? want, String Function(PaneInfo) id) {
    if (want == null) return const [];
    return panes
        .where((pane) => pane.isAgent)
        .where((pane) => id(pane) == want)
        .where((pane) => workspaceId == null || pane.workspaceId == workspaceId)
        .where((pane) => pane.paneId != selfPaneId)
        .toList();
  }

  final inTab = scope(tabId, (pane) => pane.tabId);
  if (inTab.length == 1) return inTab.single;
  final inWorkspace = scope(workspaceId, (pane) => pane.workspaceId);
  if (inWorkspace.length == 1) return inWorkspace.single;
  return null;
}

/// Writes reports and hands them to the agent beside the sidebar.
///
/// The report goes to a file and the agent's input gets a single line pointing
/// at it. A multi-line paste would submit itself on the first newline, and a
/// stack trace with a widget subtree is far too long to sit in a prompt box.
class Handoff {
  Handoff(this.cli, {String? stateDir, Map<String, String>? env})
    : _stateDir =
          stateDir ??
          (env ?? Platform.environment)['HERDR_PLUGIN_STATE_DIR'] ??
          Directory.systemTemp.path;

  final HerdrCli cli;
  final String _stateDir;

  Directory get reportDir => Directory('$_stateDir/reports');

  /// Store [markdown] and return its path.
  File writeReport(String slug, String markdown, {DateTime? now}) {
    final stamp = _stamp(now ?? DateTime.now());
    reportDir.createSync(recursive: true);
    final file = File('${reportDir.path}/$stamp-$slug.md');
    file.writeAsStringSync(markdown);
    _prune();
    return file;
  }

  /// Keep the last 50 reports so the state dir cannot grow without bound.
  void _prune() {
    if (!reportDir.existsSync()) return;
    final files =
        reportDir
            .listSync()
            .whereType<File>()
            .where((file) => file.path.endsWith('.md'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    for (final file in files.take(
      files.length - 50 < 0 ? 0 : files.length - 50,
    )) {
      try {
        file.deleteSync();
      } on FileSystemException {
        continue;
      }
    }
  }

  static String _stamp(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}${two(time.month)}${two(time.day)}'
        '-${two(time.hour)}${two(time.minute)}${two(time.second)}';
  }

  /// Write the report, put a one-line pointer in the agent's input, focus it.
  Future<HandoffResult> send({
    required String slug,
    required String headline,
    required String markdown,
  }) async {
    final File file;
    try {
      file = writeReport(slug, markdown);
    } on FileSystemException catch (error) {
      return HandoffResult.refused(HandoffRefusal.failed, error.message);
    }

    final List<PaneInfo> panes;
    try {
      panes = await cli.panes();
    } on HerdrCliException catch (error) {
      return HandoffResult.refused(
        HandoffRefusal.failed,
        error.message,
        reportPath: file.path,
      );
    }

    final agent = pickAgent(
      panes,
      tabId: cli.selfTabId,
      workspaceId: cli.selfWorkspaceId,
      selfPaneId: cli.selfPaneId,
    );
    if (agent == null) {
      final anyAgent = panes.any(
        (pane) => pane.isAgent && pane.workspaceId == cli.selfWorkspaceId,
      );
      return HandoffResult.refused(
        anyAgent ? HandoffRefusal.several : HandoffRefusal.noAgent,
        anyAgent
            ? 'several agents in this workspace, cannot choose'
            : 'no agent pane beside this sidebar',
        reportPath: file.path,
      );
    }

    final prompt = '${_oneLine(headline)} Full capture: ${file.path}';
    try {
      await cli.sendText(agent.paneId, prompt);
      await cli.focusPane(agent.paneId);
    } on HerdrCliException catch (error) {
      return HandoffResult.refused(
        HandoffRefusal.failed,
        error.message,
        reportPath: file.path,
      );
    }
    return HandoffResult.sent(agent.paneId, file.path);
  }

  static String _oneLine(String text) {
    final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (flat.length <= 240) return flat;
    return '${flat.substring(0, 237)}...';
  }
}

/// Copy [text] to the OS clipboard. Returns an error message, or null.
Future<String?> copyToClipboard(String text) async {
  final candidates = Platform.isMacOS
      ? [
          ['pbcopy'],
        ]
      : [
          ['wl-copy'],
          ['xclip', '-selection', 'clipboard'],
          ['xsel', '--clipboard', '--input'],
        ];
  for (final command in candidates) {
    try {
      final process = await Process.start(
        command.first,
        command.skip(1).toList(),
      );
      process.stdin.write(text);
      await process.stdin.close();
      if (await process.exitCode == 0) return null;
    } on ProcessException {
      continue;
    }
  }
  return 'no clipboard utility available';
}
