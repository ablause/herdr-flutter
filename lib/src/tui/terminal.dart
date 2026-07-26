import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// One decoded key press. Named keys carry a name like `up` or `enter`;
/// everything else carries the literal character in [name].
class Key {
  const Key(this.name);

  final String name;

  bool get isChar => name.runes.length == 1;

  @override
  String toString() => name;
}

/// The alternate-screen surface the sidebar draws on.
///
/// Frames are full-height lists of rows. Only rows that changed since the last
/// frame are written, which keeps a log tail smooth without any flicker.
class Terminal {
  Terminal({Stdin? input, Stdout? output})
    : _input = input ?? stdin,
      _output = output ?? stdout;

  final Stdin _input;
  final Stdout _output;

  List<String> _previous = [];
  bool _entered = false;
  StreamSubscription<List<int>>? _inputSubscription;
  final _keys = StreamController<Key>.broadcast();
  final _resizes = StreamController<void>.broadcast();
  final _signals = <StreamSubscription<ProcessSignal>>[];

  /// Falls back to a conventional size when the pty reports none.
  int get columns => _output.hasTerminal ? _output.terminalColumns : 80;
  int get rows => _output.hasTerminal ? _output.terminalLines : 24;

  Stream<Key> get keys => _keys.stream;
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
    for (final key in decodeKeys(bytes)) {
      _keys.add(key);
    }
  }
}

/// Decode a raw stdin chunk into key presses.
///
/// Escape sequences arrive whole in practice; a lone escape byte at the end of a
/// chunk is reported as `esc`, which is what a user pressing escape expects.
List<Key> decodeKeys(List<int> bytes) {
  final keys = <Key>[];
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

int _decodeEscape(List<int> bytes, int start, List<Key> keys) {
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

int _utf8Length(int byte) {
  if (byte >= 0xf0) return 4;
  if (byte >= 0xe0) return 3;
  if (byte >= 0xc0) return 2;
  return 1;
}
