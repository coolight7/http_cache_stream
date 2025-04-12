import 'dart:async';
import 'dart:io';

import 'package:http_cache_stream/http_cache_stream.dart';
import 'package:http_cache_stream/src/models/config/stream_cache_config.dart';
import 'package:mime/mime.dart';
import 'package:string_util_xx/StringUtilxx.dart';

import '../models/http_range/http_range.dart';
import '../models/http_range/http_range_request.dart';
import '../models/http_range/http_range_response.dart';

class RequestHandler {
  final HttpRequest httpRequest;

  RequestHandler(this.httpRequest) {
    _awaitDone();
  }

  void _awaitDone() async {
    httpRequest.response.bufferOutput = false;
    httpRequest.response.statusCode = HttpStatus
        .internalServerError; //Set default status code to 500, in case of error
    await httpRequest.response.done.catchError((_) {});
    _closed = true;
  }

  void stream(HttpCacheStream cacheStream) async {
    Object? error;
    try {
      final useHeader = <String, Object>{};
      httpRequest.headers.forEach((name, values) {
        if (StringUtilxx_c.isIgnoreCaseContains(
              name,
              HttpHeaders.hostHeader,
            ) ||
            StringUtilxx_c.isIgnoreCaseContains(
              name,
              HttpHeaders.acceptEncodingHeader,
            )) {
          return;
        }
        try {
          final val = values.firstOrNull;
          if (null != val) {
            useHeader[name] = val;
          }
        } catch (_) {}
      });
      cacheStream.config.requestHeaders = useHeader;
      final rangeRequest = HttpRangeRequest.parse(httpRequest);
      final streamResponse = await cacheStream.request(
        rangeRequest?.start,
        rangeRequest?.endEx,
      );
      if (isClosed) {
        streamResponse.cancel(); //Drain buffered data to prevent memory leak
        return; //Request closed before we could send the response
      }
      _setHeaders(
        rangeRequest,
        cacheStream.config,
        cacheStream.metadata.headers,
        streamResponse,
      ); //Set the headers for the response before starting the stream
      _streaming = true;
      //Note: [addStream] will automatically handle pausing/resuming the source stream to avoid buffering the entire response in memory.
      await httpRequest.response.addStream(streamResponse.stream);
    } catch (e) {
      error = e;
    } finally {
      _streaming = false;
      close(error);
    }
  }

  void _setHeaders(
    HttpRangeRequest? rangeRequest,
    StreamCacheConfig cacheConfig,
    CachedResponseHeaders? cacheHeaders,
    StreamResponse streamResponse,
  ) {
    final httpResponse = httpRequest.response;
    httpResponse.headers.clear();
    String? contentTypeHeader;
    if (cacheHeaders != null) {
      if (cacheHeaders.acceptsRangeRequests) {
        httpResponse.headers.set(
          HttpHeaders.acceptRangesHeader,
          'bytes',
        ); //Indicate that the server accepts range requests
      }
      contentTypeHeader = cacheHeaders.get(HttpHeaders.contentTypeHeader);
      if (cacheConfig.copyCachedResponseHeaders) {
        cacheHeaders.forEach(httpResponse.headers.set);
      }
    }
    contentTypeHeader ??=
        lookupMimeType(httpRequest.uri.path) ?? 'application/octet-stream';
    httpResponse.headers.set(HttpHeaders.contentTypeHeader, contentTypeHeader);
    cacheConfig.combinedResponseHeaders().forEach(httpResponse.headers.set);

    if (rangeRequest != null) {
      final rangeResponse = HttpRangeResponse.inclusive(
        rangeRequest.start,
        streamResponse.effectiveEnd,
        sourceLength: streamResponse.sourceLength,
      );
      httpResponse.contentLength = rangeResponse.contentLength ?? -1;
      httpResponse.headers.set(
        HttpHeaders.contentRangeHeader,
        rangeResponse.header,
      );
      httpResponse.statusCode = HttpStatus.partialContent;
      assert(
        HttpRange.isEqual(rangeRequest, rangeResponse),
        'Invalid range: request: $rangeRequest | response: $rangeResponse ',
      );
    } else {
      httpResponse.contentLength = streamResponse.sourceLength ?? -1;
      httpResponse.statusCode = HttpStatus.ok;
    }
  }

  void close([Object? error]) {
    if (_closed) return;
    _closed = true;
    if (error != null && !_streaming) {
      httpRequest.response.addError(error);
    }
    httpRequest.response
        .close()
        .ignore(); //Tell the client that the response is complete.
  }

  ///Indicates if the [HttpResponse] is closed. If true, no more data can be sent to the client.
  bool _closed = false;

  ///Indicate that [addStream] is currently streaming data to the client. When true, the [HttpResponse] cannot be manually written to.
  bool _streaming = false;
  bool get isClosed => _closed;
}
