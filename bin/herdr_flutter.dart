import 'dart:convert';
import 'dart:io';

import 'package:herdr_flutter/src/app.dart';
import 'package:herdr_flutter/src/config.dart';
import 'package:herdr_flutter/src/diagnostics.dart';
import 'package:herdr_flutter/src/discovery.dart';
import 'package:herdr_flutter/src/herdr_cli.dart';
import 'package:herdr_flutter/src/models.dart';
import 'package:herdr_flutter/src/session.dart';

const _version = '0.1.1';

const _usage =
    '''
herdr-flutter $_version

  herdr-flutter                      run the sidebar (needs a terminal)
  herdr-flutter --probe [--json] [--uri=URI]
                                     attach once, report what was found, exit
  herdr-flutter --resolve-plugin-config
                                     validated plugin config as JSON
  herdr-flutter --version | --help
''';

Future<int> main(List<String> arguments) async {
  if (arguments.contains('--help') || arguments.contains('-h')) {
    stdout.write(_usage);
    return 0;
  }
  if (arguments.contains('--version')) {
    stdout.writeln(_version);
    return 0;
  }

  final PluginConfig config;
  try {
    config = PluginConfig.load();
  } on ConfigException catch (error) {
    stderr.writeln('herdr-flutter: ${error.message}');
    return 1;
  }

  // The sidebar scripts read the normalized config from here, so bash never has
  // to parse TOML and every entry point shares one validation.
  if (arguments.contains('--resolve-plugin-config')) {
    stdout.writeln(jsonEncode(config.toShellJson()));
    return 0;
  }

  final cli = HerdrCli();

  if (arguments.contains('--probe')) {
    String? override;
    for (final argument in arguments) {
      if (argument.startsWith('--uri=')) {
        override = argument.substring('--uri='.length);
      }
    }
    return _probe(
      cli,
      config,
      asJson: arguments.contains('--json'),
      uriOverride: override,
    );
  }

  // hasTerminal is false when the window size cannot be read, which a pty with
  // an unset size does. Accepting either stream keeps such a pane usable, with
  // the size falling back to 80x24.
  if (!stdout.hasTerminal && !stdin.hasTerminal) {
    stderr.writeln(
      'herdr-flutter: no terminal. Run it in a herdr pane, or use --probe.',
    );
    return 2;
  }

  await App(cli: cli, config: config).run();
  return 0;
}

/// Attach once and report, for checking the plumbing without a terminal.
Future<int> _probe(
  HerdrCli cli,
  PluginConfig config, {
  required bool asJson,
  String? uriOverride,
}) async {
  // An explicit URI skips the pane scan entirely, which is what makes this mode
  // usable against an app that does not live in a herdr pane.
  final targets = uriOverride != null && uriOverride.isNotEmpty
      ? [AppTarget(serviceUri: Uri.parse(uriOverride), origin: 'flag')]
      : await discoverTargets(
          cli,
          configuredUri: config.serviceUri,
          paneLines: config.paneLines,
        );
  if (targets.isEmpty) {
    if (asJson) {
      stdout.writeln(jsonEncode({'targets': 0}));
    } else {
      stdout.writeln('no running Flutter app found');
    }
    return 1;
  }

  final logs = <LogLine>[];
  final errors = <ErrorItem>[];
  final session = FlutterSession(
    target: targets.first,
    onLog: logs.add,
    onError: errors.add,
    onChange: () {},
  );
  await session.connect();
  if (session.state == SessionState.failed) {
    stderr.writeln('attach failed: ${session.failure}');
    return 1;
  }
  // Give the app a moment to announce its extensions and post a frame.
  await Future<void>.delayed(const Duration(seconds: 2));
  final tree = await session.fetchWidgetTree();
  final report = {
    'targets': [
      for (final target in targets)
        {
          'label': target.label,
          'uri': target.serviceUri.toString(),
          'owner_pane': target.ownerPaneId,
          'origin': target.origin,
        },
    ],
    'attached': targets.first.serviceUri.toString(),
    'isolate': session.isolateId,
    'isolate_name': session.isolateName,
    'extensions': session.extensionRpcs.length,
    'inspector_ready': session.inspectorReady,
    'can_hot_reload': session.canReload,
    'can_hot_restart': session.canRestart,
    'flutter_version': session.flutterVersion['frameworkVersion'],
    'dart_version': session.vmInfo['version'],
    'frames_seen': session.frames,
    'toggles': session.toggleStates,
    'log_lines': logs.length,
    'errors': [for (final error in errors) error.summary],
    'widget_tree': tree == null
        ? null
        : {
            'root': tree.description,
            'nodes': tree.subtreeSize,
            'children': [
              for (final child in tree.children)
                {
                  'description': child.description,
                  'local': child.createdByLocalProject,
                  'location': child.location?.display(),
                },
            ],
          },
  };
  await session.dispose();

  if (asJson) {
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(report));
    return 0;
  }
  report.forEach((key, value) {
    stdout.writeln('${key.padRight(18)} $value');
  });
  if (errors.isNotEmpty) {
    stdout.writeln(
      '\nfirst error:\n${renderNode(errors.first.node, maxDepth: 4)}',
    );
  }
  return 0;
}
