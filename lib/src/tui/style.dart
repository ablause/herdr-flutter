/// ANSI styling that inherits the terminal's own palette, so the sidebar looks
/// like the rest of herdr whatever theme the user runs.
class Style {
  const Style(this._codes);

  final String _codes;

  static const none = Style('');
  static const bold = Style('1');
  static const dim = Style('2');
  static const reverse = Style('7');
  static const red = Style('31');
  static const green = Style('32');
  static const yellow = Style('33');
  static const blue = Style('34');
  static const magenta = Style('35');
  static const cyan = Style('36');
  static const brightBlack = Style('90');
  static const boldRed = Style('1;31');
  static const boldGreen = Style('1;32');
  static const boldYellow = Style('1;33');
  static const boldCyan = Style('1;36');
  static const boldReverse = Style('1;7');

  String call(String text) =>
      _codes.isEmpty ? text : '\x1b[${_codes}m$text\x1b[0m';
}

/// A single terminal row, assembled from styled fragments and never wider than
/// the pane. Widths are counted on the plain text, before any escape codes.
class LineBuilder {
  LineBuilder(this.width);

  final int width;
  final StringBuffer _buffer = StringBuffer();
  int _used = 0;

  int get remaining => width - _used;
  bool get full => remaining <= 0;

  void add(String text, [Style style = Style.none]) {
    if (full || text.isEmpty) return;
    final source = text.replaceAll('\t', '  ');
    // Text that carries its own colours keeps them, and its escape bytes must
    // not count towards the width or the row would wrap early.
    if (hasEscapes(source)) {
      final clipped = takeVisible(source, remaining);
      _used += visibleWidth(clipped);
      _buffer.write('$clipped\x1b[0m');
      return;
    }
    final runes = source.runes.toList();
    final clipped = runes.length > remaining
        ? String.fromCharCodes(runes.take(remaining))
        : source;
    _used += clipped.runes.length;
    _buffer.write(style(clipped));
  }

  /// Add text, cutting it with an ellipsis when it does not fit.
  void addEllipsized(String text, [Style style = Style.none]) {
    if (full) return;
    final runes = text.replaceAll('\t', '  ').runes.toList();
    if (runes.length <= remaining) {
      add(text, style);
      return;
    }
    if (remaining <= 1) {
      add('.', style);
      return;
    }
    add('${String.fromCharCodes(runes.take(remaining - 1))}…', style);
  }

  void spaces(int count) {
    if (count <= 0) return;
    add(' ' * count);
  }

  /// Right-align the rest of the row with [text].
  void addRight(String text, [Style style = Style.none]) {
    final runes = text.runes.length;
    if (runes >= remaining) {
      add(text, style);
      return;
    }
    spaces(remaining - runes);
    add(text, style);
  }

  String build({Style fill = Style.none}) {
    if (remaining > 0 && fill != Style.none) {
      _buffer.write(fill(' ' * remaining));
      _used = width;
    }
    return _buffer.toString();
  }
}

/// Whether the text carries SGR escape sequences of its own.
bool hasEscapes(String text) => text.contains('\x1b[');

/// The first [count] visible characters, escape sequences carried along.
///
/// A sequence is never cut in half, and it does not count towards the budget, so
/// a line that arrives already coloured measures the same as its plain form.
String takeVisible(String text, int count) {
  if (count <= 0) return '';
  final out = StringBuffer();
  var visible = 0;
  final runes = text.runes.toList();
  var index = 0;
  while (index < runes.length && visible < count) {
    if (runes[index] == 0x1b) {
      final start = index;
      while (index < runes.length && runes[index] != 0x6d) {
        index++;
      }
      if (index < runes.length) index++;
      out.write(String.fromCharCodes(runes.sublist(start, index)));
      continue;
    }
    out.writeCharCode(runes[index]);
    visible++;
    index++;
  }
  return out.toString();
}

/// Everything after the first [count] visible characters.
///
/// Escape sequences from the skipped part are kept, so the remainder still opens
/// with whatever colour was active when it was cut.
String dropVisible(String text, int count) {
  final carried = StringBuffer();
  final out = StringBuffer();
  var visible = 0;
  final runes = text.runes.toList();
  var index = 0;
  while (index < runes.length) {
    if (runes[index] == 0x1b) {
      final start = index;
      while (index < runes.length && runes[index] != 0x6d) {
        index++;
      }
      if (index < runes.length) index++;
      final sequence = String.fromCharCodes(runes.sublist(start, index));
      if (visible < count) {
        carried.write(sequence);
      } else {
        out.write(sequence);
      }
      continue;
    }
    if (visible >= count) out.writeCharCode(runes[index]);
    visible++;
    index++;
  }
  if (out.isEmpty) return '';
  return '$carried$out';
}

/// Plain text width, ignoring escape sequences.
int visibleWidth(String text) {
  var width = 0;
  var index = 0;
  final runes = text.runes.toList();
  while (index < runes.length) {
    if (runes[index] == 0x1b) {
      while (index < runes.length && runes[index] != 0x6d) {
        index++;
      }
      index++;
      continue;
    }
    width++;
    index++;
  }
  return width;
}
