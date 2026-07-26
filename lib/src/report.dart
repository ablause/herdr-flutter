import 'diagnostics.dart';
import 'discovery.dart';
import 'models.dart';

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
