import 'dart:async';

import '../metadata/cached_response_headers.dart';
import '../stream_requests/int_range.dart';

/// Represents a response from a [HttpCacheStream].
abstract class StreamResponse {
  /// The byte range of the response.
  final IntRange range;

  /// The headers of the source response.
  final CachedResponseHeaders sourceHeaders;
  const StreamResponse(this.range, this.sourceHeaders);

  /// The stream of data for this response.
  Stream<List<int>> get stream;

  /// The source of the response (cache, download, or combined).
  ResponseSource get source;

  /// The total length of the source content, if known.
  int? get sourceLength => sourceHeaders.sourceLength;

  ///The length of the content in the response. This may be different from the source length.
  int? get contentLength {
    final effectiveEnd = this.effectiveEnd;
    if (effectiveEnd == null) return null;
    return effectiveEnd - effectiveStart;
  }

  ///The effective end of the response. If no end is specified, this will be the source length.
  int? get effectiveEnd {
    return range.end ?? sourceLength;
  }

  int get effectiveStart {
    return range.start;
  }

  bool get isPartial => !isFull;

  bool get isFull {
    return range.start == 0 && (range.end == null || range.end == sourceLength);
  }

  bool get isEmpty {
    return effectiveStart == effectiveEnd;
  }

  void cancel();

  @override
  String toString() {
    return 'StreamResponse{range: $range, source: $source contentLength: $contentLength, sourceLength: $sourceLength}';
  }
}

enum ResponseSource {
  /// A [StreamResponse] that contains an empty data stream
  /// Typically used to complete HEAD requests, where no body data is expected.
  headerOnly,

  ///A stream response used to fulfill range requests that exceed [rangeRequestSplitThreshold].
  ///This is an independent download stream from the source URL.
  rangeDownload,

  ///A stream response that is served exclusively from cached data saved to a file.
  cacheFile,

  /// A stream response served from committed bytes in a cache file that is
  /// still being written. It waits for requested positions as needed.
  partialCacheFile,
}
