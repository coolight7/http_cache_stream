import 'dart:async';

import '../../cache_stream/cache_downloader/buffered_io_sink.dart';
import '../../cache_stream/response_streams/partial_cache_file_stream.dart';
import '../cache_files/cache_files.dart';
import '../metadata/cached_response_headers.dart';
import '../stream_requests/int_range.dart';
import 'stream_response.dart';
import 'stream_response_range.dart';

/// A response served from a cache file that is still being written.
class PartialFileStreamResponse extends StreamResponse {
  final StreamRange _streamRange;
  final CacheFiles _cacheFiles;
  final PartialCacheFeed _feed;

  const PartialFileStreamResponse._(
    super.range,
    super.responseHeaders,
    this._streamRange,
    this._cacheFiles,
    this._feed,
  );

  factory PartialFileStreamResponse(
    final IntRange range,
    final CacheFiles cacheFiles,
    final CachedResponseHeaders responseHeaders,
    final PartialCacheFeed feed,
  ) {
    final streamRange = StreamRange(range, responseHeaders.sourceLength);
    return PartialFileStreamResponse._(
      streamRange.range,
      responseHeaders,
      streamRange,
      cacheFiles,
      feed,
    );
  }

  @override
  Stream<List<int>> get stream =>
      PartialCacheFileStream(_streamRange, _cacheFiles, _feed);

  @override
  ResponseSource get source => ResponseSource.partialCacheFile;

  @override
  void cancel() {
    // Streams are created on demand and own their subscription resources.
  }
}
