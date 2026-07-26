import 'package:herdr_flutter/src/discovery.dart';
import 'package:herdr_flutter/src/herdr_cli.dart';
import 'package:test/test.dart';

void main() {
  group('extractAnnouncement', () {
    test('reads a flutter run announcement with its device name', () {
      const output = '''
Flutter run key commands.
r Hot reload. 🔥🔥🔥
A Dart VM Service on iPhone 17 is available at: http://127.0.0.1:54087/8iuqh5GEAmE=/
The Flutter DevTools debugger and profiler on iPhone 17 is available at: http://127.0.0.1:54087/8iuqh5GEAmE=/devtools/?uri=ws://127.0.0.1:54087/8iuqh5GEAmE=/ws
''';
      final found = extractAnnouncement(output);
      expect(found, isNotNull);
      expect(found!.uri.port, 54087);
      expect(found.uri.path, '/8iuqh5GEAmE=/');
      expect(found.deviceName, 'iPhone 17');
    });

    test('the last announcement wins, so a restarted app is the target', () {
      const output = '''
A Dart VM Service on iPhone 17 is available at: http://127.0.0.1:54087/aaa=/
Lost connection to device.
A Dart VM Service on iPhone 17 is available at: http://127.0.0.1:64095/bbb=/
''';
      expect(extractAnnouncement(output)!.uri.port, 64095);
    });

    test('reads the dart run and flutter test wording', () {
      const output =
          'The Dart VM Service is listening on http://127.0.0.1:8181/ws=/';
      final found = extractAnnouncement(output);
      expect(found!.uri.port, 8181);
      expect(found.deviceName, isNull);
    });

    test('reads the web debug service wording', () {
      const output = 'Debug service listening on ws://127.0.0.1:52000/xyz=/ws';
      expect(extractAnnouncement(output)!.uri.scheme, 'ws');
    });

    test('ignores the devtools line, which is not a service uri', () {
      const output =
          'The Flutter DevTools debugger and profiler on macOS is available at: http://127.0.0.1:9100/abc=/';
      expect(extractAnnouncement(output), isNull);
    });

    test('returns null for unrelated output', () {
      expect(extractAnnouncement('pnpm dev\nready on port 3000'), isNull);
    });
  });

  group('candidatePanes', () {
    PaneInfo pane(
      String id, {
      String tab = 't1',
      String workspace = 'w1',
      String? agent,
      String? label,
    }) => PaneInfo.fromJson({
      'pane_id': id,
      'tab_id': tab,
      'workspace_id': workspace,
      'cwd': '/repo',
      'foreground_cwd': '/repo',
      'terminal_title': id,
      'label': label,
      'agent': agent,
    });

    test('drops agents, the sidebar itself and other flutter sidebars', () {
      final panes = [
        pane('w1:p1', agent: 'claude'),
        pane('w1:p2'),
        pane('w1:p3', label: 'flutter'),
        pane('w1:p9'),
      ];
      final result = candidatePanes(
        panes,
        selfPaneId: 'w1:p9',
        tabId: 't1',
        workspaceId: 'w1',
        selfLabel: 'flutter',
      );
      expect(result.map((pane) => pane.paneId), ['w1:p2']);
    });

    test(
      'ranks the same tab first, then the same workspace, then the rest',
      () {
        final panes = [
          pane('w2:p1', tab: 't9', workspace: 'w2'),
          pane('w1:p5', tab: 't2', workspace: 'w1'),
          pane('w1:p2', tab: 't1', workspace: 'w1'),
        ];
        final result = candidatePanes(
          panes,
          selfPaneId: 'w1:p9',
          tabId: 't1',
          workspaceId: 'w1',
        );
        expect(result.map((pane) => pane.paneId), ['w1:p2', 'w1:p5', 'w2:p1']);
      },
    );
  });

  test('parsePanes tolerates a foreign envelope', () {
    expect(
      parsePanes({
        'error': {'code': 'nope'},
      }),
      isEmpty,
    );
    expect(parsePanes({'result': {}}), isEmpty);
  });
}
