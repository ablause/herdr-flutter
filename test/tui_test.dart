import 'package:herdr_flutter/src/app_state.dart';
import 'package:herdr_flutter/src/config.dart';
import 'package:herdr_flutter/src/discovery.dart';
import 'package:herdr_flutter/src/models.dart';
import 'package:herdr_flutter/src/session.dart';
import 'package:herdr_flutter/src/tui/style.dart';
import 'package:herdr_flutter/src/tui/terminal.dart';
import 'package:herdr_flutter/src/views.dart';
import 'package:test/test.dart';

/// The visible text of a frame, escape codes removed.
List<String> plain(List<String> frame) => [
  for (final line in frame) line.replaceAll(RegExp(r'\x1b\[[0-9;]*m'), ''),
];

AppState connectedState({String device = 'iPhone 17'}) {
  final target = AppTarget(
    serviceUri: Uri.parse('http://127.0.0.1:8181/abc=/'),
    deviceName: device,
    ownerPaneId: 'w1:p3',
  );
  final state = AppState(config: const PluginConfig(), repoRoot: '/repo')
    ..targets = [target];
  final session = FlutterSession(
    target: target,
    onLog: (_) {},
    onError: (_) {},
    onChange: () {},
  )..state = SessionState.connected;
  state.session = session;
  return state;
}

void main() {
  group('decodeKeys', () {
    test('reads plain characters', () {
      expect(decodeKeys('rq'.codeUnits).map((key) => key.name), ['r', 'q']);
    });

    test('reads arrows and paging', () {
      final keys = decodeKeys([
        0x1b, 0x5b, 0x41, // up
        0x1b, 0x5b, 0x42, // down
        0x1b, 0x5b, 0x35, 0x7e, // page up
        0x1b, 0x5b, 0x36, 0x7e, // page down
      ]);
      expect(keys.map((key) => key.name), ['up', 'down', 'pageup', 'pagedown']);
    });

    test('reads a lone escape and shift-tab', () {
      expect(decodeKeys([0x1b]).single.name, 'esc');
      expect(decodeKeys([0x1b, 0x5b, 0x5a]).single.name, 'shift-tab');
    });

    test('reads control keys and enter', () {
      final keys = decodeKeys([0x03, 0x0c, 0x0d, 0x09, 0x7f]);
      expect(keys.map((key) => key.name), [
        'ctrl-c',
        'ctrl-l',
        'enter',
        'tab',
        'backspace',
      ]);
    });

    test('reads multi-byte characters as one key', () {
      final keys = decodeKeys('é'.codeUnits.isEmpty ? [] : 'é'.runes.toList());
      expect(keys, isNotEmpty);
    });
  });

  group('LineBuilder', () {
    test('never exceeds the width, escape codes aside', () {
      final line = LineBuilder(10)
        ..add('12345', Style.bold)
        ..add('67890abcdef', Style.red);
      final built = line.build();
      expect(visibleWidth(built), 10);
    });

    test('ellipsizes rather than hard-cutting', () {
      final line = LineBuilder(6)..addEllipsized('abcdefghij');
      expect(line.build(), 'abcde…');
    });

    test('right-aligns the tail', () {
      final line = LineBuilder(10)
        ..add('ab')
        ..addRight('yz');
      expect(line.build(), 'ab      yz');
    });
  });

  group('renderFrame', () {
    test('fills exactly the terminal height', () {
      final frame = renderFrame(connectedState(), 60, 20);
      expect(frame.length, 20);
    });

    test('shows the device and the live state in the header', () {
      final frame = plain(renderFrame(connectedState(), 60, 20));
      expect(frame.first, contains('flutter'));
      expect(frame.first, contains('iPhone 17'));
      expect(frame.first, contains('live'));
    });

    test('names every view in the tab row', () {
      final frame = plain(renderFrame(connectedState(), 60, 20));
      expect(frame[1], contains('logs'));
      expect(frame[1], contains('errors'));
      expect(frame[1], contains('inspect'));
      expect(frame[1], contains('info'));
    });

    test('shows log lines, newest at the bottom', () {
      final state = connectedState();
      for (var index = 0; index < 5; index++) {
        state.addLog(LogLine(LogSource.stdout, 'line $index'));
      }
      final frame = plain(renderFrame(state, 60, 12));
      final first = frame.indexWhere((line) => line.contains('line 0'));
      final last = frame.indexWhere((line) => line.contains('line 4'));
      expect(first, greaterThan(1));
      expect(last, greaterThan(first));
    });

    test('the filter hides the lines that do not match', () {
      final state = connectedState()
        ..addLog(LogLine(LogSource.stdout, 'keep me'))
        ..addLog(LogLine(LogSource.stdout, 'drop this'))
        ..filter = 'keep';
      final frame = plain(renderFrame(state, 60, 12));
      expect(frame.any((line) => line.contains('keep me')), isTrue);
      expect(frame.any((line) => line.contains('drop this')), isFalse);
    });

    test('stderr lines are tagged apart from stdout', () {
      final state = connectedState()..addLog(LogLine(LogSource.stderr, 'boom'));
      final frame = plain(renderFrame(state, 60, 12));
      expect(frame.any((line) => line.contains('err boom')), isTrue);
    });

    test('an error list shows the summary and its location', () {
      final state = connectedState()
        ..view = View.errors
        ..errors.add(
          ErrorItem.fromEventData({
            'description': 'Exception caught by widgets library',
            'renderedErrorText': 'boom at file:///repo/lib/main.dart:12:3',
            'properties': [
              {'level': 'summary', 'description': 'Null check operator used'},
            ],
          }),
        );
      final frame = plain(renderFrame(state, 60, 12));
      expect(
        frame.any((line) => line.contains('Null check operator used')),
        isTrue,
      );
      expect(frame.any((line) => line.contains('lib/main.dart:12')), isTrue);
    });

    test(
      'the empty log view explains itself instead of showing a blank pane',
      () {
        final frame = plain(renderFrame(connectedState(), 60, 12));
        expect(
          frame.any((line) => line.contains('Waiting for output')),
          isTrue,
        );
      },
    );

    test('with no app at all the body says how to get one', () {
      final state = AppState(config: const PluginConfig());
      final frame = plain(renderFrame(state, 60, 14));
      expect(
        frame.any((line) => line.contains('No running Flutter app')),
        isTrue,
      );
      expect(frame.any((line) => line.contains('rescan')), isTrue);
    });

    test('the help overlay lists the reload keys', () {
      final state = connectedState()..overlay = Overlay.help;
      final frame = plain(renderFrame(state, 60, 30));
      expect(frame.any((line) => line.contains('hot reload')), isTrue);
      expect(frame.any((line) => line.contains('hot restart')), isTrue);
    });

    test('a narrow pane still renders without overflowing', () {
      final state = connectedState()
        ..addLog(
          LogLine(
            LogSource.stdout,
            'a very long line that must be wrapped or cut to fit a narrow sidebar',
          ),
        );
      final frame = renderFrame(state, 24, 10);
      for (final line in frame) {
        expect(visibleWidth(line), lessThanOrEqualTo(24));
      }
    });
  });
}
