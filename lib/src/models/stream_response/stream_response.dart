import 'dart:async';
import 'dart:io';

import 'package:http_cache_stream/http_cache_stream.dart';
import 'package:http_cache_stream/src/cache_stream/response_streams/combined_cache_stream.dart';
import 'package:http_cache_stream/src/cache_stream/response_streams/download_stream.dart';
import 'package:http_cache_stream/src/cache_stream/response_streams/file_stream.dart';

abstract class StreamResponse {
  final IntRange range;
  const StreamResponse(this.range);
  Stream<List<int>> get stream;
  ResponseSource get source;
  int? get sourceLength;

  static Future<StreamResponse> fromDownload(
    final Uri url,
    final IntRange range,
    final StreamCacheConfig config,
  ) {
    return DownloadStreamResponse.construct(url, range, config);
  }

  factory StreamResponse.fromFile(
    final IntRange range,
    final File file,
    final int? sourceLength,
  ) {
    return FileStreamResponse(file, range, sourceLength);
  }

  factory StreamResponse.fromCacheStream(
    final IntRange range,
    final File partialCacheFile,
    Stream<List<int>> dataStream,
    final int dataStreamPosition,
    final int? sourceLength,
  ) {
    final effectiveEnd = range.end ?? sourceLength;
    if (effectiveEnd != null && dataStreamPosition >= effectiveEnd) {
      //We can fully serve the request from the file
      return StreamResponse.fromFile(range, partialCacheFile, sourceLength);
    } else {
      return CombinedCacheStreamResponse.construct(range, partialCacheFile,
          dataStream, dataStreamPosition, sourceLength);
    }
  }

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

  bool get isPartial {
    return contentLength != null && contentLength! < sourceLength!;
  }

  void close();

  @override
  String toString() {
    return 'StreamResponse{range: $range, source: $source contentLength: $contentLength, sourceLength: $sourceLength}';
  }
}

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
