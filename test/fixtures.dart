import 'dart:convert';
import 'dart:io';

import 'package:herdr_flutter/src/models.dart';
import 'package:herdr_flutter/src/network.dart';

/// A real `Flutter.Error` payload, captured from a Flutter 3.44 debug build
/// running on macOS. Only the deep render-object subtree was trimmed.
Map<String, Object?> flutterError() =>
    jsonDecode(File('test/fixtures/flutter_error.json').readAsStringSync())
        as Map<String, Object?>;

ErrorItem errorItem() => ErrorItem.fromEventData(flutterError());

/// A `getHttpProfile` answer as `dart:io` serializes it: microsecond timestamps
/// on the device's own clock, header values as lists, an unknown content length
/// reported as -1, and one request still in flight.
Map<String, Object?> httpProfile() =>
    jsonDecode(File('test/fixtures/http_profile.json').readAsStringSync())
        as Map<String, Object?>;

List<HttpCall> calls() => [
  for (final entry in httpProfile()['requests'] as List)
    HttpCall.fromJson(Map<String, Object?>.from(entry as Map)),
];
