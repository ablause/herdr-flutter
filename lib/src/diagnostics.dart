/// Readers for the DiagnosticsNode JSON that the Flutter framework sends on
/// `Flutter.Error` events and from the widget inspector extensions.
library;

/// Where a widget was created, when the app was built with track-widget-creation.
class CreationLocation {
  CreationLocation({required this.file, this.line, this.column});

  final String file;
  final int? line;
  final int? column;

  /// The path without the `file://` scheme, relative to `root` when it is under it.
  String display({String? root}) {
    var path = file;
    if (path.startsWith('file://')) path = Uri.parse(path).toFilePath();
    if (root != null && root.isNotEmpty && path.startsWith('$root/')) {
      path = path.substring(root.length + 1);
    }
    if (line == null) return path;
    return '$path:$line';
  }
}

final _fileLinePattern = RegExp(r'(file:///\S+?\.dart):(\d+)(?::(\d+))?');

/// A `file:///…dart:line:column` reference inside free text.
///
/// Error payloads carry no `creationLocation`: the framework writes the
/// error-causing widget's position into the description text instead, so the only
/// way to show a file and line for an exception is to read it back out.
CreationLocation? locationFromText(String text) {
  final match = _fileLinePattern.firstMatch(text);
  if (match == null) return null;
  return CreationLocation(
    file: match.group(1)!,
    line: int.tryParse(match.group(2)!),
    column: match.group(3) == null ? null : int.tryParse(match.group(3)!),
  );
}

CreationLocation? creationLocation(Map<String, Object?> node) {
  final raw = node['creationLocation'];
  if (raw is! Map) return null;
  final file = raw['file'];
  if (file is! String || file.isEmpty) return null;
  return CreationLocation(
    file: file,
    line: raw['line'] as int?,
    column: raw['column'] as int?,
  );
}

List<Map<String, Object?>> childNodes(Map<String, Object?> node) {
  final children = node['children'];
  if (children is! List) return const [];
  return children.whereType<Map<String, Object?>>().toList();
}

List<Map<String, Object?>> propertyNodes(Map<String, Object?> node) {
  final properties = node['properties'];
  if (properties is! List) return const [];
  return properties.whereType<Map<String, Object?>>().toList();
}

/// The one-line title of a node: `name: description`, or either alone.
String nodeTitle(Map<String, Object?> node) {
  final description = (node['description'] as String? ?? '').trim();
  final name = (node['name'] as String? ?? '').trim();
  final showName = node['showName'] != false;
  if (name.isEmpty || !showName) return description;
  if (description.isEmpty) return name;
  return '$name: $description';
}

/// The error's headline, the way an IDE shows it.
///
/// `FlutterErrorDetails.summary` is serialized as the first descendant at level
/// `summary`; falling back to the node's own description keeps unusual payloads
/// readable instead of blank.
String errorSummary(Map<String, Object?> node) {
  final found = _findByLevel(node, 'summary', depth: 4);
  if (found != null) {
    final title = nodeTitle(found).trim();
    if (title.isNotEmpty) return _oneLine(title);
  }
  final rendered = node['renderedErrorText'];
  if (rendered is String && rendered.trim().isNotEmpty) {
    final line = const LineSplitterLite()
        .split(rendered)
        .map((line) => line.trim())
        .firstWhere(
          (line) => line.isNotEmpty && !_isRule(line),
          orElse: () => '',
        );
    if (line.isNotEmpty) return _oneLine(line);
  }
  final title = nodeTitle(node).trim();
  return title.isEmpty ? 'Flutter error' : _oneLine(title);
}

Map<String, Object?>? _findByLevel(
  Map<String, Object?> node,
  String level, {
  required int depth,
}) {
  if (node['level'] == level) return node;
  if (depth <= 0) return null;
  for (final child in [...propertyNodes(node), ...childNodes(node)]) {
    final found = _findByLevel(child, level, depth: depth - 1);
    if (found != null) return found;
  }
  return null;
}

bool _isRule(String line) =>
    line.length > 8 && RegExp(r'^[═─=\-]+$').hasMatch(line);

String _oneLine(String text) => text.replaceAll(RegExp(r'\s+'), ' ').trim();

/// A node and its subtree as indented text, close to what the console prints.
String renderNode(
  Map<String, Object?> node, {
  int indent = 0,
  int maxDepth = 8,
  bool includeProperties = true,
}) {
  final buffer = StringBuffer();
  _renderInto(
    buffer,
    node,
    indent: indent,
    maxDepth: maxDepth,
    includeProperties: includeProperties,
  );
  return buffer.toString().trimRight();
}

void _renderInto(
  StringBuffer buffer,
  Map<String, Object?> node, {
  required int indent,
  required int maxDepth,
  required bool includeProperties,
}) {
  if (node['level'] == 'hidden' || node['level'] == 'off') return;
  final pad = '  ' * indent;
  final title = nodeTitle(node);
  if (title.isNotEmpty) {
    for (final line in const LineSplitterLite().split(title)) {
      buffer.writeln('$pad$line');
    }
  }
  if (maxDepth <= 0) return;
  if (includeProperties) {
    for (final property in propertyNodes(node)) {
      _renderInto(
        buffer,
        property,
        indent: indent + 1,
        maxDepth: maxDepth - 1,
        includeProperties: includeProperties,
      );
    }
  }
  for (final child in childNodes(node)) {
    _renderInto(
      buffer,
      child,
      indent: indent + 1,
      maxDepth: maxDepth - 1,
      includeProperties: includeProperties,
    );
  }
}

/// `LineSplitter` without importing dart:convert everywhere, and tolerant of
/// the mixed line endings that come back from a device.
class LineSplitterLite {
  const LineSplitterLite();

  List<String> split(String text) =>
      text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
}
