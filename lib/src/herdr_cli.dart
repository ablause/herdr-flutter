import 'dart:convert';
import 'dart:io';

/// Thrown when the herdr CLI is missing or answers with an error envelope.
class HerdrCliException implements Exception {
  HerdrCliException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A pane as `herdr pane list` reports it.
class PaneInfo {
  PaneInfo({
    required this.paneId,
    required this.tabId,
    required this.workspaceId,
    required this.cwd,
    required this.foregroundCwd,
    required this.title,
    required this.label,
    required this.agent,
  });

  factory PaneInfo.fromJson(Map<String, Object?> json) => PaneInfo(
    paneId: json['pane_id'] as String? ?? '',
    tabId: json['tab_id'] as String? ?? '',
    workspaceId: json['workspace_id'] as String? ?? '',
    cwd: json['cwd'] as String? ?? '',
    foregroundCwd: json['foreground_cwd'] as String? ?? '',
    title: json['terminal_title_stripped'] as String? ??
        json['terminal_title'] as String? ??
        '',
    label: json['label'] as String?,
    agent: json['agent'] as String?,
  );

  final String paneId;
  final String tabId;
  final String workspaceId;
  final String cwd;
  final String foregroundCwd;
  final String title;

  /// The plugin-pane label herdr assigns from the entrypoint title.
  final String? label;

  /// Set only on panes hosting a coding agent.
  final String? agent;

  bool get isAgent => agent != null;
}

/// The herdr side of the plugin: the CLI calls the sidebar needs.
///
/// Every call goes through the `herdr` binary rather than the control socket,
/// because the CLI is the documented surface and it is what herdr puts on
/// `HERDR_BIN_PATH` for plugin processes.
class HerdrCli {
  HerdrCli({String? binPath, Map<String, String>? env})
      : _env = env ?? Platform.environment,
        _bin = binPath ??
            (env ?? Platform.environment)['HERDR_BIN_PATH'] ??
            'herdr';

  final String _bin;
  final Map<String, String> _env;

  String? get selfPaneId => _env['HERDR_PANE_ID'];
  String? get selfTabId => _env['HERDR_TAB_ID'];
  String? get selfWorkspaceId => _env['HERDR_WORKSPACE_ID'];

  /// True when the sidebar runs outside herdr, where every call below fails.
  bool get available => _env['HERDR_BIN_PATH'] != null || _which(_bin);

  static bool _which(String bin) {
    if (bin.contains('/')) return File(bin).existsSync();
    final result = Process.runSync('sh', ['-c', 'command -v $bin']);
    return result.exitCode == 0;
  }

  Future<Map<String, Object?>> _json(List<String> args) async {
    final result = await Process.run(_bin, args);
    final stdoutText = (result.stdout as String).trim();
    if (stdoutText.isEmpty) {
      final stderrText = (result.stderr as String).trim();
      throw HerdrCliException(
        'herdr ${args.join(' ')} returned nothing'
        '${stderrText.isEmpty ? '' : ': $stderrText'}',
      );
    }
    final Object? decoded = jsonDecode(stdoutText.split('\n').last);
    if (decoded is! Map<String, Object?>) {
      throw HerdrCliException('herdr ${args.join(' ')} returned unexpected JSON');
    }
    final Object? error = decoded['error'];
    if (error is Map<String, Object?>) {
      throw HerdrCliException(
        'herdr ${args.join(' ')}: ${error['message'] ?? error['code']}',
      );
    }
    return decoded;
  }

  /// Every pane herdr knows about, in every workspace.
  Future<List<PaneInfo>> panes() async {
    final envelope = await _json(['pane', 'list']);
    return parsePanes(envelope);
  }

  /// Terminal output of a pane, newest lines last.
  Future<String> readPane(String paneId, {int lines = 2000}) async {
    final result = await Process.run(_bin, [
      'pane',
      'read',
      paneId,
      '--source',
      'recent-unwrapped',
      '--lines',
      '$lines',
      '--format',
      'text',
    ]);
    if (result.exitCode != 0) {
      throw HerdrCliException('herdr pane read $paneId failed');
    }
    return result.stdout as String;
  }

  /// Write literal text into a pane, without a trailing newline.
  ///
  /// This is how both the hot reload keystroke and the agent handoff land: it
  /// never submits, so an agent pane keeps the text in its input.
  Future<void> sendText(String paneId, String text) async {
    final result = await Process.run(_bin, ['pane', 'send-text', paneId, text]);
    if (result.exitCode != 0) {
      throw HerdrCliException('herdr pane send-text $paneId failed');
    }
    final stdoutText = (result.stdout as String).trim();
    if (stdoutText.startsWith('{') && stdoutText.contains('"error"')) {
      throw HerdrCliException('herdr pane send-text $paneId: $stdoutText');
    }
  }

  Future<void> focusPane(String paneId) async {
    await Process.run(_bin, ['agent', 'focus', paneId]);
  }
}

/// Panes out of a `herdr pane list` envelope. Split out for testing.
List<PaneInfo> parsePanes(Map<String, Object?> envelope) {
  final result = envelope['result'];
  if (result is! Map<String, Object?>) return const [];
  final panes = result['panes'];
  if (panes is! List) return const [];
  return panes
      .whereType<Map<String, Object?>>()
      .map(PaneInfo.fromJson)
      .where((pane) => pane.paneId.isNotEmpty)
      .toList();
}
