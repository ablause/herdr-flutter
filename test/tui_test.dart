import 'dart:convert';

import 'package:herdr_flutter/src/app_state.dart';
import 'package:herdr_flutter/src/config.dart';
import 'package:herdr_flutter/src/discovery.dart';
import 'package:herdr_flutter/src/models.dart';
import 'package:herdr_flutter/src/network.dart';
import 'package:herdr_flutter/src/session.dart';
import 'package:herdr_flutter/src/tui/style.dart';
import 'package:herdr_flutter/src/tui/terminal.dart';
import 'package:herdr_flutter/src/views.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

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
  final session = FlutterSession(target: target, onLog: (_) {}, onChange: () {})
    ..state = SessionState.connected;
  state.session = session;
  return state;
}

/// A sidebar showing the network view of an app that recorded the fixture.
AppState networkState() {
  final state = connectedState()..view = View.network;
  state.session!
    ..extensionRpcs = {Ext.httpProfile}
    ..httpProfilingEnabled = true
    ..calls = calls();
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

  group('ClickTracker', () {
    final start = DateTime(2026, 7, 26, 12);
    test('two quick clicks on the same row are a pair', () {
      final tracker = ClickTracker();
      expect(tracker.isRepeat('net', 3, start), isFalse);
      expect(
        tracker.isRepeat(
          'net',
          3,
          start.add(const Duration(milliseconds: 200)),
        ),
        isTrue,
      );
    });

    test('a slow second click is another single click', () {
      final tracker = ClickTracker();
      tracker.isRepeat('net', 3, start);
      expect(
        tracker.isRepeat('net', 3, start.add(const Duration(seconds: 2))),
        isFalse,
      );
    });

    test('two rows clicked in turn are never a pair', () {
      final tracker = ClickTracker();
      tracker.isRepeat('net', 3, start);
      expect(
        tracker.isRepeat('net', 4, start.add(const Duration(milliseconds: 50))),
        isFalse,
      );
    });

    test('a click in another list does not pair with the one before', () {
      final tracker = ClickTracker();
      tracker.isRepeat('net', 3, start);
      expect(
        tracker.isRepeat('err', 3, start.add(const Duration(milliseconds: 50))),
        isFalse,
      );
    });

    test('three clicks are one pair, then a single', () {
      final tracker = ClickTracker();
      var at = start;
      expect(tracker.isRepeat('net', 1, at), isFalse);
      at = at.add(const Duration(milliseconds: 100));
      expect(tracker.isRepeat('net', 1, at), isTrue);
      at = at.add(const Duration(milliseconds: 100));
      expect(tracker.isRepeat('net', 1, at), isFalse);
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
      final frame = plain(renderFrame(connectedState(), 72, 20));
      expect(frame.first, contains('1 logs'));
      expect(frame.first, contains('2 inspect'));
      expect(frame.first, contains('3 net'));
      expect(frame.first, contains('4 info'));
      expect(frame.first, contains('iPhone 17 · live'));
    });

    test('the top row does not repeat the pane name', () {
      final frame = plain(renderFrame(connectedState(), 60, 20));
      expect(frame.first.contains('flutter'), isFalse);
    });

    test('a narrow top row keeps the state and drops the app name', () {
      final frame = plain(renderFrame(connectedState(), 41, 20));
      // The names give way to their short form before the state word does.
      expect(frame.first, contains('3 net'));
      expect(frame.first, contains('live'));
      expect(frame.first.contains('iPhone 17'), isFalse);
    });

    test('a top row with no room left keeps only the tab numbers', () {
      final frame = plain(renderFrame(connectedState(), 30, 20));
      expect(frame.first, contains(' 4 '));
      expect(frame.first.contains('net'), isFalse);
      expect(frame.first, contains('live'));
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

    test('an error shows its summary in the log and its location on open', () {
      final error = ErrorItem.fromEventData({
        'description': 'Exception caught by widgets library',
        'renderedErrorText': 'boom at file:///repo/lib/main.dart:12:3',
        'properties': [
          {'level': 'summary', 'description': 'Null check operator used'},
        ],
      });
      final state = connectedState()..addLog(LogLine.forError(error));
      final log = plain(renderFrame(state, 60, 12));
      expect(
        log.any((line) => line.contains('Null check operator used')),
        isTrue,
      );
      // The location belongs to the detail, which is one keypress away.
      state.overlay = Overlay.errorDetail;
      final detail = plain(renderFrame(state, 60, 12));
      expect(detail.any((line) => line.contains('lib/main.dart:12')), isTrue);
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
      final state = connectedState()..view = View.inspector;
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
      final state = connectedState();
      for (var index = 0; index < 3; index++) {
        state.addLog(LogLine(LogSource.stdout, 'line $index'));
      }
      final frame = renderFrame(state, 60, 12);
      final body = frame.sublist(1, frame.length - 1);
      expect(state.hitRows.length, lessThanOrEqualTo(body.length));
      for (final (row, item) in state.hitRows.indexed) {
        if (item == null) continue;
        expect(
          plain([body[row]]).single,
          contains(state.visibleLogs[item].text),
          reason: 'body row $row must belong to log line $item',
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

    test('the network list shows the outcome, the verb and the path', () {
      final state = networkState();
      final frame = plain(renderFrame(state, 60, 14));
      expect(frame.any((line) => line.contains('200 GET /v1/spots')), isTrue);
      expect(frame.any((line) => line.contains('124ms')), isTrue);
      // The host repeats down the list, so it only shows for the selected row.
      expect(
        frame.any((line) => line.contains('api.example.com · 842 B')),
        isTrue,
      );
    });

    test('a failed request is marked as such rather than left blank', () {
      final state = networkState()..callIndex = 2;
      final frame = plain(renderFrame(state, 60, 14));
      expect(frame.any((line) => line.contains('ERR GET /v1/me')), isTrue);
      expect(frame.any((line) => line.contains('Connection refused')), isTrue);
    });

    test('a request still running shows how long it has been waiting', () {
      final state = networkState();
      state.session!.profileMicros = 1700000000900000;
      final frame = plain(renderFrame(state, 60, 14));
      expect(frame.any((line) => line.contains('··· POST /v1/spots')), isTrue);
      expect(frame.any((line) => line.contains('400ms')), isTrue);
    });

    test('the request detail shows the headers and the fetched bodies', () {
      final state = networkState()
        ..overlay = Overlay.callDetail
        ..callDetail = HttpCallDetail(
          call: calls().first,
          response: HttpBody.fromBytes(utf8.encode('{"spots":[]}')),
        );
      final frame = plain(renderFrame(state, 60, 30));
      final body = frame.join('\n');
      expect(body, contains('GET https://api.example.com/v1/spots'));
      expect(body, contains('200 OK · 124ms · 842 B'));
      expect(body, contains('Connection established'));
      expect(body, contains('accept: application/json'));
      expect(body, contains('"spots": []'));
    });

    test('an app with no dart:io profiler says so', () {
      final state = networkState()..view = View.network;
      state.session!.extensionRpcs = {};
      final frame = plain(renderFrame(state, 60, 14));
      expect(frame.any((line) => line.contains('No HTTP profiler')), isTrue);
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

    test('an error marker sits in the log at the moment it happened', () {
      final error = errorItem();
      final state = connectedState()
        ..addLog(LogLine(LogSource.stdout, 'before the error'))
        ..addLog(
          LogLine(
            LogSource.error,
            error.summary,
            time: error.time,
            level: 1000,
            error: error,
          ),
        )
        ..addLog(LogLine(LogSource.stdout, 'after the error'));
      final frame = renderFrame(state, 70, 10);
      final rows = plain(frame);
      final marker = rows.indexWhere((line) => line.contains('overflowed'));
      expect(marker, greaterThan(0));
      expect(rows[marker], contains('exc'));
      expect(frame[marker], contains('\x1b[1;31m'));
      // Chronology is the whole point of the marker: without it the log would
      // run straight from one line to the other with no sign of the error.
      expect(
        rows.indexWhere((line) => line.contains('before the error')),
        lessThan(marker),
      );
      expect(
        rows.indexWhere((line) => line.contains('after the error')),
        greaterThan(marker),
      );
    });

    test('every row of a wrapped marker points at its own log entry', () {
      final error = errorItem();
      final state = connectedState()
        ..addLog(LogLine(LogSource.stdout, 'first'))
        ..addLog(
          LogLine(
            LogSource.error,
            error.summary,
            time: error.time,
            level: 1000,
            error: error,
          ),
        );
      // Narrow enough that the summary needs more than one row.
      final frame = renderFrame(state, 40, 10);
      final rows = plain(frame);
      final owned = <int>[];
      for (var row = 1; row < rows.length - 1; row++) {
        if (rows[row].trim().isEmpty) continue;
        final item = state.hitRows[row - 1];
        if (item != null && state.visibleLogs[item].error != null) {
          owned.add(row);
        }
      }
      expect(owned.length, greaterThan(1), reason: 'the marker should wrap');
      for (final row in owned) {
        expect(state.visibleLogs[state.hitRows[row - 1]!].error, same(error));
      }
    });

    test('exc: narrows the log to the errors alone', () {
      final state = connectedState()
        ..addLog(LogLine(LogSource.stdout, 'plain output'))
        ..addLog(LogLine.forError(errorItem()))
        ..addLog(LogLine(LogSource.stderr, 'a warning on stderr'));
      expect(state.visibleLogs.length, 3);
      state.filter = 'exc:';
      expect(state.visibleLogs.single.error, isNotNull);
      // A source filter still takes text after it.
      state.filter = 'exc:nothing matches this';
      expect(state.visibleLogs, isEmpty);
    });

    test('a colon that is not a source tag stays a plain search', () {
      final state = connectedState()
        ..addLog(LogLine(LogSource.stdout, 'GET http://host/spots 200'))
        ..addLog(LogLine(LogSource.stdout, 'unrelated'));
      state.filter = 'http://host';
      expect(state.visibleLogs.single.text, contains('http://host'));
    });

    test('the cursor rides the tail until it is moved off it', () {
      final state = connectedState();
      for (var index = 0; index < 5; index++) {
        state.addLog(LogLine(LogSource.stdout, 'line $index'));
      }
      expect(state.selectedLog!.text, 'line 4');
      // Off the tail the cursor stays where it was put, even as more arrives.
      state
        ..follow = false
        ..logIndex = 1;
      state.addLog(LogLine(LogSource.stdout, 'line 5'));
      expect(state.selectedLog!.text, 'line 1');
    });

    test('the cursor marks the selected line and only that one', () {
      final state = connectedState()
        ..addLog(LogLine(LogSource.stdout, 'first'))
        ..addLog(LogLine(LogSource.stdout, 'second'));
      final rows = plain(renderFrame(state, 60, 10));
      final first = rows.firstWhere((line) => line.contains('first'));
      final second = rows.firstWhere((line) => line.contains('second'));
      expect(second, startsWith('›'), reason: 'the tail is selected');
      expect(first, isNot(startsWith('›')));
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
