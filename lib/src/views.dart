import 'app_state.dart';
import 'diagnostics.dart';
import 'models.dart';
import 'session.dart';
import 'tui/style.dart';

/// The whole frame, as one row per terminal line.
///
/// Rendering is a pure function of the state, so a view can be checked in a
/// test by inspecting the strings it produces.
List<String> renderFrame(AppState state, int width, int height) {
  if (width < 8 || height < 4) return List.filled(height, '');
  final rows = <String>[_header(state, width), _tabs(state, width)];
  final bodyHeight = height - 3;
  rows.addAll(_body(state, width, bodyHeight));
  while (rows.length < height - 1) {
    rows.add('');
  }
  rows.add(_statusBar(state, width));
  return rows.take(height).toList();
}

String _header(AppState state, int width) {
  final line = LineBuilder(width);
  line.add(' flutter ', Style.boldReverse);
  line.add(' ');
  final target = state.target;
  final session = state.session;
  if (target == null) {
    line.addEllipsized(
      state.scanVisible ? 'scanning panes…' : 'no running app',
      Style.dim,
    );
  } else {
    line.addEllipsized(target.label, Style.bold);
  }
  final indicator = _stateIndicator(state, session);
  line.addRight('${indicator.$1} ', indicator.$2);
  return line.build();
}

(String, Style) _stateIndicator(AppState state, FlutterSession? session) {
  if (state.scanVisible) return ('scanning', Style.dim);
  if (session == null) return ('detached', Style.dim);
  return switch (session.state) {
    SessionState.connecting => ('connecting', Style.yellow),
    SessionState.connected => (
      session.errorCount > 0 ? '${session.errorCount} err' : 'live',
      session.errorCount > 0 ? Style.boldRed : Style.green,
    ),
    SessionState.reloading => ('reloading', Style.boldYellow),
    SessionState.disconnected => ('disconnected', Style.red),
    SessionState.failed => ('failed', Style.boldRed),
  };
}

String _tabs(AppState state, int width) {
  final line = LineBuilder(width);
  for (final view in View.values) {
    final count = switch (view) {
      View.logs => state.visibleLogs.length,
      View.errors => state.errors.length,
      View.inspector => state.flatTree.length,
      View.info => 0,
    };
    final label = count > 0 ? ' ${view.label} $count ' : ' ${view.label} ';
    line.add(label, view == state.view ? Style.reverse : Style.dim);
    line.add(' ');
  }
  return line.build();
}

List<String> _body(AppState state, int width, int height) {
  if (height <= 0) return const [];
  return switch (state.overlay) {
    Overlay.help => _pad(_helpBody(width), height),
    Overlay.toggles => _pad(_togglesBody(state, width), height),
    Overlay.targets => _pad(_targetsBody(state, width), height),
    Overlay.errorDetail => _pad(_errorDetailBody(state, width, height), height),
    Overlay.widgetDetail => _pad(
      _widgetDetailBody(state, width, height),
      height,
    ),
    Overlay.none => _pad(_viewBody(state, width, height), height),
  };
}

List<String> _viewBody(AppState state, int width, int height) {
  final session = state.session;
  if (session == null || !session.isConnected) {
    return _disconnectedBody(state, width);
  }
  return switch (state.view) {
    View.logs => _logsBody(state, width, height),
    View.errors => _errorsBody(state, width, height),
    View.inspector => _inspectorBody(state, width, height),
    View.info => _infoBody(state, width),
  };
}

List<String> _disconnectedBody(AppState state, int width) {
  final lines = <String>[''];
  final session = state.session;
  if (state.scanVisible) {
    lines.add(_text('  Looking for a Dart VM Service…', width, Style.dim));
    return lines;
  }
  if (session != null && session.state == SessionState.failed) {
    lines.add(_text('  Could not attach', width, Style.boldRed));
    lines.add('');
    for (final line in _wrap(session.failure ?? 'unknown error', width - 4)) {
      lines.add(_text('  $line', width, Style.dim));
    }
  } else if (session != null && session.state == SessionState.disconnected) {
    lines.add(_text('  The app disconnected', width, Style.yellow));
  } else {
    lines.add(_text('  No running Flutter app found', width, Style.bold));
    lines.add('');
    for (final line in _wrap(
      'Start one in a herdr pane with flutter run, then press D to rescan. '
      'The sidebar reads each pane\'s output to find the VM Service URI it '
      'prints, so the app can run anywhere in this workspace.',
      width - 4,
    )) {
      lines.add(_text('  $line', width, Style.dim));
    }
  }
  final error = state.discoveryError;
  if (error != null) {
    lines.add('');
    for (final line in _wrap(error, width - 4)) {
      lines.add(_text('  $line', width, Style.red));
    }
  }
  lines.add('');
  lines.add(_text('  D  rescan    q  quit', width, Style.dim));
  return lines;
}

/// A log entry as the display lines it occupies, newest entries last.
List<String> _logDisplayLines(AppState state, int width) {
  final showTime = width >= 64;
  final lines = <String>[];
  for (final entry in state.visibleLogs) {
    final prefix = showTime ? '${_clock(entry.time)} ' : '';
    final style = switch (entry.source) {
      LogSource.stderr => Style.red,
      LogSource.developer => Style.cyan,
      LogSource.session => Style.magenta,
      LogSource.stdout => Style.none,
    };
    final body = _wrap(entry.text, width - prefix.length - 4);
    for (final (index, part) in body.indexed) {
      final line = LineBuilder(width);
      if (index == 0) {
        line.add(prefix, Style.brightBlack);
        line.add('${entry.source.tag} ', style);
      } else {
        line.add(' ' * (prefix.length + 4), Style.none);
      }
      line.add(part, entry.source == LogSource.stderr ? Style.red : Style.none);
      lines.add(line.build());
    }
  }
  return lines;
}

List<String> _logsBody(AppState state, int width, int height) {
  final all = _logDisplayLines(state, width);
  if (all.isEmpty) {
    final message = state.filter.isEmpty
        ? '  Waiting for output from the app…'
        : '  No line matches "${state.filter}"';
    return ['', _text(message, width, Style.dim)];
  }
  final maxScroll = (all.length - height).clamp(0, all.length);
  final scroll = state.logScroll.clamp(0, maxScroll);
  final end = all.length - scroll;
  final start = (end - height).clamp(0, all.length);
  return all.sublist(start, end);
}

List<String> _errorsBody(AppState state, int width, int height) {
  if (state.errors.isEmpty) {
    return [
      '',
      _text('  No errors since the sidebar attached', width, Style.dim),
      '',
      _text(
        '  Flutter.Error events land here as they happen.',
        width,
        Style.dim,
      ),
    ];
  }
  final rows = <String>[];
  final selected = state.errorIndex.clamp(0, state.errors.length - 1);
  final start = (selected - height ~/ 2).clamp(
    0,
    (state.errors.length - height).clamp(0, state.errors.length),
  );
  for (
    var index = start;
    index < state.errors.length && rows.length < height;
    index++
  ) {
    final error = state.errors[index];
    final isSelected = index == selected;
    final line = LineBuilder(width);
    line.add(isSelected ? '›' : ' ', Style.boldRed);
    line.add('${_clock(error.time)} ', Style.brightBlack);
    line.addEllipsized(error.summary, isSelected ? Style.boldRed : Style.red);
    rows.add(line.build(fill: isSelected ? Style.none : Style.none));
    if (isSelected) {
      final location = error.location;
      if (location != null) {
        final detail = LineBuilder(width);
        detail.add('   ', Style.none);
        detail.addEllipsized(
          location.display(root: state.repoRoot),
          Style.brightBlack,
        );
        if (rows.length < height) rows.add(detail.build());
      }
    }
  }
  return rows;
}

List<String> _inspectorBody(AppState state, int width, int height) {
  if (state.loadingTree) {
    return ['', _text('  Fetching the widget tree…', width, Style.dim)];
  }
  final error = state.treeError;
  if (error != null) {
    return [
      '',
      _text('  Inspector unavailable', width, Style.boldYellow),
      '',
      ..._wrap(
        error,
        width - 4,
      ).map((line) => _text('  $line', width, Style.dim)),
    ];
  }
  if (state.flatTree.isEmpty) {
    return [
      '',
      _text('  No widget tree yet', width, Style.dim),
      '',
      _text('  g  fetch it', width, Style.dim),
    ];
  }
  final rows = <String>[];
  final selected = state.nodeIndex.clamp(0, state.flatTree.length - 1);
  final start = (selected - height ~/ 2).clamp(
    0,
    (state.flatTree.length - height).clamp(0, state.flatTree.length),
  );
  for (
    var index = start;
    index < state.flatTree.length && rows.length < height;
    index++
  ) {
    final node = state.flatTree[index];
    final isSelected = index == selected;
    final line = LineBuilder(width);
    final id = node.valueId;
    final marker = !node.hasChildren
        ? ' '
        : (id != null && state.collapsed.contains(id) ? '▸' : '▾');
    line.add(isSelected ? '›' : ' ', Style.boldCyan);
    line.add('  ' * (node.depth.clamp(0, (width ~/ 4))), Style.none);
    line.add('$marker ', Style.brightBlack);
    line.addEllipsized(
      node.description,
      node.createdByLocalProject
          ? (isSelected ? Style.boldCyan : Style.none)
          : Style.dim,
    );
    final preview = node.textPreview;
    if (preview != null && preview.isNotEmpty && line.remaining > 6) {
      line.add(' "', Style.brightBlack);
      line.addEllipsized(preview.replaceAll('\n', ' '), Style.green);
      line.add('"', Style.brightBlack);
    }
    rows.add(line.build());
  }
  return rows;
}

List<String> _infoBody(AppState state, int width) {
  final session = state.session;
  final target = state.target;
  final rows = <String>[];
  void entry(String key, String? value, [Style style = Style.none]) {
    if (value == null || value.isEmpty) return;
    final line = LineBuilder(width);
    line.add(' ${key.padRight(14)}', Style.brightBlack);
    line.addEllipsized(value, style);
    rows.add(line.build());
  }

  entry('app', target?.label, Style.bold);
  entry('service', target?.serviceUri.toString());
  entry('found via', target?.origin);
  entry('owner pane', target?.ownerPaneId ?? 'none (reload uses the protocol)');
  rows.add('');
  entry('isolate', session?.isolateName ?? session?.isolateId ?? 'none');
  entry('dart vm', session?.vmInfo['version']?.toString());
  entry('platform', session?.vmInfo['operatingSystem']?.toString());
  entry('cpu', session?.vmInfo['targetCPU']?.toString());
  entry('pid', session?.vmInfo['pid']?.toString());
  final version = session?.flutterVersion;
  if (version != null && version.isNotEmpty) {
    rows.add('');
    entry('flutter', version['frameworkVersion']?.toString());
    entry('channel', version['channel']?.toString());
    entry('framework', version['frameworkRevisionShort']?.toString());
    entry('engine', version['engineRevisionShort']?.toString());
    entry('dart sdk', version['dartSdkVersion']?.toString());
  }
  rows.add('');
  entry('hot reload', session?.canReload == true ? 'protocol' : 'unavailable');
  entry(
    'hot restart',
    session?.canRestart == true ? 'protocol' : 'unavailable',
  );
  entry(
    'inspector',
    session?.inspectorReady == true ? 'ready' : 'not registered',
  );
  entry('frames seen', session == null ? null : '${session.frames}');
  final build = session?.lastBuildMs;
  final raster = session?.lastRasterMs;
  if (build != null || raster != null) {
    entry(
      'last frame',
      'build ${build?.toStringAsFixed(1) ?? '-'} ms, '
          'raster ${raster?.toStringAsFixed(1) ?? '-'} ms',
    );
  }
  if (state.targets.length > 1) {
    rows.add('');
    entry('other apps', '${state.targets.length - 1} (press D)');
  }
  return rows;
}

List<String> _helpBody(int width) {
  const entries = <(String, String)>[
    ('1 2 3 4 / tab', 'switch view'),
    ('j k up down', 'move'),
    ('g G', 'top, bottom (inspector: fetch tree)'),
    ('pgup pgdn', 'page'),
    ('enter', 'open detail, expand or collapse a node'),
    ('r', 'hot reload'),
    ('R', 'hot restart'),
    ('s', 'send what is on screen to the agent'),
    ('y', 'copy the same capture to the clipboard'),
    ('t', 'debug toggles'),
    ('x', 'select the widget in the app (inspector)'),
    ('f', 'summary tree or full tree (inspector)'),
    ('/', 'filter the log, esc clears'),
    ('c', 'clear the log'),
    ('D', 'pick an app to attach to'),
    ('ctrl-l', 'redraw'),
    ('? esc', 'this help, close'),
    ('q', 'quit'),
  ];
  final rows = <String>['', _text(' Keys', width, Style.bold), ''];
  for (final (keys, description) in entries) {
    final line = LineBuilder(width);
    line.add(' ${keys.padRight(14)}', Style.boldCyan);
    line.addEllipsized(description, Style.none);
    rows.add(line.build());
  }
  return rows;
}

List<String> _togglesBody(AppState state, int width) {
  final session = state.session;
  final rows = <String>['', _text(' Debug toggles', width, Style.bold), ''];
  for (final toggle in DebugToggle.all) {
    final available = session?.extensionRpcs.contains(toggle.method) ?? false;
    final enabled = session?.toggleStates[toggle.key] ?? false;
    final line = LineBuilder(width);
    line.add(' ${toggle.key}  ', Style.boldCyan);
    line.add(enabled ? '[x] ' : '[ ] ', enabled ? Style.green : Style.dim);
    line.addEllipsized(toggle.label, available ? Style.none : Style.dim);
    if (!available) line.addRight('n/a ', Style.dim);
    rows.add(line.build());
  }
  rows.add('');
  rows.add(_text(' esc  close', width, Style.dim));
  return rows;
}

List<String> _targetsBody(AppState state, int width) {
  final rows = <String>['', _text(' Running apps', width, Style.bold), ''];
  if (state.targets.isEmpty) {
    rows.add(_text('  none found', width, Style.dim));
  }
  for (final (index, target) in state.targets.indexed) {
    final isCursor = index == state.targetCursor;
    final isCurrent = index == state.targetIndex;
    final line = LineBuilder(width);
    line.add(isCursor ? '›' : ' ', Style.boldCyan);
    line.add(isCurrent ? '● ' : '  ', Style.green);
    line.addEllipsized(target.label, isCursor ? Style.bold : Style.none);
    rows.add(line.build());
    final detail = LineBuilder(width);
    detail.add('    ', Style.none);
    detail.addEllipsized(
      '${target.serviceUri.host}:${target.serviceUri.port}'
      '${target.ownerPaneId == null ? '' : ' · ${target.ownerPaneId}'}',
      Style.brightBlack,
    );
    rows.add(detail.build());
  }
  rows.add('');
  rows.add(
    _text(' enter  attach     D  rescan     esc  close', width, Style.dim),
  );
  return rows;
}

List<String> _errorDetailBody(AppState state, int width, int height) {
  final error = state.selectedError;
  if (error == null) return [_text('  no error selected', width, Style.dim)];
  final lines = <String>[];
  final location = error.location;
  if (location != null) {
    lines.add(
      _text(
        ' ${location.display(root: state.repoRoot)}',
        width,
        Style.boldCyan,
      ),
    );
    lines.add('');
  }
  for (final raw in const LineSplitterLite().split(error.detail)) {
    for (final part in _wrap(raw, width - 1)) {
      lines.add(_text(' $part', width, _detailStyle(raw)));
    }
  }
  return _scroll(lines, state.detailScroll, height);
}

List<String> _widgetDetailBody(AppState state, int width, int height) {
  final node = state.selectedNode;
  if (node == null) return [_text('  no widget selected', width, Style.dim)];
  final lines = <String>[_text(' ${node.description}', width, Style.bold)];
  final location = node.location;
  if (location != null) {
    lines.add(
      _text(
        ' ${location.display(root: state.repoRoot)}',
        width,
        Style.boldCyan,
      ),
    );
  }
  lines.add('');
  final details = state.nodeDetails;
  if (details == null) {
    lines.add(_text('  Fetching properties…', width, Style.dim));
  } else {
    for (final raw in const LineSplitterLite().split(
      renderNode(details, maxDepth: 4),
    )) {
      for (final part in _wrap(raw, width - 1)) {
        lines.add(_text(' $part', width, Style.none));
      }
    }
  }
  return _scroll(lines, state.detailScroll, height);
}

Style _detailStyle(String line) {
  final trimmed = line.trimLeft();
  if (trimmed.startsWith('══') || trimmed.startsWith('The following')) {
    return Style.boldRed;
  }
  if (trimmed.startsWith('#') || trimmed.startsWith('at ')) return Style.dim;
  return Style.none;
}

String _statusBar(AppState state, int width) {
  final line = LineBuilder(width);
  final status = state.status;
  if (state.editingFilter) {
    line.add(' filter ', Style.boldReverse);
    line.add(' ${state.filter}', Style.none);
    line.add('▌', Style.boldCyan);
    return line.build();
  }
  if (status != null) {
    line.add(
      ' ${state.statusIsError ? '!' : '·'} ',
      state.statusIsError ? Style.boldRed : Style.boldGreen,
    );
    line.addEllipsized(status, state.statusIsError ? Style.red : Style.none);
    return line.build();
  }
  final hints = switch (state.overlay) {
    Overlay.none => switch (state.view) {
      View.logs => 'r reload  R restart  s send  / filter  ? keys',
      View.errors => 'enter detail  s send  r reload  ? keys',
      View.inspector => 'enter fold  x select  d details  s send  ? keys',
      View.info => 'D apps  t toggles  r reload  ? keys',
    },
    _ => 'esc close  ? keys',
  };
  line.add(' ');
  line.addEllipsized(hints, Style.dim);
  return line.build();
}

List<String> _scroll(List<String> lines, int scroll, int height) {
  if (lines.length <= height) return lines;
  final start = scroll.clamp(0, lines.length - height);
  return lines.sublist(start, (start + height).clamp(0, lines.length));
}

List<String> _pad(List<String> rows, int height) {
  if (rows.length >= height) return rows.take(height).toList();
  return [...rows, ...List.filled(height - rows.length, '')];
}

String _text(String text, int width, Style style) {
  final line = LineBuilder(width);
  line.addEllipsized(text, style);
  return line.build();
}

/// Hard-wrap on width, breaking at spaces when there is one to break on.
List<String> _wrap(String text, int width) {
  if (width <= 1) return [text];
  final source = text.replaceAll('\t', '  ');
  if (source.runes.length <= width) return [source];
  final lines = <String>[];
  var rest = source;
  while (rest.runes.length > width) {
    final window = String.fromCharCodes(rest.runes.take(width));
    var cut = window.lastIndexOf(' ');
    if (cut < width ~/ 3) cut = width;
    lines.add(String.fromCharCodes(rest.runes.take(cut)).trimRight());
    rest = String.fromCharCodes(rest.runes.skip(cut)).trimLeft();
  }
  if (rest.isNotEmpty) lines.add(rest);
  return lines;
}

String _clock(DateTime time) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
}
