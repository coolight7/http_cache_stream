import 'dart:async';
import 'dart:io';

import 'package:string_util_xx/StringUtilxx.dart';
import 'package:util_xx/util_xx.dart';

import '../../http_cache_stream.dart';
import '../etc/mime_types.dart';
import '../models/exceptions/invalid_cache_exceptions.dart';
import '../models/http_range/http_range.dart';
import '../models/http_range/http_range_request.dart';
import '../models/http_range/http_range_response.dart';
import '../request_handler/socket_handler.dart';

class RequestHandler {
  final HttpRequest _request;
  RequestHandler(this._request);
  bool _requestClosed = false;
  SocketHandler? _socketHandler;

  Future<void> stream(final HttpCacheStream cacheStream) async {
    final timeoutTimer = Timer(cacheStream.config.requestTimeout,
        () => close(HttpStatus.gatewayTimeout));

    StreamResponse? streamResponse;
    try {
      final useHeader = Httpxx_c.createHeader();
      // 过滤不规范的 header
      _request.headers.forEach((name, values) {
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
      // 阻止使用 chunked
      useHeader[HttpHeaders.acceptEncodingHeader] = 'identity';
      cacheStream.config.requestHeaders = useHeader;

      final rangeRequest = HttpRangeRequest.parse(_request);
      switch (_request.method.toUpperCase()) {
        case 'GET':
          streamResponse = await cacheStream.request(
              start: rangeRequest?.start, end: rangeRequest?.endEx);
        case 'HEAD':
          streamResponse = await cacheStream.head(
              start: rangeRequest?.start, end: rangeRequest?.endEx);
        default:
          close(HttpStatus.methodNotAllowed);
          return;
      }

      if (_requestClosed) {
        return; //Request closed before we could start streaming
      }

      _setHeaders(
        rangeRequest,
        cacheStream.config,
        streamResponse,
      ); //Set the headers for the response before starting the stream

      if (streamResponse.isEmpty) {
        //HEAD request or empty range
        close();
        return;
      }

      timeoutTimer.cancel();
      _requestClosed = true; //Response is now being handled via socket
      _socketHandler = SocketHandler(
          await _request.response.detachSocket(writeHeaders: true));
      await _socketHandler?.writeResponse(
          streamResponse.stream, cacheStream.config.readTimeout);
      _socketHandler = null; //Clear the socket handler after done.
    } catch (e, stack) {
      closeWithError(e, stack, cacheStream.metadata.headers);
    } finally {
      timeoutTimer.cancel();
      _socketHandler?.destroy();
      _socketHandler = null;
      streamResponse
          ?.cancel(); //Ensure we cancel the stream response to free resources.
      streamResponse = null;
    }
  }

  void closeWithError(final Object e,
      [final Object? stack, final CachedResponseHeaders? headers]) {
    int? statusCode;

    if (!_requestClosed) {
      switch (e) {
        case RangeError() || HttpRangeException():
          statusCode = HttpStatus.requestedRangeNotSatisfiable;
          if (headers?.sourceLength case final int sourceLength) {
            _request.response.headers
                .set(HttpHeaders.contentRangeHeader, 'bytes */$sourceLength');
          }
        case TimeoutException():
          statusCode = HttpStatus.gatewayTimeout;
        default:
          statusCode = HttpStatus.internalServerError;
      }
    }

    close(statusCode, e);
  }

  void _setHeaders(
    final HttpRangeRequest? rangeRequest,
    final StreamCacheConfig cacheConfig,
    final StreamResponse streamResponse,
  ) {
    final httpResponse = _request.response;
    httpResponse.headers.clear();
    final cacheHeaders = streamResponse.sourceHeaders;

    if (cacheHeaders.acceptsRangeRequests) {
      httpResponse.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    }
    if (cacheConfig.copyCachedResponseHeaders) {
      cacheHeaders.forEach((key, value) {
        if (StringUtilxx_c.isIgnoreCaseEqual(
            key, HttpHeaders.transferEncodingHeader)) {
          return;
        }
        try {
          httpResponse.headers.set(key, value);
        } catch (_) {}
      });
    }
    {
      final useHeader = cacheConfig.combinedResponseHeaders();
      for (final item in useHeader.entries) {
        if (StringUtilxx_c.isIgnoreCaseEqual(
            item.key, HttpHeaders.transferEncodingHeader)) {
          return;
        }
        try {
          httpResponse.headers.set(item.key, item.value);
        } catch (_) {}
      }
    }

    String? contentType =
        httpResponse.headers[HttpHeaders.contentTypeHeader]?.firstOrNull ??
            cacheHeaders.get(HttpHeaders.contentTypeHeader);
    if (contentType == null ||
        contentType.isEmpty ||
        contentType == MimeTypes.octetStream) {
      contentType =
          MimeTypes.fromPath(_request.uri.path) ?? MimeTypes.octetStream;
    }
    httpResponse.headers.set(HttpHeaders.contentTypeHeader, contentType);

    if (rangeRequest == null) {
      httpResponse.contentLength = streamResponse.sourceLength ?? -1;
      httpResponse.statusCode = HttpStatus.ok;
    } else {
      final rangeResponse = HttpRangeResponse.inclusive(
        streamResponse.effectiveStart,
        streamResponse.effectiveEnd,
        streamResponse.sourceLength,
      );
      httpResponse.headers.set(
        HttpHeaders.contentRangeHeader,
        rangeResponse.header,
      );

      httpResponse.contentLength = rangeResponse.contentLength ?? -1;
      httpResponse.statusCode = HttpStatus.partialContent;
      assert(
        HttpRange.isEqual(rangeRequest, rangeResponse),
        'Invalid HttpRange: request: $rangeRequest | response: $rangeResponse | StreamResponse.Range: ${streamResponse.range}',
      );
    }
  }

  void close([int? statusCode, Object? error, Object? stack]) {
    if (null != error) {
      CustomHttpClientxx.onLog?.call('Req Error: $error', stack);
    }
    if (!_requestClosed) {
      _requestClosed = true;
      if (statusCode != null) {
        _request.response.statusCode = statusCode;
      }
      _request.response.close().ignore();
    }

    _socketHandler?.destroy();
    _socketHandler = null;
  }

  bool get isClosed => _socketHandler?.isClosed ?? _requestClosed;
  Uri get uri => _request.uri;
}
