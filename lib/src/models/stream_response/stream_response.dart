import 'dart:io';

import 'package:http_cache_stream/src/cache_stream/cache_response_streams/byte_limit_transformer.dart';
import 'package:http_cache_stream/src/cache_stream/cache_response_streams/combined_cache_stream.dart';
import 'package:http_cache_stream/src/models/config/stream_cache_config.dart';
import 'package:http_cache_stream/src/models/stream_response/int_range.dart';

import '../../cache_stream/cache_response_streams/live_download_stream.dart';

enum ResponseSource {
  ///A stream response that is served from an independent download stream.
  ///This is separate download stream from the active cache download stream, and is used to fulfill range requests starting beyond the active cache position.
  download,

  ///A stream response that is served from a partial cache file and the active cache download stream.
  ///Data from the download stream is buffered until a listener is added. The stream must be read to completion or cancelled to release buffered data. If you no longer need the stream, you must manually call [cancel] to avoid memory leaks.
  ///This can be interperted as a combination of [ResponseSource.download] and [ResponseSource.cacheFile]. The file represents the partial cache file, and the download stream represents the active cache download.
  cacheStream,

  ///A stream response that is served exclusively from cached data saved to a file.
  cacheFile,
}

class StreamResponse {
  final IntRange range;
  final ResponseSource source;
  final Stream<List<int>> stream;
  final int? sourceLength;

  const StreamResponse({
    required this.range,
    required this.stream,
    required this.sourceLength,
    required this.source,
  });

  factory StreamResponse.fromDownload(
    Uri uri,
    IntRange range,
    int? sourceLength,
    StreamCacheConfig cacheConfig,
  ) {
    return StreamResponse(
      range: range,
      stream: LiveDownloadStream(uri, range, cacheConfig),
      sourceLength: sourceLength,
      source: ResponseSource.download,
    );
  }

  factory StreamResponse.fromFile(
    IntRange range,
    File file,
    int? sourceLength,
  ) {
    return StreamResponse(
      range: range,
      stream: file.openRead(range.start, range.end),
      sourceLength: sourceLength,
      source: ResponseSource.cacheFile,
    );
  }

  factory StreamResponse.fromCacheStream(
    IntRange range,
    File partialCacheFile,
    Stream<List<int>> dataStream,
    int position,
    int? sourceLength,
  ) {
    assert(position >= range.start, 'Position must be greater than or equal to range.start (pos: $position, start: ${range.start})');
    final requestEnd = range.end;
    final effectiveEnd = requestEnd ?? sourceLength;
    if (effectiveEnd != null && position >= effectiveEnd) {
      return StreamResponse.fromFile(range, partialCacheFile, sourceLength);
    }
    if (requestEnd != null && requestEnd > position && (sourceLength == null || requestEnd < sourceLength)) {
      final streamEnd = requestEnd - position;
      dataStream = dataStream.transform(ByteLimitTransformer(streamEnd));
    }
    final stream = CombinedCacheStream(
      fileStream: partialCacheFile.openRead(range.start, position),
      dataStream: dataStream,
    );
    return StreamResponse(
      range: range,
      stream: stream,
      sourceLength: sourceLength,
      source: ResponseSource.cacheStream,
    );
  }

  ///The length of the content in the response. This may be different from the source length.
  int? get contentLength {
    final effectiveEnd = this.effectiveEnd;
    if (effectiveEnd == null) return null;
    return effectiveEnd - effectiveStart;
  }

  ///The effective end of the response. If the response is a full response, this will be the source length. If the response is a partial response, this will be the end of the range.
  int? get effectiveEnd {
    return range.end ?? sourceLength;
  }

  int get effectiveStart {
    return range.start;
  }

  bool get isPartial {
    return contentLength != null && contentLength! < sourceLength!;
  }

  ///A [StreamResponse] with [ResponseSource.cacheStream] buffers data from the active cache download stream.
  ///Listening to the stream until completion or cancelling the stream will release buffered data.
  ///However, if you no longer need the [stream], you must manually call this function to avoid memory leaks.
  void cancel() {
    if (stream is CombinedCacheStream) {
      (stream as CombinedCacheStream).cancel();
    }
  }

  @override
  String toString() {
    return 'StreamResponse{range: $range, source: $source contentLength: $contentLength, sourceLength: $sourceLength}';
  }
}
