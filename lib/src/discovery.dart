import 'dart:io';

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

final _announcementPatterns = <RegExp>[
  // flutter run, the common case: device name and http URI on one line. The URI
  // is kept exactly as printed, trailing slash included: the websocket path is
  // derived from it, and rewriting it would break the connection.
  RegExp(
    r'(?:A|The) Dart VM Service on (.+?) is available at:\s*(https?://\S+)',
    multiLine: true,
  ),
  // dart run and flutter test: no device name.
  RegExp(r'The Dart VM Service is listening on\s*(https?://\S+)', multiLine: true),
  // flutter run -d chrome announces the websocket directly.
  RegExp(r'Debug service listening on\s*(wss?://\S+)', multiLine: true),
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

/// Whether something still listens on the announced port.
///
/// A stale announcement in the scrollback is the normal case after an app
/// exits, and connecting to it would hang the sidebar on startup.
Future<bool> isReachable(Uri uri, {Duration timeout = const Duration(milliseconds: 400)}) async {
  try {
    final socket = await Socket.connect(uri.host, uri.port, timeout: timeout);
    socket.destroy();
    return true;
  } on Exception {
    return false;
  }
}

/// Rank panes by how likely they are to host the app this sidebar is about:
/// same tab first, then same workspace, then everything else.
int _paneRank(PaneInfo pane, String? tabId, String? workspaceId) {
  final sameWorkspace = workspaceId != null && pane.workspaceId == workspaceId;
  if (sameWorkspace && tabId != null && pane.tabId == tabId) return 0;
  if (sameWorkspace) return 1;
  return 2;
}

/// Panes worth reading: not an agent, not this sidebar, not another sidebar.
List<PaneInfo> candidatePanes(
  List<PaneInfo> panes, {
  String? selfPaneId,
  String? tabId,
  String? workspaceId,
  String? selfLabel,
}) {
  final candidates = panes
      .where((pane) => !pane.isAgent)
      .where((pane) => pane.paneId != selfPaneId)
      .where((pane) => selfLabel == null || pane.label != selfLabel)
      .toList();
  candidates.sort((a, b) {
    final rank = _paneRank(a, tabId, workspaceId)
        .compareTo(_paneRank(b, tabId, workspaceId));
    if (rank != 0) return rank;
    return a.paneId.compareTo(b.paneId);
  });
  return candidates;
}

/// Every reachable app the sidebar could attach to, best candidate first.
///
/// A configured URI is tried first and never dropped for being unreachable, so
/// a deliberate override reports its own failure instead of vanishing.
Future<List<AppTarget>> discoverTargets(
  HerdrCli cli, {
  String? configuredUri,
  String selfLabel = 'flutter',
  int paneLines = 3000,
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
        (target) => '${target.serviceUri.host}:${target.serviceUri.port}' == key,
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
    if (!await isReachable(announcement.uri)) continue;
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
