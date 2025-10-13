import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart' as libdio;
import 'package:flutter/foundation.dart';
import 'package:http_cache_stream/http_cache_stream.dart';
import 'package:http_cache_stream/src/cache_stream/cache_downloader/custom_http_client.dart';
import 'package:http_cache_stream/src/etc/exceptions.dart';
import 'package:http_cache_stream/src/models/http_range/http_range_response.dart';
import 'package:util_xx/Httpxx.dart';

class DownloadStreamResponse extends StreamResponse {
  final DownloadStream _downloadStream;
  const DownloadStreamResponse._(super.range, this._downloadStream);

  static Future<DownloadStreamResponse> construct(final Uri url,
      final IntRange range, final StreamCacheConfig config) async {
    final downloadStream = await DownloadStream.open(
      url,
      range,
      config.httpClient,
      config.combinedRequestHeaders(),
    );
    return DownloadStreamResponse._(range, downloadStream);
  }

  @override
  Stream<List<int>> get stream => _downloadStream;

  @override
  ResponseSource get source => ResponseSource.download;

  @override
  int? get sourceLength => _downloadStream.sourceLength;

  @override
  void close() => _downloadStream.cancel();
}

class DownloadStream extends Stream<List<int>> {
  final libdio.ResponseBody _streamedResponse;
  final Duration autoCancelDelay;

  DownloadStream(
    this._streamedResponse, {
    this.autoCancelDelay = const Duration(seconds: 30),
  }) {
    _autoCancelTimer = Timer(autoCancelDelay, () {
      assert(
        _listened,
        'HttpResponseStream was not listened to before auto-canceling.',
      );
      cancel();
    });
  }

  static Future<DownloadStream> open(
    final Uri url,
    final IntRange range,
    final CustomHttpClientxx client,
    final Map<String, String> requestHeaders,
  ) async {
    final useHeader = Httpxx_c.createHeader(data: requestHeaders);
    final rangeRequest = range.isFull ? null : range.rangeRequest;
    if (rangeRequest != null) {
      useHeader[HttpHeaders.rangeHeader] = rangeRequest.header;
    }
    DownloadStream? downloadStream;
    try {
      final resp = (await client.getUrl(
        url,
        range,
        useHeader,
      ))
          .data;
      if (null == resp) {
        throw HttpStatusCodeException(url, 200, null);
      }
      downloadStream = DownloadStream(resp);
      if (rangeRequest == null) {
        HttpStatusCodeException.validate(
          url,
          downloadStream.statusCode,
        );
      } else {
        HttpRangeException.validate(
          url,
          rangeRequest,
          downloadStream.responseRange,
        );
      }
      return downloadStream;
    } catch (e) {
      downloadStream?.cancel();
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
    _autoCancelTimer.cancel();
    return _streamedResponse.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  ///To cancel the stream, we need to call cancel on the StreamedResponse.
  void cancel() async {
    if (_listened) return;
    try {
      final listener = listen(null, onError: (_) {}, cancelOnError: true);
      await listener.cancel();
    } catch (e) {
      if (kDebugMode) print('Error cancelling stream: $e');
    }
  }

  bool _listened = false;
  bool get hasListener => _listened;
  late final Timer _autoCancelTimer;
  libdio.ResponseBody get baseResponse => _streamedResponse;

  HttpRangeResponse? get responseRange {
    return HttpRangeResponse.parseFromHeader(baseResponse.headers);
  }

  int? get sourceLength {
    if (true ==
        baseResponse.headers[HttpHeaders.contentRangeHeader]?.isNotEmpty) {
      return responseRange?.sourceLength;
    }
    return int.tryParse(
      baseResponse.headers[HttpHeaders.contentLengthHeader]?.firstOrNull ?? "",
    );
  }

  CachedResponseHeaders get cachedResponseHeaders {
    return CachedResponseHeaders.fromBaseResponse(baseResponse.headers);
  }

  int? get statusCode => baseResponse.statusCode;
}
