import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart';
import 'package:http_cache_stream/http_cache_stream.dart';
import 'package:http_cache_stream/src/etc/exceptions.dart';
import 'package:http_cache_stream/src/models/http_range/http_range.dart';
import 'package:http_cache_stream/src/models/http_range/http_range_request.dart';
import 'package:http_cache_stream/src/models/http_range/http_range_response.dart';

class HttpUtil {
  static Future<StreamedResponse> get(Client client, Uri url, IntRange range,
      Map<String, String> requestHeaders) async {
    final request = Request('GET', url);
    _formatRequestHeaders(request, requestHeaders);

    HttpRangeRequest? rangeRequest;
    if (!range.isFull) {
      rangeRequest = range.rangeRequest;
      request.headers[HttpHeaders.rangeHeader] = rangeRequest.header;
    }

    final streamedResponse = await client.send(request);

    if (rangeRequest != null) {
      final rangeResponse = HttpRangeResponse.parse(
        streamedResponse.headers[HttpHeaders.contentRangeHeader],
        streamedResponse.contentLength,
      );
      if (rangeResponse == null ||
          !HttpRange.isEqual(rangeRequest, rangeResponse)) {
        cancelStreamedResponse(streamedResponse);
        throw InvalidRangeRequestException(url, rangeRequest, rangeResponse);
      }
    } else if (streamedResponse.statusCode != HttpStatus.ok) {
      cancelStreamedResponse(streamedResponse);
      throw InvalidHttpStatusCode(
          url, HttpStatus.ok, streamedResponse.statusCode);
    }

    return streamedResponse;
  }

  static Future<Response> headUrl(
    Client client,
    Uri url, {
    Map<String, String>? requestHeaders,
  }) async {
    final request = Request('HEAD', url);
    _formatRequestHeaders(request, requestHeaders ?? const {});

    final streamedResponse = await client.send(request);
    final response = await Response.fromStream(streamedResponse);
    if (response.statusCode != HttpStatus.ok) {
      throw InvalidHttpStatusCode(
          url, HttpStatus.ok, streamedResponse.statusCode);
    }
    return response;
  }

  /// Cancels a streamed response by cancelling its stream.
  /// Calling [stream.drain()] receives all data from the stream before closing it. This method listens to the stream and cancels it immediately.
  static void cancelStreamedResponse(
    StreamedResponse response,
  ) async {
    try {
      final listener =
          response.stream.listen(null, onError: (_) {}, cancelOnError: true);
      await listener.cancel();
    } catch (e) {
      if (kDebugMode) print('Error cancelling stream: $e');
    }
  }

  static void _formatRequestHeaders(
      Request request, Map<String, String> requestHeaders) {
    request.headers[HttpHeaders.acceptEncodingHeader] =
        'identity'; // set to identity
    request.headers.addAll(requestHeaders);
  }
}
