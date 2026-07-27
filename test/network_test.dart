import 'dart:convert';

import 'package:herdr_flutter/src/discovery.dart';
import 'package:herdr_flutter/src/network.dart';
import 'package:herdr_flutter/src/report.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  group('HttpCall', () {
    test('reads what the list needs from a profile entry', () {
      final call = calls().first;
      expect(call.id, '1');
      expect(call.method, 'GET');
      expect(call.statusCode, 200);
      expect(call.reasonPhrase, 'OK');
      expect(call.path, '/v1/spots?near=48.85');
      expect(call.host, 'api.example.com');
      expect(call.responseBytes, 842);
      expect(call.contentType, 'application/json; charset=utf-8');
      expect(call.isComplete, isTrue);
      expect(call.isFailure, isFalse);
    });

    test('measures from the start to the end of the response', () {
      expect(calls().first.duration(), const Duration(milliseconds: 124));
    });

    test('an unknown content length is not reported as a size', () {
      expect(calls().first.requestBytes, isNull);
    });

    test('header names are lower-cased and repeated values joined', () {
      final call = HttpCall.fromJson({
        'id': '9',
        'method': 'GET',
        'uri': 'https://example.com/',
        'startTime': 0,
        'response': {
          'headers': {
            'Set-Cookie': ['a=1', 'b=2'],
            'Server': 'nginx',
          },
        },
      });
      expect(call.responseHeaders['set-cookie'], 'a=1, b=2');
      expect(call.responseHeaders['server'], 'nginx');
    });

    test('a request still running has no duration of its own', () {
      final pending = calls()[1];
      expect(pending.isComplete, isFalse);
      expect(pending.statusCode, isNull);
      expect(pending.duration(), isNull);
    });

    test('the device clock measures how long a running request has taken', () {
      // Never this process's clock: the app may be on a phone behind a tunnel.
      final elapsed = calls()[1].duration(nowMicros: 1700000000900000);
      expect(elapsed, const Duration(milliseconds: 400));
    });

    test('a failed request carries its error and counts as finished', () {
      final failed = calls()[2];
      expect(failed.error, contains('Connection refused'));
      expect(failed.hasError, isTrue);
      expect(failed.isFailure, isTrue);
      expect(failed.isComplete, isTrue);
      expect(failed.duration(), const Duration(milliseconds: 60));
    });

    test('events keep their timestamps for the timeline', () {
      final event = calls().first.events.single;
      expect(event.name, 'Connection established');
      expect(event.micros - calls().first.startMicros, 4000);
    });

    test('a malformed entry does not throw', () {
      final call = HttpCall.fromJson({'id': 'x'});
      expect(call.method, '?');
      expect(call.path, '/');
      expect(call.duration(), isNull);
    });
  });

  group('HttpBody', () {
    test('pretty-prints a JSON body whatever its content type says', () {
      final body = HttpBody.fromBytes(utf8.encode('{"id":1,"name":"Spot"}'));
      expect(body!.text, '{\n  "id": 1,\n  "name": "Spot"\n}');
      expect(body.byteCount, 22);
      expect(body.isBinary, isFalse);
    });

    test('leaves text that is not JSON alone', () {
      expect(
        HttpBody.fromBytes(utf8.encode('plain answer'))!.text,
        'plain answer',
      );
    });

    test('describes bytes that are not text rather than printing them', () {
      final body = HttpBody.fromBytes([0x89, 0x50, 0x4e, 0x47, 0x00, 0x1a]);
      expect(body!.isBinary, isTrue);
      expect(body.byteCount, 6);
    });

    test('an empty body is no body at all', () {
      expect(HttpBody.fromBytes(<int>[]), isNull);
      expect(HttpBody.fromBytes(null), isNull);
    });

    test('reads a whole request answer, bodies included', () {
      final detail = HttpCallDetail.fromJson({
        'id': '1',
        'method': 'POST',
        'uri': 'https://api.example.com/v1/spots',
        'startTime': 0,
        'requestBody': utf8.encode('{"name":"Spot"}'),
        'responseBody': utf8.encode('{"id":7}'),
        'response': {'statusCode': 201},
      });
      expect(detail.call.statusCode, 201);
      expect(detail.request!.text, contains('"name": "Spot"'));
      expect(detail.response!.text, contains('"id": 7'));
    });
  });

  group('formatting', () {
    test('sizes shorten as they grow', () {
      expect(formatBytes(512), '512 B');
      expect(formatBytes(2048), '2.0 kB');
      expect(formatBytes(3 * 1024 * 1024), '3.0 MB');
    });

    test('durations keep the precision that matters', () {
      expect(formatDuration(const Duration(microseconds: 800)), '800µs');
      expect(formatDuration(const Duration(microseconds: 4200)), '4.2ms');
      expect(formatDuration(const Duration(milliseconds: 124)), '124ms');
      expect(formatDuration(const Duration(milliseconds: 1500)), '1.50s');
    });
  });

  group('report', () {
    test('a request report carries the call, its headers and its bodies', () {
      final report = Report(
        target: AppTarget(serviceUri: Uri.parse('http://127.0.0.1:1/a=/')),
      );
      final detail = HttpCallDetail(
        call: calls().first,
        response: HttpBody.fromBytes(utf8.encode('{"spots":[]}')),
      );
      final markdown = report.httpCall(calls().first, detail: detail);
      expect(markdown, contains('GET https://api.example.com/v1/spots'));
      expect(markdown, contains('Status: 200 OK'));
      expect(markdown, contains('Took: 124ms'));
      expect(markdown, contains('`accept`: application/json'));
      expect(markdown, contains('"spots": []'));
    });

    test('a failed request says so instead of inventing a status', () {
      final report = Report(
        target: AppTarget(serviceUri: Uri.parse('http://127.0.0.1:1/a=/')),
      );
      final markdown = report.httpCall(calls()[2]);
      expect(markdown, contains('Error: SocketException'));
      expect(markdown.contains('Status:'), isFalse);
    });
  });
}
