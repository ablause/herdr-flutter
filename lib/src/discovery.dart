import 'herdr_cli.dart';

/// A running Flutter app the sidebar can attach to.
class AppTarget {
  AppTarget({
    required this.serviceUri,
    this.deviceName,
    this.ownerPaneId,
    this.ownerTitle,
    this.origin = 'pane',
  });

  /// The Dart VM Service HTTP URI, as `flutter run` prints it.
  final Uri serviceUri;

  /// The device name from the same line, when it carried one.
  final String? deviceName;

  /// The pane whose `flutter run` owns the app.
  ///
  /// Hot reload and hot restart are keystrokes on that pane's stdin, so without
  /// an owner the sidebar can watch and inspect but not reload.
  final String? ownerPaneId;
  final String? ownerTitle;

  /// Where the URI came from: a pane's output, or the plugin config.
  final String origin;

  String get label {
    final device = deviceName;
    if (device != null && device.isNotEmpty) return device;
    final title = ownerTitle;
    if (title != null && title.isNotEmpty) return title;
    return '${serviceUri.host}:${serviceUri.port}';
  }

  @override
  String toString() => '$label ($serviceUri)';
}

/// One VM Service announcement found in terminal output.
class ServiceAnnouncement {
  ServiceAnnouncement(this.uri, this.deviceName);

  final Uri uri;
  final String? deviceName;
}

// Case is not part of the wording: the flutter tool prints `Dart VM Service`
// where the VM itself prints `Dart VM service`, and both reach a pane.
final _announcementPatterns = <RegExp>[
  // flutter run, the common case: device name and http URI on one line. The URI
  // is kept exactly as printed, trailing slash included: the websocket path is
  // derived from it, and rewriting it would break the connection.
  RegExp(
    r'(?:A|The) Dart VM Service on (.+?) is available at:\s*(https?://\S+)',
    multiLine: true,
    caseSensitive: false,
  ),
  // dart run and flutter test: no device name.
  RegExp(
    r'The Dart VM Service is listening on\s*(https?://\S+)',
    multiLine: true,
    caseSensitive: false,
  ),
  // flutter run -d chrome announces the websocket directly.
  RegExp(
    r'Debug service listening on\s*(wss?://\S+)',
    multiLine: true,
    caseSensitive: false,
  ),
];

/// The most recent VM Service announcement in `output`, or null.
///
/// A pane that ran several apps in a row keeps every announcement in its
/// scrollback, so the last one wins.
ServiceAnnouncement? extractAnnouncement(String output) {
  ServiceAnnouncement? best;
  var bestEnd = -1;
  for (final (index, pattern) in _announcementPatterns.indexed) {
    for (final match in pattern.allMatches(output)) {
      if (match.end <= bestEnd) continue;
      final hasDevice = index == 0;
      final raw = (hasDevice ? match.group(2) : match.group(1))!;
      final uri = Uri.tryParse(raw);
      if (uri == null || !uri.hasAuthority) continue;
      bestEnd = match.end;
      best = ServiceAnnouncement(
        uri,
        hasDevice ? match.group(1)?.trim() : null,
      );
    }
  }
  return best;
}

/// Rank panes by how likely they are to host the app this sidebar is about:
/// same tab first, then same workspace, then everything else.
int _paneRank(PaneInfo pane, String? tabId, String? workspaceId) {
  final sameWorkspace = workspaceId != null && pane.workspaceId == workspaceId;
  if (sameWorkspace && tabId != null && pane.tabId == tabId) return 0;
  if (sameWorkspace) return 1;
  return 2;
}

final _shellPromptTitle = RegExp(r'^\S+@\S+:');
const _shellNames = {'zsh', '-zsh', 'bash', '-bash', 'fish', 'sh', 'login'};

/// Whether a pane is sitting at a shell prompt with nothing running.
///
/// herdr sets a pane's title from its foreground process, so an idle shell shows
/// `user@host:path` or the shell's own name. Such a pane cannot be hosting a
/// `flutter run`, and skipping its scrollback is what keeps a background rescan
/// from spawning a read for every pane in the session.
bool looksIdle(PaneInfo pane) {
  final title = pane.title.trim();
  if (title.isEmpty) return true;
  if (_shellNames.contains(title)) return true;
  if (_shellPromptTitle.hasMatch(title)) return true;
  return false;
}

/// Panes worth reading: not an agent, not this sidebar, not another sidebar.
///
/// With [busyOnly] the panes that look idle are dropped as well, which is the
/// cheap sweep used by the periodic retry.
List<PaneInfo> candidatePanes(
  List<PaneInfo> panes, {
  String? selfPaneId,
  String? tabId,
  String? workspaceId,
  String? selfLabel,
  bool busyOnly = false,
}) {
  final candidates = panes
      .where((pane) => !pane.isAgent)
      .where((pane) => pane.paneId != selfPaneId)
      .where((pane) => selfLabel == null || pane.label != selfLabel)
      .where((pane) => !busyOnly || !looksIdle(pane))
      .toList();
  candidates.sort((a, b) {
    final rank = _paneRank(
      a,
      tabId,
      workspaceId,
    ).compareTo(_paneRank(b, tabId, workspaceId));
    if (rank != 0) return rank;
    return a.paneId.compareTo(b.paneId);
  });
  return candidates;
}

/// Every app the sidebar could attach to, best candidate first.
///
/// Discovery opens no connection of its own: it only reads text. It used to
/// probe each announced port with a TCP connect and an immediate destroy, which
/// put a connect and an abrupt reset on the debug tunnel on every pass, and for
/// a device that tunnel is iproxy over usbmuxd. It also accepted an orphaned
/// forward as alive, since such a forward answers the handshake and then never
/// speaks again. Attaching is now the only test, and it is the caller's job.
Future<List<AppTarget>> discoverTargets(
  HerdrCli cli, {
  String? configuredUri,
  String selfLabel = 'flutter',
  int paneLines = 3000,
  bool busyOnly = false,
}) async {
  final targets = <AppTarget>[];
  final seen = <String>{};

  if (configuredUri != null && configuredUri.isNotEmpty) {
    final uri = Uri.tryParse(configuredUri);
    if (uri != null && uri.hasAuthority) {
      targets.add(AppTarget(serviceUri: uri, origin: 'config'));
      seen.add('${uri.host}:${uri.port}');
    }
  }

  final List<PaneInfo> panes;
  try {
    panes = await cli.panes();
  } on HerdrCliException {
    return targets;
  }

  final candidates = candidatePanes(
    panes,
    selfPaneId: cli.selfPaneId,
    tabId: cli.selfTabId,
    workspaceId: cli.selfWorkspaceId,
    selfLabel: selfLabel,
    busyOnly: busyOnly,
  );

  for (final pane in candidates) {
    final String output;
    try {
      output = await cli.readPane(pane.paneId, lines: paneLines);
    } on HerdrCliException {
      continue;
    }
    final announcement = extractAnnouncement(output);
    if (announcement == null) continue;
    final key = '${announcement.uri.host}:${announcement.uri.port}';
    if (!seen.add(key)) {
      // Already known, but a pane beats the config as the reload owner.
      final existing = targets.indexWhere(
        (target) =>
            '${target.serviceUri.host}:${target.serviceUri.port}' == key,
      );
      if (existing >= 0 && targets[existing].ownerPaneId == null) {
        targets[existing] = AppTarget(
          serviceUri: targets[existing].serviceUri,
          deviceName: announcement.deviceName,
          ownerPaneId: pane.paneId,
          ownerTitle: pane.title,
          origin: targets[existing].origin,
        );
      }
      continue;
    }
    targets.add(
      AppTarget(
        serviceUri: announcement.uri,
        deviceName: announcement.deviceName,
        ownerPaneId: pane.paneId,
        ownerTitle: pane.title,
      ),
    );
  }

  return targets;
}
