import 'dart:async';

import 'package:http_cache_stream/src/etc/extensions/file_extensions.dart';

import '../../etc/extensions/future_extensions.dart';
import '../../models/cache_config/stream_cache_config.dart';
import '../../models/cache_files/cache_files.dart';
import '../../models/exceptions/invalid_cache_exceptions.dart';
import '../../models/metadata/cache_metadata.dart';
import '../../models/metadata/cached_response_headers.dart';
import '../../models/stream_requests/int_range.dart';
import '../../models/stream_requests/stream_request.dart';
import '../../models/stream_response/stream_response.dart';
import 'buffered_io_sink.dart';
import 'downloader.dart';

class CacheDownloader {
  final CacheFiles _cacheFiles;
  final Downloader _downloader;
  final BufferedIOSink _sink;
  final _completer = Completer<void>();
  int _position;
  CachedResponseHeaders? _cachedHeaders;
  bool _paused = false;
  CacheDownloader._(
    final CacheMetadata cacheMetadata,
    final int startPosition,
    this._downloader,
  )   : _cacheFiles = cacheMetadata.cacheFiles,
        _position = startPosition,
        _sink = BufferedIOSink(cacheMetadata.partialCacheFile, startPosition),
        _cachedHeaders = startPosition > 0 ? cacheMetadata.headers : null;

  factory CacheDownloader.construct(
    final CacheMetadata cacheMetadata,
    final StreamCacheConfig cacheConfig,
  ) {
    final partialCacheFile = cacheMetadata.partialCacheFile;
    int startPosition = 0;

    if (cacheMetadata.headers?.canResumeDownload() ?? false) {
      startPosition = partialCacheFile.lengthSyncOrNull() ?? 0;
    }

    return CacheDownloader._(
      cacheMetadata,
      startPosition,
      Downloader(cacheMetadata.sourceUrl, cacheConfig),
    );
  }

  Future<void> download({
    required final void Function(Object e) onError,
    required final void Function(CachedResponseHeaders headers) onHeaders,
    required final void Function(int position) onPosition,
    required final Future<void> Function(int sourceLength) onComplete,
  }) async {
    final int maxBufferSize = _downloader.streamConfig.maxBufferSize;

    try {
      try {
        await _downloader.download(
          downloadRange: () => IntRange(downloadPosition),
          onError: (error) {
            onError(error);
          },
          onHeaders: (cacheHttpHeaders) {
            final prevHeaders = _cachedHeaders;
            if (prevHeaders != null && downloadPosition > 0 && !CachedResponseHeaders.validateCacheResponse(prevHeaders, cacheHttpHeaders)) {
              throw CacheSourceChangedException(sourceUrl);
            }

            _cachedHeaders = cacheHttpHeaders;
            onHeaders(cacheHttpHeaders);
            onPosition(downloadPosition); //Emit current position to update progress and process queued requests
          },
          onData: (data) {
            _position += data.length;
            _sink.add(data);
            onPosition(downloadPosition); //Emit current position to update progress and synchronously process queued requests

            if (_sink.bufferSize > maxBufferSize) {
              _downloader.pause(); //Pause upstream if we are receiving more data than we can write
              _sink.flush().then(
                (_) {
                  _downloader.resume();
                },
                onError: (e) {
                  cancel(e);
                },
              );
            } else if (!_sink.isFlushing) {
              _sink.flush().catchError((e) {
                cancel(e);
              });
            }
          },
        );
      } on InvalidCacheException {
        rethrow;
      } catch (e) {
        onError(e);
      }

      // Post-download — flush remaining data and verify cache integrity
      try {
        await _sink.close(
          flushBuffer: true,
          isDone: _downloader.isDone, //If the source did not end, the feed is marked as aborted so readers do not treat it as an end of stream
        ); //Flushes all buffered data and closes the sink
      } catch (e) {
        onError(e);
      }

      final sourceLength = _cachedHeaders?.sourceLength ?? (_downloader.isDone ? downloadPosition : null);
      if (sourceLength != null && downloadPosition == sourceLength) {
        await onComplete(sourceLength);
      }
    } finally {
      if (!_sink.isClosed) {
        ///The sink is not closed on invalid cache exception, so we need to close it here
        await _sink.close(flushBuffer: false).ignoreResult();
      }
      if (!_completer.isCompleted) {
        _completer.complete();
      }
    }
  }

  /// Cancels the download and closes the stream. An optional [error] can be provided to indicate the reason for cancellation.
  Future<void> cancel([Object? exception]) async {
    _downloader.close(exception);
    _paused = false;
    return _completer.future;
  }

  void pause() {
    if (_paused || !_downloader.isActive) return;
    _paused = true;
    _downloader.pause();
  }

  void resume() {
    if (!_paused) return;
    _paused = false;
    _downloader.resume();
  }

  bool processRequest(final StreamRequest request) {
    assert(!_paused);
    if (request.start > downloadPosition) return false;
    final headers = _cachedHeaders;
    if (headers == null) return false;

    if (_downloader.isClosed && !_downloader.isDone) {
      final effectiveEnd = request.end ?? headers.sourceLength;
      if (effectiveEnd == null || effectiveEnd > downloadPosition) {
        return false; //Downloader closed and request exceeds downloaded range, cannot fulfill request
      }
    }

    request.complete(
      () => StreamResponse.fromPartialFile(
        request.range,
        _cacheFiles,
        headers,
        _sink.feed,
      ),
    );

    return true;
  }

  int? get sourceLength => _cachedHeaders?.sourceLength;
  int get downloadPosition => _position;
  int get filePosition => _sink.flushedBytes;
  Uri get sourceUrl => _downloader.sourceUrl;
  bool get isClosed => _completer.isCompleted;
  bool get isPaused => _paused;
}
