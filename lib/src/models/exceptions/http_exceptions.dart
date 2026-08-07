import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../http_range/http_range_response.dart';

class DownloadException extends HttpException {
  DownloadException(Uri uri, String message) : super('Download Exception: $message', uri: uri);
}

class DownloadStoppedException extends DownloadException {
  DownloadStoppedException(Uri uri) : super(uri, 'Download stopped');
}

class RequestTimedOutException extends DownloadException implements TimeoutException, http.ClientException {
  @override
  final Duration duration;
  RequestTimedOutException(Uri uri, this.duration) : super(uri, 'Timed out after $duration');

  @override
  String toString() {
    return 'RequestTimedOutException: Request to $uri timed out after $duration';
  }
}

class ReadTimedOutException extends DownloadException implements TimeoutException, http.ClientException {
  @override
  final Duration duration;
  ReadTimedOutException(Uri uri, this.duration) : super(uri, 'Timed out after $duration');

  @override
  String toString() {
    return 'ReadTimedOutException: Reading from $uri timed out after $duration';
  }
}

/// Thrown when a paused download does not resume within the configured timeout.
/// This exception is intentional - it prevents a paused download from hanging indefinitely.
class DownloadPausedException extends DownloadException implements TimeoutException, http.ClientException {
  @override
  final Duration duration;
  DownloadPausedException(Uri uri, this.duration) : super(uri, 'Timed out after $duration');

  @override
  String toString() {
    return 'DownloadPausedException: Paused download from $uri timed out after $duration';
  }
}

class HttpStatusCodeException extends DownloadException {
  HttpStatusCodeException(Uri url, int expected, int result)
      : super(
          url,
          'Invalid HTTP status code | Expected: $expected | Result: $result',
        );

  static void validate(
    final Uri url,
    final int expected,
    final int result,
  ) {
    if (result != expected) {
      throw HttpStatusCodeException(url, expected, result);
    }
  }

  static void validateCompleteResponse(
    final Uri url,
    final http.BaseResponse response,
  ) {
    if (response.statusCode == HttpStatus.ok) {
      return;
    }

    if (response.statusCode == HttpStatus.partialContent) {
      if (HttpRangeResponse.parse(response)?.isFull ?? true) {
        return;
      }
    }

    throw HttpStatusCodeException(url, HttpStatus.ok, response.statusCode);
  }
}
