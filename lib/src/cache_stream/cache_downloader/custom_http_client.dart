import 'dart:io';

import 'package:http_cache_stream/http_cache_stream.dart';
import 'package:http_cache_stream/src/etc/exceptions.dart';
import 'package:http_cache_stream/src/models/http_range/http_range.dart';
import 'package:http_cache_stream/src/models/http_range/http_range_request.dart';
import 'package:http_cache_stream/src/models/http_range/http_range_response.dart';

class CustomHttpClient {
  final _client = HttpClient();
  final Duration timeout;
  CustomHttpClient({this.timeout = const Duration(seconds: 15)}) {
    _client.connectionTimeout = timeout;
    _client.idleTimeout = const Duration(seconds: 30);
  }

  Future<HttpClientResponse> getUrl(Uri url, IntRange range, Map<String, Object> requestHeaders) async {
    final request = await _client.getUrl(url);
    _formatRequest(request, requestHeaders);
    if (!range.isFull) {
      final rangeRequest = HttpRangeRequest.inclusive(range.start, range.end);
      request.headers.set(HttpHeaders.rangeHeader, rangeRequest.header);
      final response = await request.close();
      final rangeResponse = HttpRangeResponse.parse(response);
      if (rangeResponse == null || !HttpRange.isEqual(rangeRequest, rangeResponse)) {
        throw InvalidRangeRequestException(url, rangeRequest, rangeResponse);
      }
      return response;
    } else {
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw InvalidHttpStatusCode(url, HttpStatus.ok, response.statusCode);
      }
      return response;
    }
  }

  Future<HttpClientResponse> headUrl(Uri url, [Map<String, Object>? requestHeaders]) async {
    final request = await _client.headUrl(url);
    _formatRequest(request, requestHeaders ?? const {});
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      throw InvalidHttpStatusCode(url, HttpStatus.ok, response.statusCode);
    }
    return response;
  }

  void _formatRequest(HttpClientRequest request, Map<String, Object> headers) {
    request.maxRedirects = 20;
    request.followRedirects = true;
    request.headers.removeAll(HttpHeaders.acceptEncodingHeader); //Remove the accept encoding header to prevent compression
    headers.forEach(request.headers.set);
  }

  void close({bool force = true}) {
    if (_closed) return;
    _closed = true;
    return _client.close(force: force);
  }

  bool _closed = false;
  bool get isClosed => _closed;
}
