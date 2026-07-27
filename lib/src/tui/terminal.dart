import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Anything read from the terminal: a key press or a mouse gesture.
sealed class TermEvent {
  const TermEvent();
}

/// One decoded key press. Named keys carry a name like `up` or `enter`;
/// everything else carries the literal character in [name].
class Key extends TermEvent {
  const Key(this.name);

  final String name;

  bool get isChar => name.runes.length == 1;

  @override
  String toString() => name;
}

enum MouseKind { press, release, wheelUp, wheelDown, other }

/// One mouse gesture, in zero-based screen coordinates.
class Mouse extends TermEvent {
  const Mouse({
    required this.kind,
    required this.column,
    required this.row,
    this.button = 0,
  });

  final MouseKind kind;

  /// Zero-based, so they index straight into a rendered frame.
  final int column;
  final int row;

  final int button;

  bool get isLeftPress => kind == MouseKind.press && button == 0;

  @override
  String toString() => '${kind.name}@$column,$row';
}

/// The alternate-screen surface the sidebar draws on.
///
/// Frames are full-height lists of rows. Only rows that changed since the last
/// frame are written, which keeps a log tail smooth without any flicker.
class Terminal {
  Terminal({Stdin? input, Stdout? output, this.mouse = true})
    : _input = input ?? stdin,
      _output = output ?? stdout;

  final Stdin _input;
  final Stdout _output;

  /// Whether to ask the terminal for click and wheel reports.
  ///
  /// Capturing the mouse is what makes the tabs clickable, and it is also what
  /// takes click-drag text selection away from the pane, so it is a setting.
  final bool mouse;

  List<String> _previous = [];
  bool _entered = false;
  StreamSubscription<List<int>>? _inputSubscription;
  final _keys = StreamController<Key>.broadcast();
  final _mice = StreamController<Mouse>.broadcast();
  final _resizes = StreamController<void>.broadcast();
  final _signals = <StreamSubscription<ProcessSignal>>[];

  /// Falls back to a conventional size when the pty reports none.
  int get columns => _output.hasTerminal ? _output.terminalColumns : 80;
  int get rows => _output.hasTerminal ? _output.terminalLines : 24;

  Stream<Key> get keys => _keys.stream;
  Stream<Mouse> get clicks => _mice.stream;
  Stream<void> get resizes => _resizes.stream;

  void enter() {
    if (_entered) return;
    _entered = true;
    if (_input.hasTerminal) {
      _input.echoMode = false;
      _input.lineMode = false;
    }
    // Alternate screen, hidden cursor, cleared.
    _output.write('\x1b[?1049h\x1b[?25l\x1b[2J');
    // Button reports in SGR encoding: no motion tracking, so the terminal only
    // speaks up on a click or a wheel turn.
    if (mouse) _output.write('\x1b[?1000h\x1b[?1006h');
    _inputSubscription = _input.listen(_onBytes);
    _signals.add(
      ProcessSignal.sigwinch.watch().listen((_) {
        _previous = [];
        _resizes.add(null);
      }),
    );
    for (final signal in [ProcessSignal.sigint, ProcessSignal.sigterm]) {
      _signals.add(
        signal.watch().listen((_) {
          leave();
          exit(0);
        }),
      );
    }
  }

  void leave() {
    if (!_entered) return;
    _entered = false;
    for (final subscription in _signals) {
      subscription.cancel();
    }
    _signals.clear();
    _inputSubscription?.cancel();
    if (mouse) _output.write('\x1b[?1006l\x1b[?1000l');
    _output.write('\x1b[?25h\x1b[?1049l');
    if (_input.hasTerminal) {
      _input.echoMode = true;
      _input.lineMode = true;
    }
  }

  /// Force the next [draw] to repaint every row.
  void invalidate() => _previous = [];

  void draw(List<String> lines) {
    final buffer = StringBuffer();
    final height = rows;
    for (var row = 0; row < height; row++) {
      final line = row < lines.length ? lines[row] : '';
      if (row < _previous.length && _previous[row] == line) continue;
      buffer.write('\x1b[${row + 1};1H');
      buffer.write(line);
      buffer.write('\x1b[0m\x1b[K');
    }
    if (buffer.isNotEmpty) _output.write(buffer.toString());
    _previous = List<String>.generate(
      height,
      (row) => row < lines.length ? lines[row] : '',
    );
  }

  void _onBytes(List<int> bytes) {
    for (final event in decodeEvents(bytes)) {
      switch (event) {
        case Key():
          _keys.add(event);
        case Mouse():
          _mice.add(event);
      }
    }
  }
}

/// Recognises a double click: the same row clicked twice in quick succession.
///
/// An SGR mouse report carries no click count, so the pairing is ours to keep.
/// The context is what the click landed on, the overlay and the view, so that a
/// click in one list and a click in the next are never read as a pair.
class ClickTracker {
  ClickTracker({this.window = const Duration(milliseconds: 400)});

  final Duration window;

  String? _context;
  int? _item;
  DateTime? _at;

  bool isRepeat(String context, int item, DateTime at) {
    final previous = _at;
    final repeat =
        _context == context &&
        _item == item &&
        previous != null &&
        !at.isBefore(previous) &&
        at.difference(previous) <= window;
    _context = context;
    _item = item;
    // A pair is consumed, so three clicks are one double click and then one
    // single, rather than two overlapping pairs.
    _at = repeat ? null : at;
    return repeat;
  }
}

/// Key presses only, for callers and tests that do not care about the mouse.
List<Key> decodeKeys(List<int> bytes) =>
    decodeEvents(bytes).whereType<Key>().toList();

/// Decode a raw stdin chunk into terminal events.
///
/// Escape sequences arrive whole in practice; a lone escape byte at the end of a
/// chunk is reported as `esc`, which is what a user pressing escape expects.
List<TermEvent> decodeEvents(List<int> bytes) {
  final keys = <TermEvent>[];
  var index = 0;
  while (index < bytes.length) {
    final byte = bytes[index];
    if (byte == 0x1b) {
      final consumed = _decodeEscape(bytes, index, keys);
      index += consumed;
      continue;
    }
    switch (byte) {
      case 0x0d:
      case 0x0a:
        keys.add(const Key('enter'));
        index++;
      case 0x09:
        keys.add(const Key('tab'));
        index++;
      case 0x7f:
      case 0x08:
        keys.add(const Key('backspace'));
        index++;
      default:
        if (byte < 0x20) {
          keys.add(Key('ctrl-${String.fromCharCode(byte + 0x60)}'));
          index++;
        } else {
          final length = _utf8Length(byte);
          final end = (index + length).clamp(0, bytes.length);
          keys.add(
            Key(utf8.decode(bytes.sublist(index, end), allowMalformed: true)),
          );
          index = end;
        }
    }
  }
  return keys;
}

int _decodeEscape(List<int> bytes, int start, List<TermEvent> keys) {
  if (start + 1 >= bytes.length) {
    keys.add(const Key('esc'));
    return 1;
  }
  final second = bytes[start + 1];
  if (second != 0x5b && second != 0x4f) {
    keys.add(const Key('esc'));
    return 1;
  }
  var index = start + 2;
  final parameters = StringBuffer();
  while (index < bytes.length &&
      (bytes[index] >= 0x30 && bytes[index] <= 0x3f)) {
    parameters.writeCharCode(bytes[index]);
    index++;
  }
  if (index >= bytes.length) {
    keys.add(const Key('esc'));
    return 1;
  }
  final finalByte = String.fromCharCode(bytes[index]);
  final consumed = index - start + 1;

  // SGR mouse report: ESC [ < button ; column ; row M (press) or m (release).
  if ((finalByte == 'M' || finalByte == 'm') &&
      parameters.toString().startsWith('<')) {
    final mouse = _decodeMouse(parameters.toString(), finalByte == 'M');
    if (mouse != null) keys.add(mouse);
    return consumed;
  }

  final named = switch (finalByte) {
    'A' => 'up',
    'B' => 'down',
    'C' => 'right',
    'D' => 'left',
    'H' => 'home',
    'F' => 'end',
    'Z' => 'shift-tab',
    '~' => switch (parameters.toString()) {
      '1' => 'home',
      '4' => 'end',
      '5' => 'pageup',
      '6' => 'pagedown',
      _ => null,
    },
    _ => null,
  };
  if (named != null) keys.add(Key(named));
  return consumed;
}

/// `<button;column;row` from an SGR report, into a [Mouse].
///
/// Wheel turns arrive as buttons 64 and 65. The low two bits of a button carry
/// which one it is, the higher bits carry modifiers, and both are reported the
/// same way for a press and a release, which the final byte distinguishes.
Mouse? _decodeMouse(String parameters, bool pressed) {
  final parts = parameters.substring(1).split(';');
  if (parts.length < 3) return null;
  final code = int.tryParse(parts[0]);
  final column = int.tryParse(parts[1]);
  final row = int.tryParse(parts[2]);
  if (code == null || column == null || row == null) return null;
  final kind = switch (code) {
    64 => MouseKind.wheelUp,
    65 => MouseKind.wheelDown,
    _ when code >= 66 => MouseKind.other,
    _ => pressed ? MouseKind.press : MouseKind.release,
  };
  return Mouse(
    kind: kind,
    button: code & 0x03,
    // SGR coordinates are one-based.
    column: column - 1,
    row: row - 1,
  );
}

int _utf8Length(int byte) {
  if (byte >= 0xf0) return 4;
  if (byte >= 0xe0) return 3;
  if (byte >= 0xc0) return 2;
  return 1;
}
