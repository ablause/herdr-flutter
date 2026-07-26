import 'dart:async';
import 'dart:io';

import 'app_state.dart';
import 'config.dart';
import 'discovery.dart';
import 'handoff.dart';
import 'herdr_cli.dart';
import 'models.dart';
import 'report.dart';
import 'session.dart';
import 'tui/terminal.dart';
import 'views.dart';

/// The sidebar: discovery, one live session, and the key handling around it.
class App {
  App({
    required this.cli,
    required PluginConfig config,
    Terminal? terminal,
    Handoff? handoff,
    String? repoRoot,
  }) : terminal = terminal ?? Terminal(),
       handoff = handoff ?? Handoff(cli),
       state = AppState(config: config, repoRoot: repoRoot ?? findRepoRoot());

  final HerdrCli cli;
  final Terminal terminal;
  final Handoff handoff;
  final AppState state;

  final _done = Completer<void>();
  Timer? _renderTimer;
  Timer? _statusTimer;
  Timer? _retryTimer;
  bool _rendering = false;

  /// The project directory, so reports and the tree show short paths.
  static String? findRepoRoot([Directory? from]) {
    var directory = from ?? Directory.current;
    for (var depth = 0; depth < 12; depth++) {
      if (File('${directory.path}/pubspec.yaml').existsSync()) {
        return directory.path;
      }
      final parent = directory.parent;
      if (parent.path == directory.path) break;
      directory = parent;
    }
    return (from ?? Directory.current).path;
  }

  Future<void> run() async {
    terminal.enter();
    terminal.keys.listen((key) => unawaited(_onKey(key)));
    terminal.resizes.listen((_) => _schedule());
    _schedule();
    unawaited(_discover());
    _retryTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      final session = state.session;
      final stale =
          session == null ||
          session.state == SessionState.disconnected ||
          session.state == SessionState.failed;
      if (stale && !state.discovering) unawaited(_discover(quiet: true));
    });
    await _done.future;
    _retryTimer?.cancel();
    _renderTimer?.cancel();
    _statusTimer?.cancel();
    await state.session?.dispose();
    terminal.leave();
  }

  void _quit() {
    if (!_done.isCompleted) _done.complete();
  }

  /// Coalesce redraws: a busy app can post hundreds of log events a second.
  void _schedule() {
    if (_rendering) return;
    _rendering = true;
    _renderTimer = Timer(const Duration(milliseconds: 25), () {
      _rendering = false;
      _render();
    });
  }

  void _render() {
    terminal.draw(renderFrame(state, terminal.columns, terminal.rows));
  }

  void _note(String message, {bool isError = false}) {
    state.note(message, isError: isError);
    _statusTimer?.cancel();
    _statusTimer = Timer(const Duration(seconds: 8), () {
      state.status = null;
      _schedule();
    });
    _schedule();
  }

  Future<void> _discover({bool quiet = false}) async {
    if (state.discovering) return;
    state.discovering = true;
    if (!quiet) state.discoveryError = null;
    _schedule();
    try {
      final targets = await discoverTargets(
        cli,
        configuredUri: state.config.serviceUri,
        paneLines: state.config.paneLines,
      );
      state.targets = targets;
      state.discovering = false;
      if (targets.isEmpty) {
        state.discoveryError = cli.available
            ? null
            : 'the herdr CLI is not on PATH, so panes cannot be scanned';
        _schedule();
        return;
      }
      final current = state.session;
      final currentUri = state.target?.serviceUri.toString();
      final sameApp =
          current != null &&
          current.isConnected &&
          targets.any((target) => target.serviceUri.toString() == currentUri);
      if (sameApp) {
        state.targetIndex = targets.indexWhere(
          (target) => target.serviceUri.toString() == currentUri,
        );
        _schedule();
        return;
      }
      await _attach(0, quiet: quiet);
    } on Exception catch (error) {
      state.discovering = false;
      state.discoveryError = error.toString();
      _schedule();
    }
  }

  Future<void> _attach(int index, {bool quiet = false}) async {
    if (index < 0 || index >= state.targets.length) return;
    final previous = state.session;
    state.session = null;
    if (previous != null) await previous.dispose();
    state.targetIndex = index;
    state.tree = null;
    state.flatTree = [];
    state.collapsed.clear();
    state.errors.clear();
    state.errorIndex = 0;

    final target = state.targets[index];
    final session = FlutterSession(
      target: target,
      onLog: (line) {
        state.addLog(line);
        if (state.follow) state.logScroll = 0;
        _schedule();
      },
      onError: (error) {
        state.errors.add(error);
        if (state.errors.length == 1) state.errorIndex = 0;
        _schedule();
      },
      onChange: _schedule,
    );
    state.session = session;
    await session.connect();
    if (session.state == SessionState.connected) {
      state.addLog(LogLine(LogSource.session, 'Attached to ${target.label}'));
      if (!quiet) _note('attached to ${target.label}');
      if (state.view == View.inspector) unawaited(_fetchTree());
    } else if (session.state == SessionState.failed) {
      state.addLog(
        LogLine(LogSource.session, 'Attach failed: ${session.failure}'),
      );
    }
    _schedule();
  }

  Future<void> _fetchTree() async {
    final session = state.session;
    if (session == null || !session.isConnected) return;
    if (!session.inspectorReady) {
      state.treeError =
          'This app did not register the widget inspector. It is a debug-build '
          'feature: a profile or release build has no widget tree to read.';
      _schedule();
      return;
    }
    state.loadingTree = true;
    state.treeError = null;
    _schedule();
    try {
      final tree = await session.fetchWidgetTree(summary: state.summaryTree);
      state.tree = tree;
      state.treeError = tree == null ? 'the inspector returned no tree' : null;
      state.rebuildFlatTree();
    } on Exception catch (error) {
      state.treeError = error.toString();
    } finally {
      state.loadingTree = false;
      _schedule();
    }
  }

  Future<void> _reload({required bool full}) async {
    final session = state.session;
    final target = state.target;
    if (session == null || !session.isConnected) {
      _note('not attached to an app', isError: true);
      return;
    }
    _note(full ? 'hot restarting…' : 'hot reloading…');
    final failure = await session.reload(full: full);
    if (failure == null) {
      _note(full ? 'hot restart done' : 'hot reload done');
      if (state.tree != null) unawaited(_fetchTree());
      return;
    }
    // The protocol path is the normal one; the keystroke is for a flutter run
    // that never registered its services on this connection.
    final owner = target?.ownerPaneId;
    if (owner == null) {
      _note('reload refused: $failure', isError: true);
      return;
    }
    try {
      await cli.sendText(owner, full ? 'R' : 'r');
      _note('sent ${full ? 'R' : 'r'} to $owner');
    } on HerdrCliException catch (error) {
      _note('reload failed: ${error.message}', isError: true);
    }
  }

  /// What the current view would hand over: a slug, a headline and a report.
  (String, String, String)? _capture() {
    final target = state.target;
    if (target == null) return null;
    final report = Report(target: target, repoRoot: state.repoRoot);
    if (state.overlay == Overlay.widgetDetail || state.view == View.inspector) {
      final node = state.selectedNode;
      if (node == null) return null;
      final location = node.location?.display(root: state.repoRoot);
      return (
        'widget',
        'Flutter widget ${node.description}'
            '${location == null ? '' : ' at $location'} in ${target.label}.',
        report.widget(node, details: state.nodeDetails),
      );
    }
    if (state.overlay == Overlay.errorDetail || state.view == View.errors) {
      final error = state.selectedError;
      if (error == null) return null;
      final location = error.location?.display(root: state.repoRoot);
      return (
        'error',
        'Flutter runtime error in ${target.label}: ${error.summary}'
            '${location == null ? '' : ' ($location)'}.',
        report.error(error),
      );
    }
    if (state.view == View.logs) {
      final lines = state.visibleLogs;
      if (lines.isEmpty) return null;
      return (
        'log',
        'Flutter app log from ${target.label}, '
            '${lines.length} lines'
            '${state.filter.isEmpty ? '' : ' matching "${state.filter}"'}.',
        report.logs(lines, filter: state.filter),
      );
    }
    return null;
  }

  Future<void> _send() async {
    final capture = _capture();
    if (capture == null) {
      _note('nothing to send from this view', isError: true);
      return;
    }
    final (slug, headline, markdown) = capture;
    _note('sending to the agent…');
    final result = await handoff.send(
      slug: slug,
      headline: headline,
      markdown: markdown,
    );
    if (result.sent) {
      _note('sent to ${result.agentPaneId}, focus moved there');
      return;
    }
    final path = result.reportPath;
    _note(
      '${result.message}${path == null ? '' : '. Report kept at $path'}',
      isError: true,
    );
  }

  Future<void> _copy() async {
    final capture = _capture();
    if (capture == null) {
      _note('nothing to copy from this view', isError: true);
      return;
    }
    final failure = await copyToClipboard(capture.$3);
    _note(failure ?? 'copied to the clipboard', isError: failure != null);
  }

  Future<void> _openWidgetDetail() async {
    final node = state.selectedNode;
    final session = state.session;
    final id = node?.valueId;
    if (node == null || session == null || id == null) return;
    state.overlay = Overlay.widgetDetail;
    state.detailScroll = 0;
    state.nodeDetails = null;
    _schedule();
    try {
      state.nodeDetails = await session.fetchDetails(id);
    } on Exception catch (error) {
      _note('details failed: $error', isError: true);
    }
    _schedule();
  }

  Future<void> _onKey(Key key) async {
    if (state.editingFilter) {
      _filterKey(key);
      return;
    }
    if (state.overlay != Overlay.none) {
      await _overlayKey(key);
      return;
    }
    switch (key.name) {
      case 'q':
      case 'ctrl-c':
        _quit();
      case 'ctrl-l':
        terminal.invalidate();
        _schedule();
      case '1':
        _setView(View.logs);
      case '2':
        _setView(View.errors);
      case '3':
        _setView(View.inspector);
      case '4':
        _setView(View.info);
      case 'tab':
        _setView(View.values[(state.view.index + 1) % View.values.length]);
      case 'shift-tab':
        _setView(
          View.values[(state.view.index - 1 + View.values.length) %
              View.values.length],
        );
      case '?':
        state.overlay = Overlay.help;
        _schedule();
      case 't':
        state.overlay = Overlay.toggles;
        unawaited(state.session?.refreshToggles() ?? Future.value());
        _schedule();
      case 'D':
        state.overlay = Overlay.targets;
        state.targetCursor = state.targetIndex;
        _schedule();
        unawaited(_discover());
      case 'r':
        await _reload(full: false);
      case 'R':
        await _reload(full: true);
      case 's':
        await _send();
      case 'y':
        await _copy();
      default:
        await _viewKey(key);
    }
  }

  void _setView(View view) {
    state.view = view;
    state.status = null;
    if (view == View.inspector && state.tree == null && !state.loadingTree) {
      unawaited(_fetchTree());
    }
    _schedule();
  }

  Future<void> _viewKey(Key key) async {
    switch (state.view) {
      case View.logs:
        _logsKey(key);
      case View.errors:
        _errorsKey(key);
      case View.inspector:
        await _inspectorKey(key);
      case View.info:
        if (key.name == 'u') unawaited(_discover());
    }
  }

  void _logsKey(Key key) {
    final page = (terminal.rows - 4).clamp(1, 200);
    switch (key.name) {
      case 'j':
      case 'down':
        state.logScroll = (state.logScroll - 1).clamp(0, 1 << 30);
      case 'k':
      case 'up':
        state.logScroll += 1;
      case 'pagedown':
        state.logScroll = (state.logScroll - page).clamp(0, 1 << 30);
      case 'pageup':
        state.logScroll += page;
      case 'G':
      case 'end':
        state.logScroll = 0;
      case 'g':
      case 'home':
        state.logScroll = 1 << 20;
      case 'c':
        state.logs.clear();
        state.logScroll = 0;
      case '/':
        state.editingFilter = true;
      default:
        return;
    }
    state.follow = state.logScroll == 0;
    _schedule();
  }

  void _filterKey(Key key) {
    switch (key.name) {
      case 'esc':
        state.filter = '';
        state.editingFilter = false;
      case 'enter':
        state.editingFilter = false;
      case 'backspace':
        if (state.filter.isNotEmpty) {
          state.filter = state.filter.substring(0, state.filter.length - 1);
        }
      default:
        if (key.isChar) state.filter += key.name;
    }
    state.logScroll = 0;
    _schedule();
  }

  void _errorsKey(Key key) {
    switch (key.name) {
      case 'j':
      case 'down':
        state.errorIndex = (state.errorIndex + 1).clamp(
          0,
          (state.errors.length - 1).clamp(0, 1 << 30),
        );
      case 'k':
      case 'up':
        state.errorIndex = (state.errorIndex - 1).clamp(0, 1 << 30);
      case 'g':
      case 'home':
        state.errorIndex = 0;
      case 'G':
      case 'end':
        state.errorIndex = (state.errors.length - 1).clamp(0, 1 << 30);
      case 'c':
        state.errors.clear();
        state.errorIndex = 0;
      case 'enter':
        if (state.errors.isNotEmpty) {
          state.overlay = Overlay.errorDetail;
          state.detailScroll = 0;
        }
      default:
        return;
    }
    _schedule();
  }

  Future<void> _inspectorKey(Key key) async {
    final node = state.selectedNode;
    switch (key.name) {
      case 'j':
      case 'down':
        state.nodeIndex = (state.nodeIndex + 1).clamp(
          0,
          (state.flatTree.length - 1).clamp(0, 1 << 30),
        );
      case 'k':
      case 'up':
        state.nodeIndex = (state.nodeIndex - 1).clamp(0, 1 << 30);
      case 'g':
      case 'home':
        state.nodeIndex = 0;
      case 'G':
      case 'end':
        state.nodeIndex = (state.flatTree.length - 1).clamp(0, 1 << 30);
      case 'enter':
      case 'l':
      case 'h':
        final id = node?.valueId;
        if (id != null && (node?.hasChildren ?? false)) {
          if (!state.collapsed.remove(id)) state.collapsed.add(id);
          state.rebuildFlatTree();
        }
      case 'u':
        await _fetchTree();
      case 'f':
        state.summaryTree = !state.summaryTree;
        _note(state.summaryTree ? 'summary tree' : 'full tree');
        await _fetchTree();
      case 'd':
        await _openWidgetDetail();
      case 'x':
        final id = node?.valueId;
        final session = state.session;
        if (id != null && session != null) {
          await session.selectWidget(id);
          _note('selected in the app');
        }
      default:
        return;
    }
    _schedule();
  }

  Future<void> _overlayKey(Key key) async {
    final page = (terminal.rows - 4).clamp(1, 200);
    switch (state.overlay) {
      case Overlay.toggles:
        if (key.name == 'esc' || key.name == 'q' || key.name == 't') {
          state.overlay = Overlay.none;
          _schedule();
          return;
        }
        DebugToggle? toggle;
        for (final candidate in DebugToggle.all) {
          if (candidate.key == key.name) toggle = candidate;
        }
        final session = state.session;
        if (toggle != null && session != null) {
          final enabled = session.toggleStates[toggle.key] ?? false;
          final failure = await session.setToggle(toggle, enabled: !enabled);
          if (failure != null) _note(failure, isError: true);
        }
        _schedule();
      case Overlay.targets:
        switch (key.name) {
          case 'esc':
          case 'q':
          case 'D':
            state.overlay = Overlay.none;
          case 'j':
          case 'down':
            state.targetCursor = (state.targetCursor + 1).clamp(
              0,
              (state.targets.length - 1).clamp(0, 1 << 30),
            );
          case 'k':
          case 'up':
            state.targetCursor = (state.targetCursor - 1).clamp(0, 1 << 30);
          case 'u':
            unawaited(_discover());
          case 'enter':
            state.overlay = Overlay.none;
            await _attach(state.targetCursor);
        }
        _schedule();
      case Overlay.errorDetail:
      case Overlay.widgetDetail:
        switch (key.name) {
          case 'esc':
          case 'q':
            state.overlay = Overlay.none;
            state.detailScroll = 0;
          case 'j':
          case 'down':
            state.detailScroll += 1;
          case 'k':
          case 'up':
            state.detailScroll = (state.detailScroll - 1).clamp(0, 1 << 30);
          case 'pagedown':
            state.detailScroll += page;
          case 'pageup':
            state.detailScroll = (state.detailScroll - page).clamp(0, 1 << 30);
          case 'g':
          case 'home':
            state.detailScroll = 0;
          case 'G':
          case 'end':
            state.detailScroll = 1 << 20;
          case 's':
            await _send();
          case 'y':
            await _copy();
          case 'r':
            await _reload(full: false);
          case 'R':
            await _reload(full: true);
        }
        _schedule();
      case Overlay.help:
      case Overlay.none:
        state.overlay = Overlay.none;
        _schedule();
    }
  }
}
