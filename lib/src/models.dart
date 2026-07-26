import 'diagnostics.dart';

/// Where a log line came from.
enum LogSource {
  stdout('out'),
  stderr('err'),
  developer('log'),
  session('app');

  const LogSource(this.tag);

  final String tag;
}

class LogLine {
  LogLine(this.source, this.text, {DateTime? time, this.name, this.level})
    : time = time ?? DateTime.now();

  final DateTime time;
  final LogSource source;
  final String text;

  /// The logger name of a `developer.log` record, when it had one.
  final String? name;

  /// The record's level, on the package:logging scale: 900 warns, 1000 is
  /// severe. It is what the app itself said about the line, so it drives the
  /// colour rather than a guess made from the text.
  final int? level;

  bool get isSevere => (level ?? 0) >= 1000;
  bool get isWarning => (level ?? 0) >= 900 && !isSevere;

  bool matches(String needle) =>
      needle.isEmpty || text.toLowerCase().contains(needle.toLowerCase());
}

/// One `Flutter.Error` event, kept whole so the report can be rebuilt later.
class ErrorItem {
  ErrorItem({
    required this.time,
    required this.summary,
    required this.node,
    required this.renderedText,
    required this.errorsSinceReload,
    this.location,
  });

  factory ErrorItem.fromEventData(Map<String, Object?> data, {DateTime? time}) {
    final rendered = data['renderedErrorText'];
    final renderedText = rendered is String && rendered.trim().isNotEmpty
        ? rendered.trimRight()
        : renderNode(data);
    return ErrorItem(
      time: time ?? DateTime.now(),
      summary: errorSummary(data),
      node: data,
      renderedText: renderedText,
      errorsSinceReload: data['errorsSinceReload'] as int? ?? 0,
      location:
          _firstLocation(data, 4) ??
          locationFromText(renderedText) ??
          locationFromText(renderNode(data, maxDepth: 6)),
    );
  }

  final DateTime time;
  final String summary;

  /// The raw DiagnosticsNode JSON of the FlutterErrorDetails.
  final Map<String, Object?> node;

  /// The console rendering. Flutter only sends the full text for the first
  /// error since the last reload; later ones get a one-line form, so the tree
  /// rendering below is what carries their detail.
  final String renderedText;

  final int errorsSinceReload;
  final CreationLocation? location;

  /// The subtree as text, used when [renderedText] is the terse repeat form.
  String get detail {
    if (errorsSinceReload == 0) return renderedText;
    return '$renderedText\n\n${renderNode(node)}';
  }

  static CreationLocation? _firstLocation(
    Map<String, Object?> node,
    int depth,
  ) {
    final own = creationLocation(node);
    if (own != null) return own;
    if (depth <= 0) return null;
    for (final child in [...propertyNodes(node), ...childNodes(node)]) {
      final found = _firstLocation(child, depth - 1);
      if (found != null) return found;
    }
    return null;
  }
}

/// A node of the widget tree as the inspector serializes it.
class WidgetNode {
  WidgetNode({
    required this.description,
    required this.valueId,
    required this.type,
    required this.children,
    required this.createdByLocalProject,
    required this.raw,
    this.textPreview,
    this.location,
    this.depth = 0,
  });

  factory WidgetNode.fromJson(Map<String, Object?> json, {int depth = 0}) {
    final children = childNodes(
      json,
    ).map((child) => WidgetNode.fromJson(child, depth: depth + 1)).toList();
    return WidgetNode(
      description: nodeTitle(json),
      valueId: json['valueId'] as String?,
      type: json['widgetRuntimeType'] as String? ?? json['type'] as String?,
      children: children,
      createdByLocalProject: json['createdByLocalProject'] == true,
      textPreview: json['textPreview'] as String?,
      location: creationLocation(json),
      raw: json,
      depth: depth,
    );
  }

  final String description;
  final String? valueId;
  final String? type;
  final List<WidgetNode> children;

  /// True for widgets from the project under development rather than a package,
  /// which is what makes the summary tree readable.
  final bool createdByLocalProject;

  final String? textPreview;
  final CreationLocation? location;
  final Map<String, Object?> raw;
  final int depth;

  bool get hasChildren => children.isNotEmpty;

  /// Flattened view honouring a collapsed set, for a scrollable list.
  void flatten(List<WidgetNode> into, Set<String> collapsed) {
    into.add(this);
    final id = valueId;
    if (id != null && collapsed.contains(id)) return;
    for (final child in children) {
      child.flatten(into, collapsed);
    }
  }

  int get subtreeSize =>
      1 + children.fold(0, (sum, child) => sum + child.subtreeSize);
}
