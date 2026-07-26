import 'dart:io';

/// Directories that never hold the project being run, and are expensive to walk.
const _skipped = {
  '.git',
  '.dart_tool',
  'node_modules',
  'build',
  'ios',
  'android',
  'macos',
  'windows',
  'linux',
  'web',
  'Pods',
  '.symlinks',
  '.idea',
  '.vscode',
};

/// The `--target` of a `flutter run` invocation, if it names one.
String? targetOf(String command) {
  final parts = command.split(RegExp(r'\s+'));
  for (var index = 0; index < parts.length; index++) {
    final part = parts[index];
    if (part.startsWith('--target=')) return part.substring('--target='.length);
    if ((part == '--target' || part == '-t') && index + 1 < parts.length) {
      return parts[index + 1];
    }
  }
  return null;
}

/// Directories under [root] that hold a `pubspec.yaml`, shallowest first.
List<String> pubspecDirs(String root, {int maxDepth = 3}) {
  final found = <String>[];
  void walk(Directory directory, int depth) {
    if (File('${directory.path}/pubspec.yaml').existsSync()) {
      found.add(directory.path);
    }
    if (depth >= maxDepth) return;
    final List<FileSystemEntity> entries;
    try {
      entries = directory.listSync(followLinks: false);
    } on FileSystemException {
      return;
    }
    for (final entry in entries) {
      if (entry is! Directory) continue;
      final name = entry.path.split('/').last;
      if (name.startsWith('.') || _skipped.contains(name)) continue;
      walk(entry, depth + 1);
    }
  }

  walk(Directory(root), 0);
  return found;
}

/// The directory a `flutter run` should be started from.
///
/// A monorepo holds several packages, so the entry point the command names is
/// what identifies the right one: `--target lib/main_dev.dart` only resolves
/// inside the project it belongs to. Without a target, the only Dart project
/// wins, and a root that is itself one wins over its packages.
///
/// Returns null when the answer would be a guess between equals, which the
/// launch screen shows rather than papering over.
String? flutterProjectDir(String root, {String? target, int maxDepth = 3}) {
  final candidates = pubspecDirs(root, maxDepth: maxDepth);
  if (candidates.isEmpty) return null;
  if (target != null && target.isNotEmpty) {
    for (final directory in candidates) {
      if (File('$directory/$target').existsSync()) return directory;
    }
  }
  if (candidates.contains(root)) return root;
  if (candidates.length == 1) return candidates.single;
  return null;
}
