import 'config.dart';
import 'discovery.dart';
import 'models.dart';
import 'session.dart';

enum View {
  logs('logs'),
  errors('errors'),
  inspector('inspect'),
  info('info');

  const View(this.label);

  final String label;
}

/// Which full-pane overlay is up, if any. A sidebar is too narrow for split
/// detail panes, so detail takes the whole body and escape goes back.
enum Overlay { none, help, toggles, targets, errorDetail, widgetDetail }

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

  AppTarget? get target =>
      targetIndex >= 0 && targetIndex < targets.length ? targets[targetIndex] : null;

  View view = View.logs;
  Overlay overlay = Overlay.none;

  final List<LogLine> logs = [];
  int logScroll = 0;
  bool follow = true;
  String filter = '';
  bool editingFilter = false;

  final List<ErrorItem> errors = [];
  int errorIndex = 0;
  int detailScroll = 0;

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

  ErrorItem? get selectedError =>
      errors.isEmpty ? null : errors[errorIndex.clamp(0, errors.length - 1)];

  WidgetNode? get selectedNode => flatTree.isEmpty
      ? null
      : flatTree[nodeIndex.clamp(0, flatTree.length - 1)];

  List<LogLine> get visibleLogs =>
      filter.isEmpty ? logs : logs.where((line) => line.matches(filter)).toList();

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
