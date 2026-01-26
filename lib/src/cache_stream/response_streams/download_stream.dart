import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart' as libdio;
import 'package:http_cache_stream/http_cache_stream.dart';
import 'package:http_cache_stream/src/models/exceptions/invalid_cache_exceptions.dart';
import 'package:http_cache_stream/src/models/http_range/http_range_response.dart';
import 'package:util_xx/Httpxx.dart';

import '../../models/exceptions/http_exceptions.dart';

class DownloadStream extends Stream<List<int>> {
  final libdio.ResponseBody _streamedResponse;
  final libdio.CancelToken? cancelToken;

  DownloadStream(this._streamedResponse, this.cancelToken);

  static Future<DownloadStream> open(
    final Uri url,
    final IntRange range,
    final StreamCacheConfig config,
  ) async {
    final useHeader =
        Httpxx_c.createHeader(data: config.combinedRequestHeaders());
    final rangeRequest = range.isFull ? null : range.rangeRequest;
    if (rangeRequest != null) {
      useHeader[HttpHeaders.rangeHeader] = rangeRequest.header;
    }
    final cancelToken = libdio.CancelToken();
    try {
      final resp = (await config.httpClient.getUrl(
        url,
        range,
        useHeader,
        cancelToken: cancelToken,
      ))
          .data;
      if (null == resp) {
        throw HttpStatusCodeException(url, 200, null);
      }

      if (rangeRequest == null) {
        HttpStatusCodeException.validateCompleteResponse(
          url,
          resp.statusCode,
          resp.headers,
        );
      } else {
        HttpRangeException.validate(
          url,
          rangeRequest,
          HttpRangeResponse.parseFromHeader(resp.headers),
        );
      }
      return DownloadStream(resp, cancelToken);
    } catch (e) {
      try {
        cancelToken.cancel();
      } catch (_) {}
      rethrow;
    }
  }

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    _listened = true;
    return _streamedResponse.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  void cancel() {
    if (_listened) return;
    try {
      cancelToken?.cancel();
    } catch (_) {}
  }

  bool _listened = false;
  libdio.ResponseBody get baseResponse => _streamedResponse;

  HttpRangeResponse? get responseRange {
    return HttpRangeResponse.parseFromHeader(baseResponse.headers);
  }

  int? get sourceLength {
    if (baseResponse.headers.containsKey(HttpHeaders.contentRangeHeader)) {
      return responseRange?.sourceLength;
    }
    return baseResponse.contentLength;
  }

  CachedResponseHeaders get responseHeaders {
    return CachedResponseHeaders.fromBaseResponse(baseResponse.headers);
  }

  int get statusCode => baseResponse.statusCode;
}
