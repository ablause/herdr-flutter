# API notes

Facts this plugin depends on, each verified live rather than assumed. Verified on
2026-07-26 against herdr 0.7.x, Flutter 3.44.8 and Dart 3.12.2 on macOS.

## herdr CLI

Output is a JSON envelope on stdout: `{"id":…,"result":{…}}`, or
`{"error":{"code":…,"message":…}}`.

| command | used for |
| --- | --- |
| `herdr pane list [--workspace W]` | panes with `pane_id`, `tab_id`, `workspace_id`, `cwd`, `label`, `agent` |
| `herdr pane read <pane> --source recent-unwrapped --lines N --format text` | scrollback, to find the VM Service URI |
| `herdr pane send-text <pane> <text>` | literal text, no newline appended |
| `herdr pane close <pane>` | teardown of a sidebar pane |
| `herdr agent list` | agent panes only |
| `herdr agent focus <pane>` | move focus after a handoff |
| `herdr plugin pane open --plugin … --entrypoint sidebar …` | new pane id at `.result.plugin_pane.pane.pane_id` |

Notes worth keeping:

- **`herdr agent send` does not exist in this version.** reviewr's send path calls
  it and fails. The working equivalent is `herdr pane send-text`, which writes into
  a pane without submitting. `herdr agent prompt` exists but submits.
- Only panes carrying an `agent` field host an agent. A plugin sidebar has
  `agent_status: unknown` and no `agent` field.
- `--source recent-unwrapped` is the right snapshot for scraping: it does not fold
  long lines, so a URI never gets a line break inside it.
- `plugin pane close` only knows panes in the in-memory plugin registry, which does
  not survive a herdr restart. Plain `pane close` closes any pane by id.
- A pane's command resolves against the pane's cwd, not the plugin root, so the
  binary is invoked as `$HERDR_PLUGIN_ROOT/bin/herdr-flutter`.
- Plugin commands run with a minimal `PATH`; scripts prepend the usual bin dirs.
- Env for panes and commands: `HERDR_BIN_PATH`, `HERDR_PANE_ID`, `HERDR_TAB_ID`,
  `HERDR_WORKSPACE_ID`, `HERDR_PLUGIN_ROOT`, `HERDR_PLUGIN_CONFIG_DIR`,
  `HERDR_PLUGIN_STATE_DIR`, `HERDR_PLUGIN_CONTEXT_JSON`, `HERDR_PLUGIN_EVENT_JSON`.

## Dart VM Service

Connect with `convertToWebSocketUrl` then `vmServiceConnectUri`. The URI must be
kept exactly as `flutter run` printed it, trailing slash included, because the
websocket path is derived from it.

**Subscribe to a stream before calling `streamListen`.** The VM replays state as
events the moment a stream is listened to. The `Service` stream replays a
`ServiceRegistered` event for every already-registered service, so a listener
attached after `streamListen` misses all of them. This is what makes hot reload
appear unavailable when the order is wrong.

The `Logging` stream also replays its buffered records on subscribe, which is why
a log line printed before attach still shows up.

## Services registered by `flutter run`

The flutter tool registers these on the connection, with alias `Flutter Tools`.
The callable method name is client-prefixed, for example `s1.reloadSources`, so it
has to be read from the `ServiceRegistered` event rather than hardcoded.

| service | params |
| --- | --- |
| `reloadSources` | `isolateId` (string), `force` (bool), `pause` (bool), all required |
| `hotRestart` | `pause` (bool) |
| `flutterVersion` | none; returns `frameworkVersion`, `channel`, `frameworkRevisionShort`, `engineRevisionShort`, `dartSdkVersion` |
| `compileExpression`, `flutterMemoryInfo` | not used here |

This is why reload does not need to send `r` to a pane: the tool that recompiles is
reachable over the same socket. A hot restart replaces the isolate, so the isolate
id, the inspector object group and the error count all reset.

## Widget inspector

Extension names come from
`packages/flutter/lib/src/widgets/widget_inspector.dart`, prefixed with
`ext.flutter.inspector.`.

- `getRootWidgetTree` with `groupName`, `isSummaryTree`, `withPreviews`,
  `fullDetails`. All values are strings, since extension args are strings.
  **`fullDetails: 'false'` strips `creationLocation`**, so the tree loses every
  `file:line`. This plugin always asks for full details.
- `getDetailsSubtree` with `arg` (a `valueId`), `objectGroup`, `subtreeDepth`.
- `setSelectionById` with `arg`, `objectGroup`: highlights the widget on the device.
- `disposeGroup` with `objectGroup`: releases the object group.
- `show` is select-widget mode, `structuredErrors` toggles error events.

Node JSON of interest: `description`, `name`, `showName`, `level`, `type`,
`valueId`, `widgetRuntimeType`, `createdByLocalProject`, `creationLocation`
(`file`, `line`, `column`, `name`), `textPreview`, `properties`, `children`.

## Flutter.Error events

Posted on the `Extension` stream with `extensionKind: 'Flutter.Error'`.
`isStructuredErrorsEnabled()` defaults to true in debug on non-web, so nothing has
to be enabled: the events arrive as soon as the stream is listened to.

The event is the only channel, not an extra one. `WidgetInspectorService`
assigns `FlutterError.presentError = _reportStructuredError` when structured
errors are on, replacing the default handler that dumps to the console, and
`_reportStructuredError` ends at `postEvent('Flutter.Error', errorJson)` without
printing anything. A framework error therefore reaches neither `Stdout` nor
`Stderr`, which is why the log needs a marker of its own to stay in order.
(`packages/flutter/lib/src/widgets/widget_inspector.dart`, Flutter 3.44.)

Payload shape, from a real `RenderFlex overflowed` capture (see
`test/fixtures/flutter_error.json`):

- the root node describes the phase, for example `Exception caught by rendering
  library`, and carries no `level`
- `properties[]` holds the detail: an `ErrorDescription`, then an `ErrorSummary`
  with `level: 'summary'` which is the real headline, then `ErrorHint` nodes, then
  a `DiagnosticableTreeNode` with the offending render object
- `errorsSinceReload` counts from zero after each reload
- `renderedErrorText` is the full console text **only for the first error since the
  last reload**. Later ones get `Another exception was thrown: <summary>`, so their
  detail has to be rendered from the node tree.
- **there is no `creationLocation` anywhere in an error payload.** The position of
  the error-causing widget is written into a description string, as
  `Row Row:file:///…/main.dart:29:22`, so a `file:line` for an exception can only be
  recovered by parsing the text.

## HTTP profiler (`ext.dart.io.`)

Registered by `dart:io` rather than by Flutter, so it answers in any Dart VM and
is absent from a web build. Verified against Dart 3.12 on macOS.

- `httpEnableTimelineLogging` with `{'enabled': 'true'}` starts the recording and
  answers `{"type": "HttpTimelineLoggingState", "enabled": true}`. Note the value
  is a real boolean here, where the `ext.flutter.` toggles answer with the
  strings `"true"` and `"false"`.
- **nothing issued before the recording was switched on is ever reported.** The
  profiler is off by default and keeps no history, so attaching to an app that
  has been running for an hour starts from an empty list.
- `getHttpProfile` answers `{'type', 'timestamp', 'requests': [...]}`, where
  `timestamp` is the **app's own clock** in microseconds. Passing it back as
  `updatedSince` on the next call asks for what changed since, which is what
  makes polling cheap and is immune to a device whose clock differs from this
  machine's. Both parameters are strings: the handler receives
  `Map<String, String>` and parses them itself.
- a request appears as soon as it starts. `response.statusCode` and
  `response.endTime` stay null while it is in flight, and a request that never
  reached the server carries `request.error` instead.
- an unknown response length is reported as `contentLength: -1`, which is the
  normal case for a chunked answer, not an error.
- header values are lists, since a header can repeat.
- `events[]` timestamps the steps of the call: `Connection established`,
  `Request sent`, `Waiting (TTFB)`, `Content Download`.
- `getHttpProfileRequest` with `{'id': …}` is the only call that carries
  `requestBody` and `responseBody`, as byte lists.
- `clearHttpProfile` drops the recording. A hot restart drops it too, and the new
  isolate starts with the recording off, so it has to be switched on again.
- only traffic through `dart:io`'s `HttpClient` is seen, which covers
  `package:http` and dio. A platform view, a native SDK or an image fetched by
  the engine is invisible to it.

## Other service extensions used

Boolean toggles under `ext.flutter.`: `debugPaint`,
`debugPaintBaselinesEnabled`, `repaintRainbow`, `showPerformanceOverlay`,
`debugAllowBanner`, `invertOversizedImages`. Calling one with no args reads its
current value as `{"enabled": "true"|"false"}`; calling it with
`{'enabled': 'true'}` sets it. A toggle absent from the isolate's `extensionRPCs`
is not available in that build.

`Flutter.Frame` events carry `build` and `raster` in microseconds. They only
arrive while frames are being produced, so an idle app reports none.
