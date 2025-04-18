// ignore_for_file: constant_identifier_names

import 'dart:io';

import 'package:dio/dio.dart' as libdio;
import 'package:dio/io.dart';
import 'package:http_cache_stream/http_cache_stream.dart';
import 'package:http_cache_stream/src/etc/exceptions.dart';
import 'package:http_cache_stream/src/models/http_range/http_range.dart';
import 'package:http_cache_stream/src/models/http_range/http_range_request.dart';
import 'package:http_cache_stream/src/models/http_range/http_range_response.dart';
import 'package:util_xx/Httpxx.dart';

abstract class CustomHttpClient {
  Future<libdio.Response<libdio.ResponseBody>> getUrl(
    Uri url,
    IntRange range,
    HttpHeaderxx requestHeaders,
  );

  Future<libdio.Response<dynamic>> headUrl(
    Uri url, [
    Map<String, Object>? requestHeaders,
  ]);

  Future<Uri?> handleHttpRedirect(
    Uri url, {
    HttpHeaderxx? header,
  });

  void close({bool force = true});

  bool get isClosed;
}

class CustomHttpClientxx extends CustomHttpClient {
  static const extraNAME_writeErrorLog = "writeErrorLog";
  static const headerConfigKey_X_PRE_HEAD = "X-PRE-Head";

  static libdio.BaseOptions? options;
  static String defExtendsUserAgentStr = "Musicxx/77";
  static void Function(Object e)? onLog;
  static final _interceptor = libdio.InterceptorsWrapper(
    onRequest: (options, handler) {
      // 添加默认ua
      if (false == options.headers.containsKey(HttpHeaders.userAgentHeader)) {
        options.headers[HttpHeaders.userAgentHeader] = defExtendsUserAgentStr;
      }
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
            ]);
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

  @override
  bool get isClosed => _closed;

  CustomHttpClientxx() {
    client = libdio.Dio(options);
    client.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: _createHttpClient,
    );
    client.interceptors.add(_interceptor);
  }

  static HttpClient _createHttpClient() {
    final client = HttpClient(
      context: SecurityContext(withTrustedRoots: false),
    );
    client.badCertificateCallback = (
      X509Certificate cert,
      String host,
      int port,
    ) {
      return true;
    };
    return client;
  }

  @override
  Future<libdio.Response<libdio.ResponseBody>> getUrl(
    Uri url,
    IntRange range,
    HttpHeaderxx requestHeaders,
  ) async {
    // 检查重定向
    Uri realUrl = url;
    if (requestHeaders.containsKey(headerConfigKey_X_PRE_HEAD)) {
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
    if (!range.isFull) {
      final rangeRequest = HttpRangeRequest.inclusive(range.start, range.end);
      final useHeader = Httpxx_c.createHeader(data: requestHeaders);
      useHeader[HttpHeaders.rangeHeader] = rangeRequest.header;
      final resp = await client.getUri<libdio.ResponseBody>(
        realUrl,
        options: libdio.Options(
          headers: useHeader,
          responseType: libdio.ResponseType.stream,
        ),
      );
      final rangeResponse = HttpRangeResponse.parse(resp.headers);
      if (rangeResponse == null ||
          !HttpRange.isEqual(rangeRequest, rangeResponse)) {
        throw InvalidRangeRequestException(
          realUrl,
          rangeRequest,
          rangeResponse,
        );
      }
      return resp;
    } else {
      final resp = await client.getUri<libdio.ResponseBody>(
        realUrl,
        options: libdio.Options(
          headers: requestHeaders,
          responseType: libdio.ResponseType.stream,
          followRedirects: true,
          maxRedirects: 5,
        ),
      );
      final code = resp.statusCode;
      if (null != code && code ~/ 100 != 2) {
        throw InvalidHttpStatusCode(url, HttpStatus.ok, code);
      }
      return resp;
    }
  }

  @override
  Future<libdio.Response<dynamic>> headUrl(
    Uri url, [
    Map<String, Object>? requestHeaders,
  ]) async {
    final response = await client.headUri(
      url,
      options: libdio.Options(
        headers: requestHeaders,
      ),
    );
    final code = response.statusCode;
    if (null != code && code ~/ 100 != 2) {
      throw InvalidHttpStatusCode(url, HttpStatus.ok, code);
    }
    return response;
  }

  @override
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
    } catch (e) {
      CustomHttpClientxx.onLog?.call(e);
    }
    return null;
  }

  @override
  void close({bool force = true}) {
    if (_closed) return;
    _closed = true;
    return client.close(force: force);
  }
}
