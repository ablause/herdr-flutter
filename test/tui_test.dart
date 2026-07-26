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

    test('reads an SGR mouse press, with zero-based coordinates', () {
      final events = decodeEvents('\x1b[<0;13;1M'.codeUnits);
      final mouse = events.single as Mouse;
      expect(mouse.kind, MouseKind.press);
      expect(mouse.isLeftPress, isTrue);
      expect(mouse.column, 12);
      expect(mouse.row, 0);
    });

    test('reads a release and a wheel turn', () {
      expect(
        (decodeEvents('\x1b[<0;5;5m'.codeUnits).single as Mouse).kind,
        MouseKind.release,
      );
      expect(
        (decodeEvents('\x1b[<64;5;5M'.codeUnits).single as Mouse).kind,
        MouseKind.wheelUp,
      );
      expect(
        (decodeEvents('\x1b[<65;5;5M'.codeUnits).single as Mouse).kind,
        MouseKind.wheelDown,
      );
    });

    test('a mouse report is not mistaken for keys', () {
      expect(decodeKeys('\x1b[<0;13;1M'.codeUnits), isEmpty);
    });

    test('reads a key that follows a mouse report in the same chunk', () {
      final events = decodeEvents('\x1b[<0;3;4Mq'.codeUnits);
      expect(events.length, 2);
      expect(events.first, isA<Mouse>());
      expect((events.last as Key).name, 'q');
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

    test('one top row holds the numbered views and the attachment', () {
      final frame = plain(renderFrame(connectedState(), 60, 20));
      expect(frame.first, contains('1 logs'));
      expect(frame.first, contains('2 errors'));
      expect(frame.first, contains('3 inspect'));
      expect(frame.first, contains('4 info'));
      expect(frame.first, contains('iPhone 17 · live'));
    });

    test('the top row does not repeat the pane name', () {
      final frame = plain(renderFrame(connectedState(), 60, 20));
      expect(frame.first.contains('flutter'), isFalse);
    });

    test('a narrow top row keeps the state and drops the app name', () {
      final frame = plain(renderFrame(connectedState(), 40, 20));
      expect(frame.first, contains('live'));
      expect(frame.first.contains('iPhone 17'), isFalse);
    });

    test('an error count replaces the live marker', () {
      final state = connectedState();
      state.session!.errorCount = 3;
      final frame = plain(renderFrame(state, 60, 20));
      expect(frame.first, contains('3 err'));
    });

    test('shows log lines, newest at the bottom', () {
      final state = connectedState();
      for (var index = 0; index < 5; index++) {
        state.addLog(LogLine(LogSource.stdout, 'line $index'));
      }
      final frame = plain(renderFrame(state, 60, 12));
      final first = frame.indexWhere((line) => line.contains('line 0'));
      final last = frame.indexWhere((line) => line.contains('line 4'));
      expect(first, greaterThan(0));
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
      expect(frame.first, contains('no app'));
    });

    test('the keys live in the status bar, not in the body', () {
      final state = AppState(config: const PluginConfig())
        ..firstScanDone = true;
      final frame = plain(renderFrame(state, 60, 14));
      expect(frame.last, contains('D rescan'));
      expect(frame.last, contains('q quit'));
      // The body used to repeat them as a key list, which wasted two rows. It
      // still explains what D does in prose, which is not the same thing.
      final body = frame.sublist(1, frame.length - 1).join('\n');
      expect(body.contains('D rescan'), isFalse);
      expect(body.contains('q quit'), isFalse);
    });

    test('the help overlay lists the reload keys', () {
      final state = connectedState()..overlay = Overlay.help;
      final frame = plain(renderFrame(state, 60, 30));
      expect(frame.any((line) => line.contains('hot reload')), isTrue);
      expect(frame.any((line) => line.contains('hot restart')), isTrue);
    });

    test('a click on the top row maps to the view it is over', () {
      final state = connectedState();
      final spans = tabSpans(state, 60);
      for (final span in spans) {
        expect(tabAt(state, 60, span.start), span.view);
        expect(tabAt(state, 60, span.end - 1), span.view);
      }
      // Past the last tab there is nothing to click.
      expect(tabAt(state, 60, spans.last.end), isNull);
      expect(tabAt(state, 60, 59), isNull);
    });

    test('the tab spans line up with what was drawn', () {
      final state = connectedState()..view = View.errors;
      final frame = plain(renderFrame(state, 60, 12));
      for (final span in tabSpans(state, 60)) {
        expect(
          frame.first.substring(span.start, span.end),
          span.text,
          reason: 'span for ${span.view} must match the drawn row',
        );
      }
    });

    test('the hit map lines up row for row with a list body', () {
      final state = connectedState()..view = View.errors;
      for (var index = 0; index < 3; index++) {
        state.errors.add(
          ErrorItem.fromEventData({'description': 'boom $index'}),
        );
      }
      state.errorIndex = 1;
      final frame = renderFrame(state, 60, 12);
      final body = frame.sublist(1, frame.length - 1);
      expect(state.hitRows.length, lessThanOrEqualTo(body.length));
      for (final (row, item) in state.hitRows.indexed) {
        if (item == null) continue;
        expect(
          plain([body[row]]).single,
          contains(state.errors[item].summary),
          reason: 'body row $row must belong to error $item',
        );
      }
    });

    test('the hit map skips the title rows of an overlay list', () {
      final state = connectedState()..overlay = Overlay.targets;
      state.targets = [
        AppTarget(serviceUri: Uri.parse('http://127.0.0.1:1/a=/')),
        AppTarget(serviceUri: Uri.parse('http://127.0.0.1:2/b=/')),
      ];
      final frame = renderFrame(state, 60, 16);
      final body = plain(frame.sublist(1, frame.length - 1));
      final rows = state.hitRows;
      expect(rows.take(3), everyElement(isNull));
      for (final (row, item) in rows.indexed) {
        if (item == null) continue;
        expect(body[row], contains('127.0.0.1:${item + 1}'));
      }
    });

    test('a pre-coloured line keeps its colours and its full width', () {
      const coloured =
          '\x1b[38;5;12m[api]\x1b[0m \x1b[32mGET /spots 200\x1b[0m in 84ms';
      final state = connectedState()
        ..addLog(LogLine(LogSource.developer, coloured));
      final frame = renderFrame(state, 60, 8);
      // Escape bytes used to count as width, which wrapped the line early.
      expect(plain(frame).any((line) => line.contains('in 84ms')), isTrue);
      expect(frame[1], contains('\x1b[38;5;12m'));
      expect(frame[1], contains('\x1b[32m'));
      expect(visibleWidth(frame[1]), lessThanOrEqualTo(60));
    });

    test('a severe record is red and a warning is yellow', () {
      final state = connectedState()
        ..addLog(
          LogLine(LogSource.developer, 'boom', name: 'Bloc', level: 1000),
        )
        ..addLog(LogLine(LogSource.developer, 'careful', level: 900));
      final frame = renderFrame(state, 60, 8);
      final severe = frame.firstWhere((line) => line.contains('boom'));
      final warning = frame.firstWhere((line) => line.contains('careful'));
      expect(severe, contains('\x1b[31m'));
      expect(warning, contains('\x1b[33m'));
      // The logger name is shown apart from the message.
      expect(plain([severe]).single, contains('Bloc boom'));
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
