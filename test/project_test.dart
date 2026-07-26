import 'dart:io';

import 'package:herdr_flutter/src/project.dart';
import 'package:test/test.dart';

/// A monorepo the way Flutter projects are usually laid out: several packages,
/// one runnable app, and a checkout root that is not a Dart project itself.
Directory makeMonorepo() {
  final root = Directory.systemTemp.createTempSync('herdr-flutter-test');
  void project(String path, {String? entry}) {
    final directory = Directory('${root.path}/$path')
      ..createSync(recursive: true);
    File('${directory.path}/pubspec.yaml').writeAsStringSync('name: x\n');
    if (entry != null) {
      final file = File('${directory.path}/$entry')
        ..parent.createSync(recursive: true);
      file.writeAsStringSync('void main() {}\n');
    }
  }

  project('apps/mobile', entry: 'lib/main_development.dart');
  project('packages/one');
  project('packages/two');
  // Heavy directories must not be walked, and must never be an answer.
  Directory(
    '${root.path}/node_modules/some_package',
  ).createSync(recursive: true);
  File(
    '${root.path}/node_modules/some_package/pubspec.yaml',
  ).writeAsStringSync('name: nope\n');
  return root;
}

void main() {
  group('targetOf', () {
    test('reads every spelling of the flag', () {
      expect(
        targetOf('flutter run --target lib/main_dev.dart'),
        'lib/main_dev.dart',
      );
      expect(
        targetOf('flutter run --target=lib/main_dev.dart'),
        'lib/main_dev.dart',
      );
      expect(targetOf('flutter run -t lib/a.dart -d macos'), 'lib/a.dart');
    });

    test('is null when the command names none', () {
      expect(targetOf('flutter run -d macos --flavor dev'), isNull);
    });
  });

  group('flutterProjectDir', () {
    late Directory root;

    setUp(() => root = makeMonorepo());
    tearDown(() => root.deleteSync(recursive: true));

    test('the target picks the package that owns the entry point', () {
      expect(
        flutterProjectDir(root.path, target: 'lib/main_development.dart'),
        '${root.path}/apps/mobile',
      );
    });

    test('refuses to guess between packages without a target', () {
      expect(flutterProjectDir(root.path), isNull);
    });

    test('a root that is itself a project wins', () {
      File('${root.path}/pubspec.yaml').writeAsStringSync('name: root\n');
      expect(flutterProjectDir(root.path), root.path);
    });

    test('a single project needs no target', () {
      final solo = Directory.systemTemp.createTempSync('herdr-flutter-solo');
      Directory('${solo.path}/app').createSync();
      File('${solo.path}/app/pubspec.yaml').writeAsStringSync('name: app\n');
      expect(flutterProjectDir(solo.path), '${solo.path}/app');
      solo.deleteSync(recursive: true);
    });

    test('vendored directories are never walked', () {
      expect(
        pubspecDirs(root.path).any((path) => path.contains('node_modules')),
        isFalse,
      );
      expect(pubspecDirs(root.path).length, 3);
    });

    test('a checkout with no Dart project at all gives nothing', () {
      final empty = Directory.systemTemp.createTempSync('herdr-flutter-empty');
      expect(flutterProjectDir(empty.path), isNull);
      empty.deleteSync(recursive: true);
    });
  });
}
