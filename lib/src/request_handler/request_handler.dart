import 'dart:async';
import 'dart:io';

import '../../http_cache_stream.dart';
import '../request_handler/response_handler.dart';
import '../request_handler/socket_handler.dart';

class RequestHandler {
  final HttpRequest _request;
  ResponseHandler? _responseHandler;
  SocketHandler? _socketHandler;
  RequestHandler(this._request) : _responseHandler = ResponseHandler(_request);

  Future<void> stream(final HttpCacheStream cacheStream) async {
    final responseHandler = _responseHandler;
    if (responseHandler == null) {
      throw StateError('Request already being handled or closed');
    }

    StreamResponse? streamResponse;
    try {
      streamResponse = await responseHandler.getResponse(cacheStream);

      if (responseHandler.isClosed) {
        _responseHandler = null;
        return; //Request closed before we could start streaming
      }

      final socketHandler =
          _socketHandler = SocketHandler(await responseHandler.detachSocket());
      _responseHandler =
          null; //We have detached the socket; we can no longer use the HttpRequest object.
      await socketHandler.writeResponse(
          streamResponse.stream, cacheStream.config.readTimeout);
      _socketHandler = null; //Clear the socket handler after done.
    } catch (e) {
      close(HttpStatus.internalServerError);
    } finally {
      streamResponse
          ?.cancel(); //Ensure we cancel the stream response to free resources.
    }
  }

  void close([int? statusCode]) {
    final responseHandler = _responseHandler;
    if (responseHandler != null) {
      _responseHandler = null;
      responseHandler.close(statusCode);
    }

    final socketHandler = _socketHandler;
    if (socketHandler != null) {
      _socketHandler = null;
      socketHandler.destroy();
    }
  }

  bool get isClosed =>
      _responseHandler?.isClosed ?? _socketHandler?.isClosed ?? true;
  Uri get uri => _request.uri;
}
