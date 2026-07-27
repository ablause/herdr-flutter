import 'diagnostics.dart';

/// Where a log line came from.
enum LogSource {
  stdout('out'),
  stderr('err'),
  developer('log'),
  session('app'),

  /// A framework error, which reaches no other stream: enabling structured
  /// errors replaces the console dump with the `Flutter.Error` event, so
  /// without a line here the log would have a hole where the error happened.
  error('exc');

  const LogSource(this.tag);

  final String tag;
}

class LogLine {
  LogLine(
    this.source,
    this.text, {
    DateTime? time,
    this.name,
    this.level,
    this.error,
  }) : time = time ?? DateTime.now();

  /// The line an error takes in the log: its summary, at its own time, severe.
  ///
  /// The framework prints nothing itself when structured errors are on, so this
  /// is the only trace the run leaves, and it carries the whole report with it.
  LogLine.forError(ErrorItem item)
    : this(
        LogSource.error,
        item.summary,
        time: item.time,
        level: 1000,
        error: item,
      );

  final DateTime time;
  final LogSource source;
  final String text;

  /// The error this line stands for, when it is a marker.
  ///
  /// Held by reference rather than by index so that clearing the errors makes
  /// the older markers inert instead of pointing at whatever took their place.
  final ErrorItem? error;

  /// The logger name of a `developer.log` record, when it had one.
  final String? name;

  /// The record's level, on the package:logging scale: 900 warns, 1000 is
  /// severe. It is what the app itself said about the line, so it drives the
  /// colour rather than a guess made from the text.
  final int? level;

  bool get isSevere => (level ?? 0) >= 1000;
  bool get isWarning => (level ?? 0) >= 900 && !isSevere;
}

/// What `/` narrows the log to: a source, free text, or both.
///
/// A leading `<tag>:` picks the source, so `exc:` shows the framework errors
/// alone. Anything else before a colon is left as text, so searching for
/// `http://host` or `12:30` still does what it looks like it does.
class LogFilter {
  const LogFilter({this.source, this.text = ''});

  factory LogFilter.parse(String raw) {
    final colon = raw.indexOf(':');
    if (colon > 0) {
      final tag = raw.substring(0, colon).trim().toLowerCase();
      for (final source in LogSource.values) {
        if (source.tag == tag) {
          return LogFilter(
            source: source,
            text: raw.substring(colon + 1).trim(),
          );
        }
      }
    }
    return LogFilter(text: raw.trim());
  }

  final LogSource? source;
  final String text;

  bool get isEmpty => source == null && text.isEmpty;

  bool matches(LogLine line) {
    if (source != null && line.source != source) return false;
    return text.isEmpty || line.text.toLowerCase().contains(text.toLowerCase());
  }
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

  /// The lines worth reading without unfolding: what the framework was doing
  /// and which widget it blamed, but never the stack.
  ///
  /// The rendering opens with a banner rule and repeats the summary a line or
  /// two in, so both are dropped: what is left is the sentence that places the
  /// error. Nothing here is guaranteed, and an unusual payload yields none.
  List<String> preview({int limit = 2}) {
    final wanted = <String>[];
    for (final raw in const LineSplitterLite().split(detail)) {
      final line = raw.trim();
      if (line.isEmpty || _isRule(line)) continue;
      if (line == summary.trim()) continue;
      // A repeat error renders as this one sentence, which says nothing the
      // summary beside it does not.
      if (line.startsWith('Another exception was thrown:')) continue;
      wanted.add(line);
      if (wanted.length == limit) break;
    }
    return wanted;
  }

  /// Decoration rather than content: the titled banner the rendering opens
  /// with, the rule it closes on, and the striped bar an overflow draws.
  static bool _isRule(String line) {
    if (line.startsWith('═') || line.startsWith('╞') || line.startsWith('╡')) {
      return true;
    }
    return line.split('').every((rune) => '═╡╞◢◤▲ '.contains(rune));
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
