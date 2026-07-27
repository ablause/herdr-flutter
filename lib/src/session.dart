import 'dart:async';
import 'dart:convert';

import 'package:vm_service/utils.dart';
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

import 'discovery.dart';
import 'models.dart';
import 'network.dart';

/// Service extension names this sidebar uses. Verified against the Flutter
/// framework sources shipped with the SDK in use (see docs/api-notes.md).
class Ext {
  static const rootWidgetTree = 'ext.flutter.inspector.getRootWidgetTree';
  static const detailsSubtree = 'ext.flutter.inspector.getDetailsSubtree';
  static const setSelectionById = 'ext.flutter.inspector.setSelectionById';
  static const disposeGroup = 'ext.flutter.inspector.disposeGroup';
  static const isWidgetTreeReady = 'ext.flutter.inspector.isWidgetTreeReady';
  static const selectMode = 'ext.flutter.inspector.show';

  /// dart:io's own extensions, registered by the VM rather than by Flutter.
  static const httpTimelineLogging = 'ext.dart.io.httpEnableTimelineLogging';
  static const httpProfile = 'ext.dart.io.getHttpProfile';
  static const httpProfileRequest = 'ext.dart.io.getHttpProfileRequest';
  static const clearHttpProfile = 'ext.dart.io.clearHttpProfile';
}

/// A debug toggle exposed by the framework as a boolean service extension.
class DebugToggle {
  const DebugToggle(this.key, this.label, this.method);

  final String key;
  final String label;
  final String method;

  static const all = <DebugToggle>[
    DebugToggle('p', 'Paint guides', 'ext.flutter.debugPaint'),
    DebugToggle('b', 'Baselines', 'ext.flutter.debugPaintBaselinesEnabled'),
    DebugToggle('R', 'Repaint rainbow', 'ext.flutter.repaintRainbow'),
    DebugToggle(
      'o',
      'Performance overlay',
      'ext.flutter.showPerformanceOverlay',
    ),
    DebugToggle('a', 'Debug banner', 'ext.flutter.debugAllowBanner'),
    DebugToggle('i', 'Oversized images', 'ext.flutter.invertOversizedImages'),
    DebugToggle('w', 'Select widget mode', Ext.selectMode),
  ];
}

enum SessionState { connecting, connected, reloading, disconnected, failed }

/// The VM Service side of the sidebar: one connection to one running app.
///
/// The class owns the isolate the app runs in, the streams it listens to, and
/// the flutter-tool services registered on the connection. It never touches the
/// terminal; the caller decides what to draw.
class FlutterSession {
  FlutterSession({
    required this.target,
    required this.onLog,
    required this.onError,
    required this.onChange,
    this.httpProfiling = true,
  });

  final AppTarget target;
  final void Function(LogLine) onLog;
  final void Function(ErrorItem) onError;
  final void Function() onChange;

  /// Whether to ask the app to record its HTTP traffic. Recording keeps every
  /// body in the app's memory until it is cleared, so it can be turned off.
  final bool httpProfiling;

  static const _objectGroup = 'herdr-flutter';

  VmService? _service;
  final _subscriptions = <StreamSubscription<Event>>[];

  SessionState state = SessionState.connecting;
  String? failure;

  String? isolateId;
  String? isolateName;
  Set<String> extensionRpcs = {};

  /// Methods the flutter tool registered on this connection, by service name.
  final Map<String, String> _toolMethods = {};

  Map<String, bool> toggleStates = {};
  Map<String, Object?> vmInfo = {};
  Map<String, Object?> flutterVersion = {};

  int frames = 0;
  double? lastBuildMs;
  double? lastRasterMs;
  int errorCount = 0;

  /// The HTTP calls seen since profiling was enabled, oldest first.
  List<HttpCall> calls = const [];
  final Map<String, HttpCall> _callsById = {};

  /// The device clock as of the last poll, which dates the calls and measures
  /// the ones still running without involving this process's own clock.
  int? profileMicros;

  bool httpProfilingEnabled = false;

  /// Beyond this the oldest calls are dropped, the way the log is trimmed. The
  /// app keeps its own copy either way; this is only what the sidebar holds.
  static const _callLimit = 500;

  bool get canReload => _toolMethods.containsKey('reloadSources');
  bool get canRestart => _toolMethods.containsKey('hotRestart');
  bool get inspectorReady => extensionRpcs.contains(Ext.rootWidgetTree);
  bool get networkReady => extensionRpcs.contains(Ext.httpProfile);
  bool get isConnected =>
      state == SessionState.connected || state == SessionState.reloading;

  Future<void> connect() async {
    _setState(SessionState.connecting);
    try {
      final wsUri = target.serviceUri.scheme.startsWith('ws')
          ? target.serviceUri
          : convertToWebSocketUrl(serviceProtocolUrl: target.serviceUri);
      // An orphaned port forward accepts the connection and then never answers,
      // which is exactly what a stale iproxy tunnel to a device looks like, so
      // the handshake needs a deadline of its own.
      final service = await vmServiceConnectUri(
        wsUri.toString(),
      ).timeout(const Duration(seconds: 8));
      _service = service;
      service.onDone.then((_) {
        if (state != SessionState.failed) {
          _setState(SessionState.disconnected);
        }
      });
      await _listenStreams(service);
      await _refreshIsolate();
      await _loadVmInfo();
      _setState(SessionState.connected);
      unawaited(_loadFlutterVersion());
      unawaited(refreshToggles());
      unawaited(enableHttpProfiling());
    } on TimeoutException {
      failure =
          'the service did not answer within eight seconds, '
          'which is what a stale port forward looks like';
      _setState(SessionState.failed);
    } on Exception catch (error) {
      failure = _short(error);
      _setState(SessionState.failed);
    }
  }

  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    final service = _service;
    _service = null;
    if (service == null) return;
    try {
      final isolate = isolateId;
      if (isolate != null && inspectorReady) {
        await service
            .callServiceExtension(
              Ext.disposeGroup,
              isolateId: isolate,
              args: {'objectGroup': _objectGroup},
            )
            .timeout(const Duration(seconds: 1));
      }
    } on Exception {
      // Disposing the object group is a courtesy; the app drops it on reload.
    }
    try {
      await service.dispose();
    } on Exception {
      // Nothing left to do on the way out.
    }
  }

  void _setState(SessionState next) {
    state = next;
    onChange();
  }

  Future<void> _listenStreams(VmService service) async {
    Future<void> listen(String stream, void Function(Event) handler) async {
      // Subscribe before streamListen. The VM replays state as events the moment
      // the stream is listened to, and the Service stream replays every existing
      // registration, so a listener attached afterwards misses hot reload.
      _subscriptions.add(service.onEvent(stream).listen(handler));
      try {
        await service.streamListen(stream);
      } on RPCError catch (error) {
        // 103 is "stream already subscribed", which is not a problem.
        if (error.code != 103) return;
      }
    }

    await listen(
      EventStreams.kStdout,
      (event) => _onStdio(event, LogSource.stdout),
    );
    await listen(
      EventStreams.kStderr,
      (event) => _onStdio(event, LogSource.stderr),
    );
    await listen(EventStreams.kLogging, _onLogging);
    await listen(EventStreams.kExtension, _onExtension);
    await listen(EventStreams.kIsolate, _onIsolate);
    await listen(EventStreams.kService, _onService);
  }

  void _onStdio(Event event, LogSource source) {
    final bytes = event.bytes;
    if (bytes == null) return;
    final text = utf8.decode(base64Decode(bytes), allowMalformed: true);
    for (final line in text.split('\n')) {
      if (line.trim().isEmpty) continue;
      onLog(LogLine(source, line.trimRight()));
    }
  }

  void _onLogging(Event event) {
    final record = event.logRecord;
    if (record == null) return;
    final message = record.message?.valueAsString ?? '';
    final logger = record.loggerName?.valueAsString ?? '';
    final name = logger.isEmpty ? null : logger;
    onLog(
      LogLine(LogSource.developer, message, name: name, level: record.level),
    );
    final errorText = record.error?.valueAsString;
    if (errorText != null && errorText.isNotEmpty && errorText != 'null') {
      onLog(
        LogLine(
          LogSource.developer,
          errorText,
          name: name,
          // An error attached to a record is severe whatever the record said.
          level: 1000,
        ),
      );
    }
  }

  void _onExtension(Event event) {
    final kind = event.extensionKind;
    final data = event.extensionData?.data;
    if (kind == 'Flutter.Error' && data != null) {
      errorCount++;
      onError(ErrorItem.fromEventData(Map<String, Object?>.from(data)));
      onChange();
      return;
    }
    if (kind == 'Flutter.Frame') {
      frames++;
      final build = data?['build'];
      final raster = data?['raster'];
      if (build is num) lastBuildMs = build / 1000;
      if (raster is num) lastRasterMs = raster / 1000;
      return;
    }
    if (kind == null) return;
    if (kind == 'Flutter.ServiceExtensionStateChanged') {
      unawaited(refreshToggles());
    }
    onLog(LogLine(LogSource.session, kind));
  }

  void _onIsolate(Event event) {
    switch (event.kind) {
      case EventKind.kServiceExtensionAdded:
        final rpc = event.extensionRPC;
        if (rpc == null || !extensionRpcs.add(rpc)) return;
        // dart:io registers its extensions on its own schedule, so profiling is
        // turned on whenever they show up rather than only at attach.
        if (rpc == Ext.httpProfile) unawaited(enableHttpProfiling());
        onChange();
      case EventKind.kIsolateStart:
      case EventKind.kIsolateRunnable:
        unawaited(_onIsolateRestarted());
      case EventKind.kIsolateExit:
        if (event.isolate?.id == isolateId) {
          isolateId = null;
          extensionRpcs = {};
          onChange();
        }
    }
  }

  Future<void> _onIsolateRestarted() async {
    // A hot restart replaces the isolate: everything keyed to the old one, the
    // inspector object group and the recorded traffic included, is gone.
    errorCount = 0;
    _resetCalls();
    await _refreshIsolate();
    await refreshToggles();
    await enableHttpProfiling();
    onChange();
  }

  void _onService(Event event) {
    final service = event.service;
    final method = event.method;
    if (service == null || method == null) return;
    if (event.kind == EventKind.kServiceUnregistered) {
      _toolMethods.remove(service);
    } else {
      _toolMethods[service] = method;
    }
    onChange();
  }

  Future<void> _refreshIsolate() async {
    final service = _service;
    if (service == null) return;
    final vm = await service.getVM();
    final isolates = vm.isolates ?? const [];
    if (isolates.isEmpty) {
      isolateId = null;
      return;
    }
    for (final ref in isolates) {
      final id = ref.id;
      if (id == null) continue;
      try {
        final isolate = await service.getIsolate(id);
        final rpcs = (isolate.extensionRPCs ?? const <String>[]).toSet();
        if (rpcs.contains(Ext.rootWidgetTree) || isolateId == null) {
          isolateId = id;
          isolateName = isolate.name;
          extensionRpcs = rpcs;
        }
        if (rpcs.contains(Ext.rootWidgetTree)) return;
      } on RPCError {
        continue;
      }
    }
  }

  Future<void> _loadVmInfo() async {
    final service = _service;
    if (service == null) return;
    try {
      final vm = await service.getVM();
      vmInfo = {
        'version': vm.version,
        'targetCPU': vm.targetCPU,
        'hostCPU': vm.hostCPU,
        'operatingSystem': vm.operatingSystem,
        'pid': vm.pid,
        'isolates': vm.isolates?.length,
      };
    } on Exception {
      vmInfo = {};
    }
  }

  Future<void> _loadFlutterVersion() async {
    final method = _toolMethods['flutterVersion'];
    final service = _service;
    if (method == null || service == null) return;
    try {
      final response = await service
          .callMethod(method)
          .timeout(const Duration(seconds: 5));
      flutterVersion = Map<String, Object?>.from(response.json ?? {});
      onChange();
    } on Exception {
      // Version details are decoration; a failure changes nothing else.
    }
  }

  /// Ask the flutter tool to hot reload, or hot restart with [full].
  ///
  /// Returns null on success, or a message explaining the refusal. The tool
  /// registers these services on the VM Service connection itself, so this path
  /// works whether or not the `flutter run` sits in a herdr pane.
  Future<String?> reload({bool full = false}) async {
    final service = _service;
    if (service == null) return 'not connected';
    final method = _toolMethods[full ? 'hotRestart' : 'reloadSources'];
    if (method == null) {
      return 'the flutter tool did not register '
          '${full ? 'hotRestart' : 'reloadSources'} on this connection';
    }
    final isolate = isolateId;
    if (!full && isolate == null) return 'no isolate to reload';
    _setState(SessionState.reloading);
    try {
      final response = await service
          .callMethod(
            method,
            args: full
                ? {'pause': false}
                : {'isolateId': isolate, 'force': false, 'pause': false},
          )
          .timeout(const Duration(minutes: 2));
      final result = response.json?['result'];
      final type = result is Map ? result['type'] : null;
      _setState(SessionState.connected);
      onLog(
        LogLine(
          LogSource.session,
          full ? 'Hot restart requested' : 'Hot reload requested',
        ),
      );
      if (type != null && type != 'Success') return 'reload reported $type';
      if (full) errorCount = 0;
      return null;
    } on TimeoutException {
      _setState(SessionState.connected);
      return 'reload timed out after two minutes';
    } on Exception catch (error) {
      _setState(SessionState.connected);
      return _short(error);
    }
  }

  Future<Map<String, Object?>?> _callExtension(
    String method, {
    Map<String, dynamic>? args,
  }) async {
    final service = _service;
    final isolate = isolateId;
    if (service == null || isolate == null) return null;
    final response = await service.callServiceExtension(
      method,
      isolateId: isolate,
      args: args,
    );
    return Map<String, Object?>.from(response.json ?? {});
  }

  /// The widget tree, summary by default so it shows the project's own widgets.
  Future<WidgetNode?> fetchWidgetTree({bool summary = true}) async {
    if (!inspectorReady) return null;
    final response = await _callExtension(
      Ext.rootWidgetTree,
      args: {
        'groupName': _objectGroup,
        'isSummaryTree': '$summary',
        'withPreviews': 'true',
        // Without full details the nodes carry no creationLocation, and the
        // file:line of a widget is the whole point of the tree here.
        'fullDetails': 'true',
      },
    );
    final result = response?['result'];
    if (result is! Map) return null;
    return WidgetNode.fromJson(Map<String, Object?>.from(result));
  }

  /// Properties and shallow children of one node, for the detail pane.
  Future<Map<String, Object?>?> fetchDetails(String valueId) async {
    final response = await _callExtension(
      Ext.detailsSubtree,
      args: {'arg': valueId, 'objectGroup': _objectGroup, 'subtreeDepth': '2'},
    );
    final result = response?['result'];
    if (result is! Map) return null;
    return Map<String, Object?>.from(result);
  }

  /// Select the widget in the running app, which highlights it on the device.
  Future<void> selectWidget(String valueId) async {
    await _callExtension(
      Ext.setSelectionById,
      args: {'arg': valueId, 'objectGroup': _objectGroup},
    );
  }

  /// Ask dart:io to record HTTP traffic, which is what fills the network view.
  ///
  /// Nothing is recorded before this: the profiler is off by default, and a
  /// request issued while it was off is never reported, not even in hindsight.
  Future<String?> enableHttpProfiling() async {
    if (!httpProfiling) return 'recording is off in the plugin config';
    if (!networkReady) return 'this app does not expose the dart:io profiler';
    try {
      final response = await _callExtension(
        Ext.httpTimelineLogging,
        args: {'enabled': 'true'},
      );
      httpProfilingEnabled = response?['enabled'] == true;
      onChange();
      return httpProfilingEnabled ? null : 'the app refused to record traffic';
    } on Exception catch (error) {
      return _short(error);
    }
  }

  /// Fetch what changed since the last poll and merge it into [calls].
  ///
  /// The profiler answers with its own clock, and that timestamp is what the
  /// next poll asks from: a device whose clock differs from this machine's would
  /// otherwise be asked for a window that never matches.
  Future<String?> pollHttpCalls() async {
    if (!networkReady) return 'this app does not expose the dart:io profiler';
    try {
      final since = profileMicros;
      final response = await _callExtension(
        Ext.httpProfile,
        args: {if (since != null) 'updatedSince': '$since'},
      );
      if (response == null) return 'not connected';
      profileMicros = response['timestamp'] as int? ?? profileMicros;
      final requests = response['requests'];
      if (requests is! List) return null;
      var changed = false;
      for (final entry in requests) {
        if (entry is! Map) continue;
        final call = HttpCall.fromJson(Map<String, Object?>.from(entry));
        if (call.id.isEmpty) continue;
        _callsById[call.id] = call;
        changed = true;
      }
      if (!changed) return null;
      while (_callsById.length > _callLimit) {
        _callsById.remove(_callsById.keys.first);
      }
      calls = List.unmodifiable(_callsById.values);
      onChange();
      return null;
    } on Exception catch (error) {
      return _short(error);
    }
  }

  /// One call with its bodies, which the list form does not carry.
  Future<HttpCallDetail?> fetchHttpCall(String id) async {
    final response = await _callExtension(
      Ext.httpProfileRequest,
      args: {'id': id},
    );
    if (response == null) return null;
    return HttpCallDetail.fromJson(response);
  }

  /// Drop the recorded traffic, in the app as well as here.
  Future<String?> clearHttpCalls() async {
    _resetCalls();
    onChange();
    if (!networkReady) return null;
    try {
      await _callExtension(Ext.clearHttpProfile);
      return null;
    } on Exception catch (error) {
      return _short(error);
    }
  }

  void _resetCalls() {
    _callsById.clear();
    calls = const [];
    profileMicros = null;
    httpProfilingEnabled = false;
  }

  Future<void> refreshToggles() async {
    final next = <String, bool>{};
    for (final toggle in DebugToggle.all) {
      if (!extensionRpcs.contains(toggle.method)) continue;
      try {
        final response = await _callExtension(toggle.method);
        next[toggle.key] = response?['enabled'] == 'true';
      } on Exception {
        continue;
      }
    }
    toggleStates = next;
    onChange();
  }

  Future<String?> setToggle(DebugToggle toggle, {required bool enabled}) async {
    if (!extensionRpcs.contains(toggle.method)) {
      return '${toggle.label} is not available in this build';
    }
    try {
      final response = await _callExtension(
        toggle.method,
        args: {'enabled': '$enabled'},
      );
      toggleStates[toggle.key] = response?['enabled'] == 'true';
      onChange();
      return null;
    } on Exception catch (error) {
      return _short(error);
    }
  }

  static String _short(Object error) {
    if (error is RPCError) return error.message;
    if (error is TimeoutException) return 'timed out';
    final text = error.toString().replaceAll('\n', ' ');
    return text.length > 160 ? '${text.substring(0, 157)}...' : text;
  }
}
