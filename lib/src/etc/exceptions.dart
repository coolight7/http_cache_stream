import 'dart:io';

import '../models/http_range/http_range_request.dart';
import '../models/http_range/http_range_response.dart';

class InvalidCacheException {
  final Uri uri;
  final String message;
  InvalidCacheException(this.uri, this.message);
  @override
  String toString() => 'InvalidCacheException: $message';
}

class CacheDeletedException extends InvalidCacheException {
  CacheDeletedException(Uri uri) : super(uri, 'Cache deleted');
}

class CacheSourceChangedException extends InvalidCacheException {
  CacheSourceChangedException(Uri uri) : super(uri, 'Cache source changed');
}

class InvalidRangeRequestException extends InvalidCacheException {
  InvalidRangeRequestException(
    Uri uri,
    HttpRangeRequest request,
    HttpRangeResponse? response,
  ) : super(
        uri,
        'Invalid Download Range Response | Request: $request | Response: $response',
      );
}

class InvalidCacheLengthException extends InvalidCacheException {
  InvalidCacheLengthException(Uri uri, int length, int expected)
    : super(
        uri,
        'Invalid cache length | Length: $length, expected $expected (Diff: ${expected - length})',
      );
}

class CacheStreamDisposedException extends StateError {
  final Uri uri;
  CacheStreamDisposedException(this.uri)
    : super('HttpCacheStream disposed | $uri');
}

class InvalidHttpStatusCode extends HttpException {
  InvalidHttpStatusCode(Uri uri, int expected, int result)
    : super(
        'Invalid HTTP status code | Expected: $expected | Result: $result',
        uri: uri,
      );
}
