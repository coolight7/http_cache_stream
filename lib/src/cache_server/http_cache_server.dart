import 'dart:async';

import 'package:http_cache_stream/src/cache_server/local_cache_server.dart';

import '../../http_cache_stream.dart';

class HttpCacheServer {
  final Uri source;
  final LocalCacheServer _localCacheServer;
  final Duration autoDisposeDelay;
  final HttpCacheStream Function(Uri sourceUrl) _createCacheStream;
  HttpCacheServer(this.source, this._localCacheServer, this.autoDisposeDelay,
      this._createCacheStream) {
    _localCacheServer.start((request) {
      final sourceUrl = getSourceUrl(request.uri);
      final cacheStream = _createCacheStream(sourceUrl);
      request.response.done.catchError((_) {}).whenComplete(() {
        Timer(
            autoDisposeDelay,
            () => cacheStream
                .dispose()
                .ignore()); // Decrease the stream's retainCount for autoDispose
      });
      return cacheStream;
    });
  }

  Uri getCacheUrl(Uri sourceUrl) {
    if (sourceUrl.scheme != source.scheme ||
        sourceUrl.host != source.host ||
        sourceUrl.port != source.port) {
      throw ArgumentError('Invalid source URL: $sourceUrl');
    }
    return _localCacheServer.getCacheUrl(sourceUrl);
  }

  Uri getSourceUrl(Uri cacheUrl) {
    return cacheUrl.replace(
      scheme: source.scheme,
      host: source.host,
      port: source.port,
    );
  }

  /// The URI of the local cache server. Requests to this URI will be redirected to the source URL.
  Uri get uri => _localCacheServer.serverUri;

  Future<void> dispose() {
    if (_completer.isCompleted) {
      return _completer.future;
    }
    _completer.complete();
    return _localCacheServer.close();
  }

  final _completer = Completer<void>();
  bool get isDisposed => _completer.isCompleted;
  Future<void> get future => _completer.future;
}
