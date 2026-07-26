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
  // One row of chrome at the top and one at the bottom. The pane border already
  // carries the plugin's name, so nothing here repeats it.
  final rows = <String>[_tabs(state, width)];
  rows.addAll(_body(state, width, height - 2));
  while (rows.length < height - 1) {
    rows.add('');
  }
  rows.add(_statusBar(state, width));
  return rows.take(height).toList();
}

/// One tab as drawn: its text and the columns it occupies.
class TabSpan {
  const TabSpan(this.view, this.text, this.start);

  final View view;
  final String text;
  final int start;

  int get end => start + text.length;
}

/// Where each tab sits on the top row, so a click can be mapped back to a view.
List<TabSpan> tabSpans(AppState state, int width) {
  // The app and its state matter more than full tab names, so the names give way
  // first, then disappear entirely, leaving the numbers that select them.
  final detail = width >= 52
      ? _TabDetail.counts
      : (width >= 34 ? _TabDetail.short : _TabDetail.numbers);
  final spans = <TabSpan>[];
  var start = 0;
  for (final view in View.values) {
    final count = switch (view) {
      View.logs => state.visibleLogs.length,
      View.errors => state.errors.length,
      View.inspector => state.flatTree.length,
      View.info => 0,
    };
    final label = switch (detail) {
      _TabDetail.counts =>
        count > 0
            ? '${view.index + 1} ${view.label}($count)'
            : '${view.index + 1} ${view.label}',
      _TabDetail.short => '${view.index + 1} ${view.short}',
      _TabDetail.numbers => '${view.index + 1}',
    };
    final text = ' $label ';
    spans.add(TabSpan(view, text, start));
    start += text.length;
  }
  return spans;
}

/// The view a click on the top row lands on, or null between or past the tabs.
View? tabAt(AppState state, int width, int column) {
  if (column >= width) return null;
  for (final span in tabSpans(state, width)) {
    if (column >= span.start && column < span.end) return span.view;
  }
  return null;
}

/// The numbered views on the left, what the sidebar is attached to on the right.
String _tabs(AppState state, int width) {
  final line = LineBuilder(width);
  for (final span in tabSpans(state, width)) {
    line.add(span.text, span.view == state.view ? Style.reverse : Style.dim);
  }

  final (label, word, style) = _attachment(state);
  final tail = label == null || line.remaining < label.length + word.length + 4
      ? word
      : '$label · $word';
  line.addRight('$tail ', style);
  return line.build();
}

enum _TabDetail { counts, short, numbers }

/// What the sidebar is attached to, as one phrase: the app and its state.
(String?, String, Style) _attachment(AppState state) {
  if (state.scanVisible) return (null, 'scanning', Style.dim);
  final target = state.target;
  final session = state.session;
  if (target == null || session == null) return (null, 'no app', Style.dim);
  final label = target.label;
  return switch (session.state) {
    SessionState.connecting => (label, 'connecting', Style.yellow),
    SessionState.connected =>
      session.errorCount > 0
          ? (label, '${session.errorCount} err', Style.boldRed)
          : (label, 'live', Style.green),
    SessionState.reloading => (label, 'reloading', Style.boldYellow),
    SessionState.disconnected => (label, 'lost', Style.red),
    SessionState.failed => (label, 'failed', Style.boldRed),
  };
}

List<String> _body(AppState state, int width, int height) {
  if (height <= 0) return const [];
  state.hitRows = [];
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
  // The keys live in the status bar, so they are not repeated here.
  return lines;
}

/// A log entry as the display lines it occupies, newest entries last.
List<String> _logDisplayLines(AppState state, int width) {
  final showTime = width >= 64;
  final lines = <String>[];
  for (final entry in state.visibleLogs) {
    final prefix = showTime ? '${_clock(entry.time)} ' : '';
    final tagStyle = switch (entry.source) {
      LogSource.stderr => Style.red,
      LogSource.developer => Style.cyan,
      LogSource.session => Style.magenta,
      LogSource.stdout => Style.none,
    };
    // The colour of the text comes from what the app said about the line: the
    // level of a developer.log record, or the stream it came out of.
    final textStyle = entry.isSevere || entry.source == LogSource.stderr
        ? Style.red
        : (entry.isWarning ? Style.yellow : Style.none);
    final name = entry.name;
    final label = name == null ? '' : '$name ';
    final indent = prefix.length + 4;
    final body = _wrap(entry.text, width - indent - label.length);
    for (final (index, part) in body.indexed) {
      final line = LineBuilder(width);
      if (index == 0) {
        line.add(prefix, Style.brightBlack);
        line.add('${entry.source.tag} ', tagStyle);
        if (label.isNotEmpty) line.add(label, Style.boldCyan);
      } else {
        line.add(' ' * indent, Style.none);
      }
      line.add(part, textStyle);
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
    line.add(isSelected ? '› ' : '  ', Style.boldRed);
    line.add('${_clock(error.time)} ', Style.brightBlack);
    line.addEllipsized(error.summary, isSelected ? Style.boldRed : Style.red);
    rows.add(line.build());
    state.hitRows.add(index);
    if (isSelected) {
      final location = error.location;
      if (location != null) {
        final detail = LineBuilder(width);
        detail.add('    ', Style.none);
        detail.addEllipsized(
          location.display(root: state.repoRoot),
          Style.brightBlack,
        );
        if (rows.length < height) {
          rows.add(detail.build());
          state.hitRows.add(index);
        }
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
    line.add(isSelected ? '› ' : '  ', Style.boldCyan);
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
    state.hitRows.add(index);
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
    ('click', 'switch view, or pick a row'),
    ('wheel', 'scroll, or move the selection'),
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
  state.hitRows.addAll(List<int?>.filled(rows.length, null));
  for (final (index, toggle) in DebugToggle.all.indexed) {
    final available = session?.extensionRpcs.contains(toggle.method) ?? false;
    final enabled = session?.toggleStates[toggle.key] ?? false;
    final line = LineBuilder(width);
    line.add(' ${toggle.key}  ', Style.boldCyan);
    line.add(enabled ? '[x] ' : '[ ] ', enabled ? Style.green : Style.dim);
    line.addEllipsized(toggle.label, available ? Style.none : Style.dim);
    if (!available) line.addRight('n/a ', Style.dim);
    rows.add(line.build());
    state.hitRows.add(index);
  }
  rows.add('');
  rows.add(_text(' esc  close', width, Style.dim));
  state.hitRows.addAll([null, null]);
  return rows;
}

List<String> _targetsBody(AppState state, int width) {
  final rows = <String>['', _text(' Running apps', width, Style.bold), ''];
  state.hitRows.addAll(List<int?>.filled(rows.length, null));
  if (state.targets.isEmpty) {
    rows.add(_text('  none found', width, Style.dim));
    state.hitRows.add(null);
  }
  for (final (index, target) in state.targets.indexed) {
    final isCursor = index == state.targetCursor;
    final isCurrent = index == state.targetIndex;
    final line = LineBuilder(width);
    line.add(isCursor ? '› ' : '  ', Style.boldCyan);
    line.add(isCurrent ? '● ' : '  ', Style.green);
    line.addEllipsized(target.label, isCursor ? Style.bold : Style.none);
    rows.add(line.build());
    state.hitRows.add(index);
    final detail = LineBuilder(width);
    detail.add('    ', Style.none);
    detail.addEllipsized(
      '${target.serviceUri.host}:${target.serviceUri.port}'
      '${target.ownerPaneId == null ? '' : ' · ${target.ownerPaneId}'}',
      Style.brightBlack,
    );
    rows.add(detail.build());
    state.hitRows.add(index);
  }
  rows.add('');
  rows.add(
    _text(' enter  attach     D  rescan     esc  close', width, Style.dim),
  );
  state.hitRows.addAll([null, null]);
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
  final attached = state.session?.isConnected ?? false;
  // A narrow pane gets a shorter list rather than a sentence cut mid-word.
  final compact = width < 64;
  final hints = switch (state.overlay) {
    Overlay.none when !attached => 'D rescan',
    Overlay.none => switch (state.view) {
      View.logs =>
        compact
            ? 'r reload  s send  / filter'
            : 'r reload  R restart  s send  / filter',
      View.errors =>
        compact ? 'enter detail  s send' : 'enter detail  s send  r reload',
      View.inspector =>
        compact
            ? 'enter fold  s send'
            : 'enter fold  x select  d details  s send',
      View.info =>
        compact ? 'D apps  t toggles' : 'D apps  t toggles  r reload',
    },
    _ => 'esc close',
  };

  // Quitting stays pinned to the right whatever the view, the way reviewr keeps
  // its own trailing group, so the hints are budgeted around it.
  const quit = 'q quit ';
  line.add(' ');
  final budget = line.remaining - quit.length - 1;
  final text = hints.length + 8 <= budget ? '$hints  ? keys' : hints;
  line.addEllipsized(_clip(text, budget), Style.dim);
  if (line.remaining >= quit.length) line.addRight(quit, Style.dim);
  return line.build();
}

String _clip(String text, int max) {
  if (max <= 1) return '';
  final runes = text.runes;
  if (runes.length <= max) return text;
  return '${String.fromCharCodes(runes.take(max - 1))}…';
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
  // A line that arrived already coloured is measured on its visible characters
  // and cut between them, never inside an escape sequence.
  if (hasEscapes(source)) {
    final wrapped = <String>[];
    var left = source;
    while (visibleWidth(left) > width) {
      wrapped.add(takeVisible(left, width));
      left = dropVisible(left, width);
    }
    if (left.isNotEmpty) wrapped.add(left);
    return wrapped;
  }
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
