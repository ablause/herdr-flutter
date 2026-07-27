import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

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
  }) : terminal = terminal ?? Terminal(mouse: config.mouse),
       handoff = handoff ?? Handoff(cli),
       state = AppState(config: config, repoRoot: repoRoot ?? findRepoRoot());

  final HerdrCli cli;
  final Terminal terminal;
  final Handoff handoff;
  final AppState state;

  final _done = Completer<void>();
  final _clicks = ClickTracker();
  Timer? _renderTimer;
  Timer? _statusTimer;
  Timer? _retryTimer;
  Timer? _networkTimer;
  bool _rendering = false;
  bool _polling = false;

  /// Set on the way out. Closing the session makes it report a disconnection,
  /// which would otherwise schedule one last frame and paint it over the shell
  /// after the alternate screen is gone.
  bool _stopped = false;

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
    terminal.clicks.listen((mouse) => unawaited(_onMouse(mouse)));
    terminal.resizes.listen((_) => _schedule());
    _schedule();
    unawaited(_discover());
    _scheduleRetry();
    await _done.future;
    _stopped = true;
    _retryTimer?.cancel();
    _renderTimer?.cancel();
    _statusTimer?.cancel();
    _networkTimer?.cancel();
    await state.session?.dispose();
    terminal.leave();
  }

  void _quit() {
    if (!_done.isCompleted) _done.complete();
  }

  static const _retryFloor = Duration(seconds: 3);
  static const _retryCeiling = Duration(seconds: 30);
  Duration _retryDelay = _retryFloor;

  /// URIs whose attach failed. The sidebar stops touching them until the user
  /// asks for a rescan, so a stale announcement in a pane's scrollback is tried
  /// once and then left alone rather than reopened on every pass.
  final Set<String> _dead = {};

  /// Look again for an app to attach to, backing off while nothing is there.
  ///
  /// The retry is cheap on purpose: it only reads panes that look busy, and it
  /// never repaints the body, so an idle sidebar neither flickers nor spawns a
  /// read for every pane in the session. An app that was attached and went away
  /// is worth finding fast, so the delay resets whenever one is known.
  void _scheduleRetry() {
    _retryTimer?.cancel();
    _retryTimer = Timer(_retryDelay, () async {
      final session = state.session;
      final stale =
          session == null ||
          session.state == SessionState.disconnected ||
          session.state == SessionState.failed;
      if (stale && !state.discovering) {
        await _discover(quiet: true, busyOnly: true);
      }
      final found = state.session?.isConnected ?? false;
      _retryDelay = found
          ? _retryFloor
          : Duration(
              seconds: math.min(
                _retryDelay.inSeconds * 2,
                _retryCeiling.inSeconds,
              ),
            );
      if (!_done.isCompleted) _scheduleRetry();
    });
  }

  /// Coalesce redraws: a busy app can post hundreds of log events a second.
  void _schedule() {
    if (_rendering || _stopped) return;
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

  Future<void> _discover({bool quiet = false, bool busyOnly = false}) async {
    if (state.discovering) return;
    state.discovering = true;
    if (!quiet) {
      state.discoveryError = null;
      // A rescan the user asked for restarts the backoff and forgives every
      // address that failed before: they are watching, and they may have just
      // fixed whatever was wrong.
      _dead.clear();
      _retryDelay = _retryFloor;
    }
    _schedule();
    try {
      final targets = await discoverTargets(
        cli,
        configuredUri: state.config.serviceUri,
        paneLines: state.config.paneLines,
        busyOnly: busyOnly,
      );
      state.targets = targets;
      state.discovering = false;
      state.firstScanDone = true;
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
      final next = targets.indexWhere(
        (target) => !_dead.contains(target.serviceUri.toString()),
      );
      if (next < 0) {
        state.discoveryError =
            'the app announced at ${targets.first.serviceUri.host}:'
            '${targets.first.serviceUri.port} did not answer. Press D to try again.';
        _schedule();
        return;
      }
      await _attach(next, quiet: quiet);
    } on Exception catch (error) {
      state.discovering = false;
      state.firstScanDone = true;
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
    state.callIndex = 0;
    state.callDetail = null;
    state.networkError = null;
    state.followCalls = true;

    final target = state.targets[index];
    final session = FlutterSession(
      target: target,
      httpProfiling: state.config.httpProfiling,
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
      _syncNetworkPolling();
    } else if (session.state == SessionState.failed) {
      _dead.add(target.serviceUri.toString());
      state.addLog(
        LogLine(LogSource.session, 'Attach failed: ${session.failure}'),
      );
    }
    _schedule();
  }

  /// Poll the HTTP profiler only while its view is up.
  ///
  /// The profiler has no event stream: the traffic has to be asked for. Asking
  /// once a second forever would be a request per second for a view nobody is
  /// looking at, and the app keeps recording either way, so nothing is lost by
  /// only polling while the view is on screen.
  void _syncNetworkPolling() {
    final wanted =
        (state.session?.isConnected ?? false) &&
        (state.view == View.network || state.overlay == Overlay.callDetail);
    if (!wanted) {
      _networkTimer?.cancel();
      _networkTimer = null;
      return;
    }
    if (_networkTimer != null) return;
    unawaited(_pollNetwork());
    _networkTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(_pollNetwork()),
    );
  }

  Future<void> _pollNetwork() async {
    final session = state.session;
    if (_polling || session == null || !session.isConnected) return;
    _polling = true;
    try {
      final failure = await session.pollHttpCalls();
      if (state.followCalls && state.calls.isNotEmpty) {
        state.callIndex = state.calls.length - 1;
      }
      if (failure != state.networkError) {
        state.networkError = failure;
        _schedule();
      }
    } finally {
      _polling = false;
    }
  }

  Future<void> _openCallDetail() async {
    final call = state.selectedCall;
    final session = state.session;
    if (call == null || session == null) return;
    state.overlay = Overlay.callDetail;
    state.detailScroll = 0;
    state.callDetail = null;
    _schedule();
    try {
      state.callDetail = await session.fetchHttpCall(call.id);
    } on Exception catch (error) {
      _note('request detail failed: $error', isError: true);
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
    if (state.overlay == Overlay.callDetail || state.view == View.network) {
      final call = state.selectedCall;
      if (call == null) return null;
      final outcome = call.hasError
          ? 'failed'
          : (call.statusCode == null
                ? 'is still running'
                : 'answered ${call.statusCode}');
      return (
        'http',
        'Flutter app HTTP ${call.method} ${call.uri} $outcome '
            'in ${target.label}.',
        report.httpCall(call, detail: state.callDetail),
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

  /// Clicks and wheel turns, resolved against the frame that is on screen.
  ///
  /// The top row selects a view, the wheel scrolls or moves the selection
  /// depending on what the body shows, and a click inside a list picks the row
  /// under the pointer.
  Future<void> _onMouse(Mouse mouse) async {
    final bodyRow = mouse.row - 1;
    final lastBodyRow = terminal.rows - 3;
    final inBody = bodyRow >= 0 && bodyRow <= lastBodyRow;

    if (mouse.kind == MouseKind.wheelUp || mouse.kind == MouseKind.wheelDown) {
      final up = mouse.kind == MouseKind.wheelUp;
      switch (state.overlay) {
        case Overlay.errorDetail:
        case Overlay.widgetDetail:
        case Overlay.callDetail:
          state.detailScroll = (state.detailScroll + (up ? -3 : 3)).clamp(
            0,
            1 << 30,
          );
        case Overlay.targets:
          await _overlayKey(Key(up ? 'up' : 'down'));
          return;
        case Overlay.help:
        case Overlay.toggles:
          return;
        case Overlay.none:
          switch (state.view) {
            case View.logs:
              state.logScroll = (state.logScroll + (up ? 3 : -3)).clamp(
                0,
                1 << 30,
              );
              state.follow = state.logScroll == 0;
            case View.errors:
              _errorsKey(Key(up ? 'up' : 'down'));
            case View.inspector:
              await _inspectorKey(Key(up ? 'up' : 'down'));
            case View.network:
              await _networkKey(Key(up ? 'up' : 'down'));
            case View.info:
              return;
          }
      }
      _schedule();
      return;
    }

    if (!mouse.isLeftPress) return;

    if (mouse.row == 0) {
      final view = tabAt(state, terminal.columns, mouse.column);
      if (view == null) return;
      state.overlay = Overlay.none;
      _setView(view);
      return;
    }

    if (!inBody) return;
    final item = bodyRow < state.hitRows.length ? state.hitRows[bodyRow] : null;
    if (item == null) return;
    // A second click on the row already picked does what enter would do to it,
    // which is the only way to reach a detail without touching the keyboard.
    final again = _clicks.isRepeat(
      '${state.overlay}/${state.view}',
      item,
      DateTime.now(),
    );
    switch (state.overlay) {
      case Overlay.targets:
        state.targetCursor = item;
        if (again) {
          state.overlay = Overlay.none;
          await _attach(item);
        }
      case Overlay.toggles:
        // A checkbox needs no double click: each click flips it, and clicking
        // twice puts it back, which is what it looks like it should do.
        final toggle = DebugToggle.all[item];
        final session = state.session;
        if (session != null) {
          final enabled = session.toggleStates[toggle.key] ?? false;
          final failure = await session.setToggle(toggle, enabled: !enabled);
          if (failure != null) _note(failure, isError: true);
        }
      case Overlay.none when state.view == View.errors:
        state.errorIndex = item;
        if (again) {
          state.overlay = Overlay.errorDetail;
          state.detailScroll = 0;
        }
      case Overlay.none when state.view == View.inspector:
        state.nodeIndex = item;
        if (again) await _inspectorKey(const Key('enter'));
      case Overlay.none when state.view == View.network:
        _selectCall(item);
        if (again) await _openCallDetail();
      case Overlay.none:
      case Overlay.help:
      case Overlay.errorDetail:
      case Overlay.widgetDetail:
      case Overlay.callDetail:
        return;
    }
    _schedule();
  }

  /// Move the network selection, which also stops the list following its tail.
  ///
  /// Without this a click would be undone a second later by the next poll, and a
  /// double click would land on two different rows.
  void _selectCall(int index) {
    state.callIndex = index;
    state.followCalls = index >= (state.calls.length - 1).clamp(0, 1 << 30);
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
        _setView(View.network);
      case '5':
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
    _syncNetworkPolling();
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
      case View.network:
        await _networkKey(key);
      case View.info:
        if (key.name == 'u') unawaited(_discover());
    }
  }

  Future<void> _networkKey(Key key) async {
    final page = (terminal.rows - 4).clamp(1, 200);
    final last = (state.calls.length - 1).clamp(0, 1 << 30);
    switch (key.name) {
      case 'j':
      case 'down':
        state.callIndex = (state.callIndex + 1).clamp(0, last);
      case 'k':
      case 'up':
        state.callIndex = (state.callIndex - 1).clamp(0, last);
      case 'pagedown':
        state.callIndex = (state.callIndex + page).clamp(0, last);
      case 'pageup':
        state.callIndex = (state.callIndex - page).clamp(0, last);
      case 'g':
      case 'home':
        state.callIndex = 0;
      case 'G':
      case 'end':
        state.callIndex = last;
      case 'u':
        await _pollNetwork();
      case 'c':
        final failure = await state.session?.clearHttpCalls();
        state.callIndex = 0;
        state.followCalls = true;
        if (failure != null) _note(failure, isError: true);
      case 'enter':
        if (state.calls.isNotEmpty) await _openCallDetail();
      default:
        return;
    }
    // Moving off the newest call stops the list from following it, and coming
    // back to it starts again, the way scrolling the log works.
    _selectCall(state.callIndex);
    _schedule();
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
      case Overlay.callDetail:
        switch (key.name) {
          case 'esc':
          case 'q':
            state.overlay = Overlay.none;
            state.detailScroll = 0;
            _syncNetworkPolling();
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
