import 'dart:io';

import 'package:http_cache_stream/http_cache_stream.dart';

import '../request_handler/request_handler.dart';

class LocalCacheServer {
  final HttpServer _httpServer;
  final Uri serverUri;
  LocalCacheServer._(this._httpServer)
      : serverUri = Uri(
          scheme: 'http',
          host: _httpServer.address.host,
          port: _httpServer.port,
        );

  static Future<LocalCacheServer> init() async {
    final httpServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return LocalCacheServer._(httpServer);
  }

  void start(
      final Future<void> Function(RequestHandler handler) processRequest) {
    _httpServer.listen(
      (request) async {
        final requestHandler = RequestHandler(request);
        try {
          if (request.method != 'GET') {
            requestHandler.close(HttpStatus.methodNotAllowed);
          } else {
            await processRequest(requestHandler);
          }
        } catch (e) {
          requestHandler.close(HttpStatus.internalServerError, e);
        } finally {
          assert(requestHandler.isClosed,
              'RequestHandler should be closed after processing the request');
        }
      },
      onError: (e) {
        CustomHttpClientxx.onLog?.call('server onError: $e');
      },
      cancelOnError: false,
    );
  }

  Uri getCacheUrl(Uri sourceUrl) {
    return sourceUrl.replace(
        scheme: serverUri.scheme, host: serverUri.host, port: serverUri.port);
  }

  Future<void> close() {
    return _httpServer.close(force: true);
  }
}
