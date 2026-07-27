import 'dart:convert';

/// One HTTP request as `dart:io`'s profiler reports it.
///
/// The JSON is parsed here rather than through `package:vm_service`'s own
/// classes: the shape is part of the service protocol, and owning the parsing
/// keeps the model readable in a test without a running app. Only what the
/// sidebar shows is kept; the raw map rides along for the report.
class HttpCall {
  HttpCall({
    required this.id,
    required this.method,
    required this.uri,
    required this.startMicros,
    required this.raw,
    this.requestEndMicros,
    this.endMicros,
    this.statusCode,
    this.reasonPhrase,
    this.requestBytes,
    this.responseBytes,
    this.error,
    this.requestHeaders = const {},
    this.responseHeaders = const {},
    this.redirects = const [],
    this.events = const [],
  });

  factory HttpCall.fromJson(Map<String, Object?> json) {
    final request = _asMap(json['request']);
    final response = _asMap(json['response']);
    return HttpCall(
      id: json['id']?.toString() ?? '',
      method: json['method']?.toString() ?? '?',
      uri: Uri.tryParse(json['uri']?.toString() ?? '') ?? Uri(),
      startMicros: _asInt(json['startTime']) ?? 0,
      requestEndMicros: _asInt(json['endTime']),
      endMicros: _asInt(response?['endTime']),
      statusCode: _asInt(response?['statusCode']),
      reasonPhrase: response?['reasonPhrase']?.toString(),
      requestBytes: _asSize(request?['contentLength']),
      responseBytes: _asSize(response?['contentLength']),
      // A request that never left and one that failed mid-response both matter,
      // and only one of the two carries the message.
      error:
          _asText(request?['error']) ??
          _asText(response?['error']) ??
          _asText(json['error']),
      requestHeaders: _headers(request?['headers']),
      responseHeaders: _headers(response?['headers']),
      redirects: _redirects(response?['redirects']),
      events: _events(json['events']),
      raw: json,
    );
  }

  /// The profiler's own id, stable across polls, which is what merges updates.
  final String id;

  final String method;
  final Uri uri;

  /// Device clock, in microseconds. Never compared against this process's clock:
  /// a phone on the other end of a tunnel does not share it.
  final int startMicros;

  /// When the request itself was sent, which can be well before the response.
  final int? requestEndMicros;

  /// When the response was fully received, null while it still is not.
  final int? endMicros;

  final int? statusCode;
  final String? reasonPhrase;
  final int? requestBytes;
  final int? responseBytes;
  final String? error;
  final Map<String, String> requestHeaders;
  final Map<String, String> responseHeaders;
  final List<String> redirects;
  final List<HttpEvent> events;
  final Map<String, Object?> raw;

  bool get isComplete => endMicros != null || error != null;
  bool get hasError => error != null;
  bool get isFailure => hasError || (statusCode != null && statusCode! >= 400);

  /// How long the call took, or how long it has been running when [nowMicros] is
  /// the device clock as of the last poll.
  Duration? duration({int? nowMicros}) {
    final end = endMicros ?? (hasError ? requestEndMicros : nowMicros);
    if (end == null) return null;
    final elapsed = end - startMicros;
    return elapsed < 0 ? null : Duration(microseconds: elapsed);
  }

  /// What identifies the call in a list: the path, with its query when there is
  /// room for it. The host goes on the second row, since it repeats.
  String get path {
    final path = uri.path.isEmpty ? '/' : uri.path;
    return uri.query.isEmpty ? path : '$path?${uri.query}';
  }

  String get host {
    if (uri.host.isEmpty) return uri.toString();
    final port = uri.hasPort && uri.port != 80 && uri.port != 443
        ? ':${uri.port}'
        : '';
    return '${uri.host}$port';
  }

  String get contentType => responseHeaders['content-type'] ?? '';

  static Map<String, Object?>? _asMap(Object? value) =>
      value is Map ? Map<String, Object?>.from(value) : null;

  static int? _asInt(Object? value) => value is int
      ? value
      : (value is num ? value.toInt() : int.tryParse('$value'));

  /// dart:io reports an unknown length as -1 rather than as a missing field.
  static int? _asSize(Object? value) {
    final size = _asInt(value);
    return size == null || size < 0 ? null : size;
  }

  static String? _asText(Object? value) {
    if (value == null) return null;
    final text = value.toString().trim();
    return text.isEmpty || text == 'null' ? null : text;
  }

  /// Header values arrive as lists, since a header can repeat.
  static Map<String, String> _headers(Object? value) {
    final source = _asMap(value);
    if (source == null) return const {};
    return {
      for (final entry in source.entries)
        entry.key.toLowerCase(): entry.value is List
            ? (entry.value as List).join(', ')
            : '${entry.value}',
    };
  }

  static List<String> _redirects(Object? value) {
    if (value is! List) return const [];
    return [
      for (final hop in value)
        if (hop is Map)
          '${hop['method'] ?? 'GET'} ${hop['location'] ?? ''}'.trim(),
    ];
  }

  static List<HttpEvent> _events(Object? value) {
    if (value is! List) return const [];
    return [
      for (final event in value)
        if (event is Map && event['event'] != null)
          HttpEvent(
            '${event['event']}',
            _asInt(event['timestamp']) ?? 0,
            arguments: _asMap(event['arguments']),
          ),
    ];
  }
}

/// A step of a request, as the profiler timestamps it.
class HttpEvent {
  const HttpEvent(this.name, this.micros, {this.arguments});

  final String name;
  final int micros;
  final Map<String, Object?>? arguments;
}

/// A body as it will be shown: decoded when it is text, measured when it is not.
class HttpBody {
  const HttpBody({required this.byteCount, this.text});

  /// Bodies are held in the app's memory until the profile is cleared, so a
  /// large one is described rather than carried around whole.
  static const maxTextBytes = 512 * 1024;

  final int byteCount;

  /// Null when the bytes are not text, which is what an image or a protobuf is.
  final String? text;

  bool get isBinary => text == null;

  /// Decode the byte list the profiler returns, pretty-printing JSON.
  ///
  /// The content type decides nothing: an API that answers JSON under
  /// `text/plain` is common enough that the bytes themselves are the better
  /// signal.
  static HttpBody? fromBytes(Object? value) {
    if (value is! List) return null;
    final bytes = <int>[];
    for (final byte in value) {
      if (byte is int) bytes.add(byte);
    }
    if (bytes.isEmpty) return null;
    if (bytes.length > maxTextBytes) return HttpBody(byteCount: bytes.length);
    final String decoded;
    try {
      decoded = utf8.decode(bytes);
    } on FormatException {
      return HttpBody(byteCount: bytes.length);
    }
    if (_looksBinary(decoded)) return HttpBody(byteCount: bytes.length);
    return HttpBody(byteCount: bytes.length, text: _pretty(decoded));
  }

  static bool _looksBinary(String text) {
    for (final rune in text.runes) {
      if (rune == 0x09 || rune == 0x0a || rune == 0x0d) continue;
      if (rune < 0x20 || rune == 0x7f) return true;
    }
    return false;
  }

  static String _pretty(String text) {
    final trimmed = text.trim();
    if (!trimmed.startsWith('{') && !trimmed.startsWith('[')) return text;
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(trimmed));
    } on FormatException {
      return text;
    }
  }
}

/// A call with the bodies that only `getHttpProfileRequest` carries.
class HttpCallDetail {
  const HttpCallDetail({required this.call, this.request, this.response});

  factory HttpCallDetail.fromJson(Map<String, Object?> json) => HttpCallDetail(
    call: HttpCall.fromJson(json),
    request: HttpBody.fromBytes(json['requestBody']),
    response: HttpBody.fromBytes(json['responseBody']),
  );

  final HttpCall call;
  final HttpBody? request;
  final HttpBody? response;
}

/// A size in the shortest form that stays exact enough to compare two calls.
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} kB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// A duration at the precision that matters for a request.
String formatDuration(Duration duration) {
  final micros = duration.inMicroseconds;
  if (micros < 1000) return '${micros}µs';
  if (micros < 10 * 1000) return '${(micros / 1000).toStringAsFixed(1)}ms';
  if (micros < 1000 * 1000) return '${duration.inMilliseconds}ms';
  return '${(micros / 1000000).toStringAsFixed(2)}s';
}
