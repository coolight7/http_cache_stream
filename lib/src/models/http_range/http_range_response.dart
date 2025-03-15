import 'dart:io';

import 'http_range.dart';

class HttpRangeResponse extends HttpRange {
  const HttpRangeResponse._(super.start, super.end, {super.sourceLength});

  static HttpRangeResponse? parse(HttpClientResponse response) {
    final contentRangeHeader = response.headers.value(HttpHeaders.contentRangeHeader);
    if (contentRangeHeader == null || contentRangeHeader.isEmpty) return null;
    var (int? start, int? end, int? sourceLength) = HttpRange.parse(contentRangeHeader);
    if (start == null && end == null && sourceLength == null) {
      return null;
    }
    start ??= 0;
    if (sourceLength == null && start == 0 && end == null && response.contentLength > 0) {
      sourceLength = response.contentLength; // If the source length is unknown, use the content length
    }

    return HttpRangeResponse._(start, end, sourceLength: sourceLength);
  }

  /// Creates a [HttpRangeResponse] from an exclusive end range by converting it to inclusive.
  /// For example: if given start=0, end=100 (exclusive), creates a range of 0-99 (inclusive).
  factory HttpRangeResponse.inclusive(int start, int? end, {int? sourceLength}) {
    return HttpRangeResponse._(start, end == null ? null : end - 1, sourceLength: sourceLength);
  }

  String get header {
    final bytes = 'bytes $start-${end ?? ""}';
    return '$bytes/${sourceLength ?? "*"}';
  }

  @override
  String toString() {
    return 'HttpRangeResponse: $start: $start, end: $end, sourceLength: $sourceLength';
  }
}
