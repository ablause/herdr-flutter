import 'package:herdr_flutter/src/diagnostics.dart';
import 'package:herdr_flutter/src/discovery.dart';
import 'package:herdr_flutter/src/models.dart';
import 'package:herdr_flutter/src/report.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

Map<String, Object?> loadFixture() => flutterError();

void main() {
  test('the preview keeps the context line and drops the banner', () {
    final preview = ErrorItem.fromEventData(loadFixture()).preview();
    expect(preview, hasLength(2));
    expect(preview.first, 'The following assertion was thrown during layout:');
    // The rule above it and the summary below it are both skipped, since the
    // summary is already on the line the preview hangs from.
    expect(preview.any((line) => line.contains('═')), isFalse);
    expect(preview.any((line) => line.contains('overflowed by 750')), isFalse);
  });

  test('a repeat error previews its tree, not its one-line form', () {
    final data = Map<String, Object?>.from(loadFixture())
      ..['errorsSinceReload'] = 3
      ..['renderedErrorText'] = 'Another exception was thrown: boom';
    final preview = ErrorItem.fromEventData(data).preview();
    expect(preview, isNotEmpty);
    expect(
      preview.any((line) => line.startsWith('Another exception')),
      isFalse,
      reason: 'that sentence says nothing the summary does not',
    );
  });

  test('the preview asks for no more lines than it is given', () {
    final error = ErrorItem.fromEventData(loadFixture());
    expect(error.preview(limit: 1), hasLength(1));
    expect(error.preview(limit: 5), hasLength(5));
  });

  test('the summary is the ErrorSummary node, not the wrapper description', () {
    final error = ErrorItem.fromEventData(loadFixture());
    expect(
      error.summary,
      'A RenderFlex overflowed by 750 pixels on the right.',
    );
  });

  test(
    'the location comes out of the text, since errors carry no creationLocation',
    () {
      final error = ErrorItem.fromEventData(loadFixture());
      expect(error.location, isNotNull);
      expect(error.location!.file, 'file:///Users/dev/app/lib/main.dart');
      expect(error.location!.line, 29);
      expect(
        error.location!.display(root: '/Users/dev/app'),
        'lib/main.dart:29',
      );
    },
  );

  test('the first error keeps the console rendering', () {
    final error = ErrorItem.fromEventData(loadFixture());
    expect(error.errorsSinceReload, 0);
    expect(
      error.renderedText,
      contains('EXCEPTION CAUGHT BY RENDERING LIBRARY'),
    );
    expect(error.detail, error.renderedText);
  });

  test('a repeat error falls back to the diagnostics tree for detail', () {
    final payload = loadFixture()
      ..['errorsSinceReload'] = 3
      ..['renderedErrorText'] = 'Another exception was thrown: overflow';
    final error = ErrorItem.fromEventData(payload);
    expect(error.renderedText, 'Another exception was thrown: overflow');
    expect(error.detail, contains('Exception caught by rendering library'));
    expect(error.detail, contains('RenderFlex'));
  });

  test('an unusual payload still produces a headline', () {
    final error = ErrorItem.fromEventData({'description': 'something broke'});
    expect(error.summary, 'something broke');
    expect(error.location, isNull);
  });

  test('renderNode indents properties and children under their parent', () {
    final text = renderNode({
      'description': 'root',
      'properties': [
        {'name': 'size', 'description': 'Size(1.0, 2.0)'},
      ],
      'children': [
        {'description': 'child', 'children': <Object>[]},
      ],
    });
    expect(text, 'root\n  size: Size(1.0, 2.0)\n  child');
  });

  test('renderNode skips hidden nodes', () {
    final text = renderNode({
      'description': 'root',
      'children': [
        {'description': 'gone', 'level': 'hidden'},
        {'description': 'kept'},
      ],
    });
    expect(text, 'root\n  kept');
  });

  test('the report carries the summary, the location and the raw tree', () {
    final error = ErrorItem.fromEventData(loadFixture());
    final markdown = Report(
      target: AppTarget(
        serviceUri: Uri.parse('http://127.0.0.1:8181/abc=/'),
        deviceName: 'macOS',
        ownerPaneId: 'w1:p3',
      ),
      repoRoot: '/Users/dev/app',
    ).error(error);

    expect(markdown, startsWith('# Flutter runtime error'));
    expect(markdown, contains('- App: macOS'));
    expect(markdown, contains('- herdr pane: w1:p3'));
    expect(markdown, contains('A RenderFlex overflowed'));
    expect(markdown, contains('`lib/main.dart:29`'));
    expect(markdown, contains('## Diagnostics tree'));
    expect(markdown, contains('Consider applying a flex factor'));
  });

  test('locationFromText ignores text without a dart file reference', () {
    expect(locationFromText('no file here'), isNull);
    expect(locationFromText('at file:///a/b.dart:12:3 something')!.line, 12);
  });
}
