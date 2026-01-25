// ignore_for_file: constant_identifier_names

import 'dart:io';

import 'package:dio/dio.dart' as libdio;
import 'package:dio/io.dart';
import 'package:http_cache_stream/http_cache_stream.dart';
import 'package:http_cache_stream/src/models/exceptions/http_exceptions.dart';
import 'package:http_cache_stream/src/models/exceptions/invalid_cache_exceptions.dart';
import 'package:http_cache_stream/src/models/http_range/http_range.dart';
import 'package:http_cache_stream/src/models/http_range/http_range_request.dart';
import 'package:http_cache_stream/src/models/http_range/http_range_response.dart';
import 'package:util_xx/Httpxx.dart';

class CustomHttpClientxx {
  static const extraNAME_writeErrorLog = 'writeErrorLog';
  static const headerConfigKey_X_PRE_HEAD = 'X-PRE-Head';

  static libdio.BaseOptions? options;
  static String defExtendsUserAgentStr = 'Musicxx/77';
  static void Function(Object e, Object? stack)? onLog;
  static final _interceptor = libdio.InterceptorsWrapper(
    onRequest: (options, handler) {
      // 添加默认ua
      options.headers[HttpHeaders.userAgentHeader] ??= defExtendsUserAgentStr;
      options.headers['skip_zrok_interstitial'] ??= '1';
      return handler.next(options); //continue
    },
    onError: (e, handler) {
      if (false != e.requestOptions.extra[extraNAME_writeErrorLog]) {
        // 如果没有禁用写入日志
        switch (e.type) {
          case libdio.DioExceptionType.cancel:
            break;
          default:
            CustomHttpClientxx.onLog?.call([
              e.toString(),
              e.requestOptions.headers.toString(),
              e.requestOptions.path,
            ], e.stackTrace);
        }
      }
      final resp = e.response;
      if (null == resp) {
        handler.next(e);
      } else {
        handler.resolve(resp); //continue
      }
    },
  );

  late final libdio.Dio client;
  bool _closed = false;

  bool get isClosed => _closed;

  CustomHttpClientxx() {
    client = libdio.Dio(options);
    client.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: _createHttpClient,
    );
    client.interceptors.add(_interceptor);
  }

  static HttpClient _createHttpClient() {
    final context = SecurityContext(withTrustedRoots: false)
      ..allowLegacyUnsafeRenegotiation = true;
    return HttpClient(context: context)
      ..badCertificateCallback = (X509Certificate cert, String host, int port) {
        return true;
      }
      ..idleTimeout = const Duration(minutes: 5)
      ..connectionTimeout = const Duration(seconds: 8);
  }

  Future<libdio.Response<libdio.ResponseBody>> getUrl(
    Uri url,
    IntRange range,
    HttpHeaderxx requestHeaders, {
    libdio.CancelToken? cancelToken,
  }) async {
    // 检查重定向
    Uri realUrl = url;
    requestHeaders = Httpxx_c.createHeader(data: requestHeaders);
    requestHeaders[HttpHeaders.acceptEncodingHeader] = 'identity';
    if (requestHeaders.containsKey(headerConfigKey_X_PRE_HEAD)) {
      // dio 自动重定向时，部分请求头不会转发过去
      // 预先处理重定向
      requestHeaders.remove(headerConfigKey_X_PRE_HEAD);
      realUrl = (await handleHttpRedirect(
            url,
            header: requestHeaders,
          )) ??
          url;
      if (realUrl != url) {
        requestHeaders[HttpHeaders.refererHeader] = url.toString();
      }
    }
    if (true == cancelToken?.isCancelled) {
      throw DownloadStoppedException(url);
    }

    if (!range.isFull) {
      final rangeRequest = HttpRangeRequest.inclusive(range.start, range.end);
      final useHeader = Httpxx_c.createHeader(data: requestHeaders);
      useHeader[HttpHeaders.rangeHeader] = rangeRequest.header;
      final resp = await client.getUri<libdio.ResponseBody>(
        realUrl,
        cancelToken: cancelToken,
        options: libdio.Options(
          headers: useHeader,
          responseType: libdio.ResponseType.stream,
          followRedirects: true,
          maxRedirects: 5,
          receiveDataWhenStatusError: true,
        ),
      );
      final rangeResponse = HttpRangeResponse.parseFromHeader(resp.headers.map);
      if (rangeResponse == null ||
          !HttpRange.isEqual(rangeRequest, rangeResponse)) {
        throw HttpRangeException(
          realUrl,
          rangeRequest,
          rangeResponse,
        );
      }
      return resp;
    } else {
      final resp = await client.getUri<libdio.ResponseBody>(
        realUrl,
        cancelToken: cancelToken,
        options: libdio.Options(
          headers: requestHeaders,
          responseType: libdio.ResponseType.stream,
          followRedirects: true,
          maxRedirects: 5,
          receiveDataWhenStatusError: true,
        ),
      );
      final code = resp.statusCode;
      if (false == Httpxx_c.statusCodeIsSuccess(code)) {
        throw HttpStatusCodeException(url, HttpStatus.ok, code ?? -1);
      }
      return resp;
    }
  }

  Future<libdio.Response<dynamic>> headUrl(
    Uri url, [
    Map<String, String>? requestHeaders,
  ]) async {
    requestHeaders ??= Httpxx_c.createHeader();
    requestHeaders[HttpHeaders.acceptEncodingHeader] = 'identity';
    final response = await client.headUri(
      url,
      options: libdio.Options(
        headers: requestHeaders,
      ),
    );
    final code = response.statusCode;
    if (false == Httpxx_c.statusCodeIsSuccess(code)) {
      throw HttpStatusCodeException(url, HttpStatus.ok, code ?? -1);
    }
    return response;
  }

  Future<Uri?> handleHttpRedirect(
    Uri url, {
    HttpHeaderAnyxx? header,
  }) async {
    try {
      final resp = await client.headUri(
        url,
        options: libdio.Options(
          followRedirects: true,
          headers: header,
          receiveDataWhenStatusError: true,
          extra: {
            extraNAME_writeErrorLog: false,
          },
        ),
      );
      if (null != resp.statusCode) {
        return resp.realUri;
      }
    } catch (e, stack) {
      CustomHttpClientxx.onLog?.call(e, stack);
    }
    return null;
  }

  void close({bool force = true}) {
    if (_closed) {
      return;
    }
    _closed = true;
    return client.close(force: force);
  }
}
