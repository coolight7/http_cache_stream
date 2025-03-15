import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http_cache_stream/http_cache_stream.dart';
import 'package:http_cache_stream/src/cache_manager/http_request_handler.dart';

class HttpCacheServer {
  final HttpServer _httpServer;
  HttpCacheServer(this._httpServer);

  static Future<HttpCacheServer> init() async {
    final httpServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return HttpCacheServer(httpServer);
  }

  void start(final HttpCacheStream? Function(Uri uri) getCacheStream) {
    _httpServer.listen(
      (request) {
        final httpCacheStream = request.method == 'GET' ? getCacheStream(request.uri) : null;
        if (httpCacheStream != null) {
          final requestHandler = RequestHandler(request);
          requestHandler.stream(httpCacheStream);
        } else {
          request.response.statusCode = HttpStatus.clientClosedRequest;
          request.response.close().ignore();
        }
      },
      onError: (Object e, StackTrace st) {
        if (kDebugMode) print('HttpCacheStream Proxy server onError: $e');
      },
      cancelOnError: false,
    );
  }

  Uri getCacheUrl(Uri sourceUrl) {
    return sourceUrl.replace(
      scheme: 'http',
      host: InternetAddress.loopbackIPv4.address,
      port: _httpServer.port,
    );
  }

  Future<void> close() {
    return _httpServer.close(force: true);
  }

  int get port => _httpServer.port;
}
