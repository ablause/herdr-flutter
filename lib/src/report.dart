import 'diagnostics.dart';
import 'discovery.dart';
import 'models.dart';
import 'network.dart';

/// Markdown captures of what the sidebar is showing, for the agent to read.
///
/// Reports are plain observations: what happened, where, and the raw framework
/// output. They never tell the agent what to change.
class Report {
  Report({required this.target, this.repoRoot});

  final AppTarget target;
  final String? repoRoot;

  String _header(String title, DateTime time) {
    final lines = <String>[
      '# $title',
      '',
      '- Captured: ${time.toIso8601String()}',
      '- App: ${target.label}',
      '- VM Service: ${target.serviceUri}',
    ];
    final owner = target.ownerPaneId;
    if (owner != null) lines.add('- herdr pane: $owner');
    lines.add('');
    return '${lines.join('\n')}\n';
  }

  String error(ErrorItem item) {
    final buffer = StringBuffer(_header('Flutter runtime error', item.time));
    buffer.writeln('## Summary');
    buffer.writeln();
    buffer.writeln(item.summary);
    buffer.writeln();
    final location = item.location;
    if (location != null) {
      buffer.writeln('## Location');
      buffer.writeln();
      buffer.writeln('`${location.display(root: repoRoot)}`');
      buffer.writeln();
    }
    if (item.errorsSinceReload > 0) {
      buffer.writeln(
        '> Error number ${item.errorsSinceReload + 1} since the last reload. '
        'Flutter only renders the full console text for the first one, so the '
        'diagnostics tree below carries the detail.',
      );
      buffer.writeln();
    }
    buffer.writeln('## Console output');
    buffer.writeln();
    buffer.writeln('```');
    buffer.writeln(item.renderedText);
    buffer.writeln('```');
    buffer.writeln();
    buffer.writeln('## Diagnostics tree');
    buffer.writeln();
    buffer.writeln('```');
    buffer.writeln(renderNode(item.node, maxDepth: 10));
    buffer.writeln('```');
    return buffer.toString();
  }

  String httpCall(HttpCall call, {HttpCallDetail? detail}) {
    final buffer = StringBuffer(
      _header(
        'Flutter app HTTP request',
        DateTime.fromMicrosecondsSinceEpoch(call.startMicros),
      ),
    );
    buffer.writeln('## Request');
    buffer.writeln();
    buffer.writeln('`${call.method} ${call.uri}`');
    buffer.writeln();
    final status = call.statusCode;
    if (status != null) {
      buffer.writeln(
        '- Status: $status${call.reasonPhrase == null ? '' : ' ${call.reasonPhrase}'}',
      );
    }
    final elapsed = call.duration();
    if (elapsed != null) buffer.writeln('- Took: ${formatDuration(elapsed)}');
    final bytes = call.responseBytes;
    if (bytes != null) buffer.writeln('- Response size: ${formatBytes(bytes)}');
    final error = call.error;
    if (error != null) buffer.writeln('- Error: $error');
    if (!call.isComplete) buffer.writeln('- Still in flight when captured');
    buffer.writeln();
    _headers(buffer, 'Request headers', call.requestHeaders);
    _body(buffer, 'Request body', detail?.request);
    _headers(buffer, 'Response headers', call.responseHeaders);
    _body(buffer, 'Response body', detail?.response);
    return buffer.toString();
  }

  void _headers(StringBuffer buffer, String title, Map<String, String> values) {
    if (values.isEmpty) return;
    buffer.writeln('## $title');
    buffer.writeln();
    final names = values.keys.toList()..sort();
    for (final name in names) {
      buffer.writeln('- `$name`: ${values[name]}');
    }
    buffer.writeln();
  }

  void _body(StringBuffer buffer, String title, HttpBody? body) {
    if (body == null) return;
    buffer.writeln('## $title');
    buffer.writeln();
    final text = body.text;
    if (text == null) {
      buffer.writeln('${formatBytes(body.byteCount)} that are not text.');
      buffer.writeln();
      return;
    }
    buffer.writeln('```');
    buffer.writeln(text);
    buffer.writeln('```');
    buffer.writeln();
  }

  String logs(List<LogLine> lines, {String filter = '', int limit = 300}) {
    final selected = lines.length > limit
        ? lines.sublist(lines.length - limit)
        : lines;
    final buffer = StringBuffer(_header('Flutter app log', DateTime.now()));
    buffer.writeln('- Lines: ${selected.length} of ${lines.length}');
    if (filter.isNotEmpty) buffer.writeln('- Filter: `$filter`');
    buffer.writeln();
    buffer.writeln('```');
    for (final line in selected) {
      buffer.writeln('${_time(line.time)} ${line.source.tag} ${line.text}');
    }
    buffer.writeln('```');
    return buffer.toString();
  }

  String widget(WidgetNode node, {Map<String, Object?>? details}) {
    final buffer = StringBuffer(_header('Flutter widget', DateTime.now()));
    buffer.writeln('## Widget');
    buffer.writeln();
    buffer.writeln('`${node.description}`');
    buffer.writeln();
    final location = node.location;
    if (location != null) {
      buffer.writeln('- Created at: `${location.display(root: repoRoot)}`');
    }
    final preview = node.textPreview;
    if (preview != null && preview.isNotEmpty) {
      buffer.writeln('- Text preview: `$preview`');
    }
    buffer.writeln('- Subtree size: ${node.subtreeSize}');
    buffer.writeln();
    if (details != null) {
      buffer.writeln('## Properties and children');
      buffer.writeln();
      buffer.writeln('```');
      buffer.writeln(renderNode(details, maxDepth: 4));
      buffer.writeln('```');
      buffer.writeln();
    }
    buffer.writeln('## Subtree');
    buffer.writeln();
    buffer.writeln('```');
    buffer.writeln(_tree(node, 0));
    buffer.writeln('```');
    return buffer.toString();
  }

  String _tree(WidgetNode node, int depth) {
    final buffer = StringBuffer();
    final pad = '  ' * depth;
    final location = node.location;
    final suffix = location == null || !node.createdByLocalProject
        ? ''
        : '  (${location.display(root: repoRoot)})';
    buffer.writeln('$pad${node.description}$suffix');
    if (depth >= 12) return buffer.toString();
    for (final child in node.children) {
      buffer.write(_tree(child, depth + 1));
    }
    return buffer.toString();
  }

  static String _time(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
  }
}
