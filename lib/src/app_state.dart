import 'dart:math' as math;

import 'config.dart';
import 'discovery.dart';
import 'models.dart';
import 'network.dart';
import 'session.dart';

enum View {
  logs('logs', 'log'),
  inspector('inspect', 'tree'),
  network('net', 'net'),
  info('info', 'info');

  const View(this.label, this.short);

  final String label;

  /// Used when the pane is too narrow for the full name and the app state.
  final String short;
}

/// Which full-pane overlay is up, if any. A sidebar is too narrow for split
/// detail panes, so detail takes the whole body and escape goes back.
enum Overlay {
  none,
  help,
  toggles,
  targets,
  errorDetail,
  widgetDetail,
  callDetail,
}

/// Everything the renderer needs. Mutated by the app, read by the views.
class AppState {
  AppState({required this.config, this.repoRoot});

  final PluginConfig config;
  final String? repoRoot;

  List<AppTarget> targets = [];
  int targetIndex = 0;
  FlutterSession? session;
  bool discovering = false;
  String? discoveryError;

  /// Set once a discovery has finished. A periodic rescan after that must not
  /// swap the body back to a scanning message: the pane would repaint on every
  /// retry, which reads as a flicker.
  bool firstScanDone = false;

  /// True only while a scan the user is waiting on is in flight.
  bool get scanVisible => discovering && !firstScanDone;

  AppTarget? get target => targetIndex >= 0 && targetIndex < targets.length
      ? targets[targetIndex]
      : null;

  View view = View.logs;
  Overlay overlay = Overlay.none;

  final List<LogLine> logs = [];

  /// Where the cursor sits when it is not riding the tail. Read through
  /// [logCursor], which is the one that accounts for following and for a filter
  /// that just changed under it.
  int logIndex = 0;
  bool follow = true;
  String filter = '';
  bool editingFilter = false;

  int detailScroll = 0;

  int callIndex = 0;
  HttpCallDetail? callDetail;
  String? networkError;

  /// Whether the selection rides the newest call, the way the log follows its
  /// tail. A user who scrolls up stops following until they come back down.
  bool followCalls = true;

  WidgetNode? tree;
  List<WidgetNode> flatTree = [];
  final Set<String> collapsed = {};
  int nodeIndex = 0;
  bool summaryTree = true;
  bool loadingTree = false;
  String? treeError;
  Map<String, Object?>? nodeDetails;

  int targetCursor = 0;

  String? status;
  bool statusIsError = false;

  /// For each body row of the last drawn frame, the index of the list item it
  /// shows, or null for a row that is not part of a list.
  ///
  /// The renderer fills this so a click can be resolved against exactly what is
  /// on screen, scrolling and multi-row entries included.
  List<int?> hitRows = [];

  /// The recorded traffic belongs to the connection, so it lives in the session
  /// and goes away with it.
  List<HttpCall> get calls => session?.calls ?? const [];

  HttpCall? get selectedCall =>
      calls.isEmpty ? null : calls[callIndex.clamp(0, calls.length - 1)];

  /// The log line under the cursor. Following pins it to the newest line, so a
  /// running app keeps the cursor where the output is.
  int get logCursor {
    final last = math.max(0, visibleLogs.length - 1);
    return follow ? last : logIndex.clamp(0, last);
  }

  LogLine? get selectedLog {
    final lines = visibleLogs;
    return lines.isEmpty ? null : lines[logCursor];
  }

  /// The error the cursor is on, which is the only way one is reached now that
  /// errors live in the log rather than in a list of their own.
  ErrorItem? get selectedError => selectedLog?.error;

  WidgetNode? get selectedNode => flatTree.isEmpty
      ? null
      : flatTree[nodeIndex.clamp(0, flatTree.length - 1)];

  List<LogLine> get visibleLogs {
    final parsed = LogFilter.parse(filter);
    return parsed.isEmpty ? logs : logs.where(parsed.matches).toList();
  }

  void addLog(LogLine line) {
    logs.add(line);
    final overflow = logs.length - config.logLimit;
    if (overflow > 0) logs.removeRange(0, overflow);
  }

  void note(String message, {bool isError = false}) {
    status = message;
    statusIsError = isError;
  }

  void rebuildFlatTree() {
    final root = tree;
    final previous = selectedNode?.valueId;
    flatTree = [];
    if (root == null) return;
    root.flatten(flatTree, collapsed);
    if (previous != null) {
      final index = flatTree.indexWhere((node) => node.valueId == previous);
      if (index >= 0) {
        nodeIndex = index;
        return;
      }
    }
    nodeIndex = nodeIndex.clamp(0, flatTree.length - 1);
  }
}
