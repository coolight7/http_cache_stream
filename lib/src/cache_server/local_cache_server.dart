import 'dart:io';

import 'package:http_cache_stream/http_cache_stream.dart';

import 'package:http_cache_stream/http_cache_stream.dart';

import '../etc/keep_alive_server.dart';
import '../request_handler/request_handler.dart';

class LocalCacheServer {
  final KeepAliveServer _httpServer;
  final Uri serverUri;
  LocalCacheServer._(this._httpServer)
      : serverUri = Uri(
          scheme: 'http',
          host: _httpServer.address.host,
          port: _httpServer.port,
        );

  static Future<LocalCacheServer> init() async {
    final httpServer =
        await KeepAliveServer.bind(InternetAddress.loopbackIPv4, 0);
    return LocalCacheServer._(httpServer);
  }

  void start(
      final Future<void> Function(RequestHandler handler) processRequest) {
    _httpServer.listen(
      (request) async {
        final requestHandler = RequestHandler(request);
        try {
          await processRequest(requestHandler);
        } catch (e, stack) {
          requestHandler.closeWithError(e, stack);
        } finally {
          assert(requestHandler.isClosed,
              'RequestHandler should be closed after processing the request');
        }
      },
      onError: (e, stack) {
        CustomHttpClientxx.onLog?.call('server onError: $e', stack);
      },
      cancelOnError: false,
    );
  }

  Future<void> ensureActive() => _httpServer.ensureActive();

  Uri getCacheUrl(Uri sourceUrl) {
    return sourceUrl.replace(
        scheme: serverUri.scheme, host: serverUri.host, port: serverUri.port);
  }

  Future<void> close({bool force = true}) {
    return _httpServer.close(force: force);
  }
}
