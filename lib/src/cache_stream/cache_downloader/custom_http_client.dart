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
    HttpHeaderAnyxx requestHeaders,
  );

  Future<libdio.Response<dynamic>> headUrl(
    Uri url, [
    Map<String, Object>? requestHeaders,
  ]);

  void close({bool force = true});

  bool get isClosed;
}

class CustomHttpClientxx extends CustomHttpClient {
  static libdio.BaseOptions? options;

  late final libdio.Dio client;
  bool _closed = false;

  @override
  bool get isClosed => _closed;

  CustomHttpClientxx() {
    client = libdio.Dio(options);
    client.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
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
      },
    );
  }

  @override
  Future<libdio.Response<libdio.ResponseBody>> getUrl(
    Uri url,
    IntRange range,
    HttpHeaderAnyxx requestHeaders,
  ) async {
    if (!range.isFull) {
      final rangeRequest = HttpRangeRequest.inclusive(range.start, range.end);
      final useHeader = Httpxx_c.createHeader(data: requestHeaders);
      useHeader[HttpHeaders.rangeHeader] = rangeRequest.header;
      final resp = await client.getUri<libdio.ResponseBody>(
        url,
        options: libdio.Options(
          headers: useHeader,
          responseType: libdio.ResponseType.stream,
        ),
      );
      final rangeResponse = HttpRangeResponse.parse(resp.headers);
      if (rangeResponse == null ||
          !HttpRange.isEqual(rangeRequest, rangeResponse)) {
        throw InvalidRangeRequestException(url, rangeRequest, rangeResponse);
      }
      return resp;
    } else {
      final resp = await client.getUri<libdio.ResponseBody>(
        url,
        options: libdio.Options(
          headers: requestHeaders,
          responseType: libdio.ResponseType.stream,
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
  void close({bool force = true}) {
    if (_closed) return;
    _closed = true;
    return client.close(force: force);
  }
}
