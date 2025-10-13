import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http_cache_stream/http_cache_stream.dart';
import 'package:http_cache_stream/src/cache_stream/response_streams/download_stream.dart';
import 'package:http_cache_stream/src/etc/exceptions.dart';

class Downloader {
  final Uri sourceUrl;
  final IntRange downloadRange;
  final StreamCacheConfig streamConfig;
  final Duration timeout;

  Downloader(
    this.sourceUrl,
    this.downloadRange,
    this.streamConfig, {
    this.timeout = const Duration(seconds: 15),
  });

  Future<void> download({
    ///If [onError] is provided, handles IO errors (e.g. connection errors) and calls [onError] with the error. Otherwise, closes the stream with the error.
    required final void Function(Object e) onError,
    required final void Function(CachedResponseHeaders responseHeaders)
        onHeaders,
    required final void Function(List<int> data) onData,
  }) async {
    try {
      while (isActive) {
        DownloadStream? downloadStream;
        try {
          downloadStream = await DownloadStream.open(
            sourceUrl,
            IntRange(position, downloadRange.end),
            streamConfig.httpClient,
            streamConfig.combinedRequestHeaders(),
          );
          if (!isActive) {
            //Downloader was closed while waiting for the stream
            throw DownloadStoppedException(
              sourceUrl,
            );
          }
          onHeaders(downloadStream.cachedResponseHeaders);
          await _listenResponse(downloadStream, onData);
        } catch (e) {
          downloadStream?.cancel();
          if (!isActive) {
            break;
          } else if (e is! InvalidCacheException) {
            onError(e);
            await Future.delayed(Duration(seconds: 5)); //Wait before retrying
          } else {
            rethrow;
          }
        }
      }
    } finally {
      close();
    }
  }

  Future<void> _listenResponse(
    final Stream<List<int>> response,
    final void Function(List<int> data) onData,
  ) {
    final subscriptionCompleter = _subscriptionCompleter = Completer<void>();
    final buffer = BytesBuilder(copy: false);
    final minChunkSize = streamConfig.minChunkSize;

    void emitBuffer() {
      if (buffer.isEmpty) return;
      _receivedBytes += buffer.length;
      onData(buffer.takeBytes());
    }

    void completeError(DownloadException error) {
      if (subscriptionCompleter.isCompleted) return;
      subscriptionCompleter.completeError(error);
    }

    final subscription = response.listen(
      (data) {
        buffer.add(data);
        if (buffer.length > minChunkSize) {
          emitBuffer();
        }
      },
      onDone: () {
        emitBuffer();
        _done = true;
        if (!subscriptionCompleter.isCompleted) {
          subscriptionCompleter.complete();
        }
      },
      onError: (e) {
        emitBuffer();
        completeError(DownloadException(sourceUrl, e.toString()));
      },
      cancelOnError: true,
    );
    _currentSubscription = subscription;
    if (_pauseCount > 0 && !subscription.isPaused) {
      subscription.pause(); //Pause the subscription if the downloader is paused
    }

    int lastReceivedBytes = receivedBytes;
    final timeoutTimer = Timer.periodic(timeout, (t) {
      if (lastReceivedBytes != receivedBytes) {
        lastReceivedBytes = receivedBytes;
      } else if (!subscription.isPaused && buffer.isEmpty) {
        t.cancel();
        completeError(DownloadTimedOutException(sourceUrl, timeout));
      }
    });

    return subscriptionCompleter.future.whenComplete(() {
      _currentSubscription = null;
      _subscriptionCompleter = null;
      timeoutTimer.cancel();
      subscription.cancel();
      emitBuffer();
    });
  }

  void close([Object? error]) {
    _closed = true;
    final subscriptionCompleter = _subscriptionCompleter;
    if (subscriptionCompleter != null && !subscriptionCompleter.isCompleted) {
      subscriptionCompleter
          .completeError(error ?? DownloadStoppedException(sourceUrl));
    }
  }

  void pause() {
    _pauseCount = _pauseCount <= 0 ? 1 : _pauseCount + 1;
    _currentSubscription?.pause();
  }

  void resume() {
    _pauseCount--;
    _currentSubscription?.resume();
  }

  StreamSubscription<List<int>>? _currentSubscription;
  int _receivedBytes = 0;
  bool _done = false;
  Completer<void>? _subscriptionCompleter;
  int _pauseCount = 0;
  bool _closed = false;

  ///The number of bytes received from the current stream. This is not always the same as the position.
  int get receivedBytes => _receivedBytes;

  ///If the stream closed with a done event
  bool get isDone => _done;

  ///If the stream is currently active. This is true if the downloader is not closed and not done.
  bool get isActive => !isClosed && !isDone;

  ///The current position of the stream, this is the sum of the start position and the received bytes.
  int get position => downloadRange.start + _receivedBytes;

  ///If the downloader has been closed. The downloader cannot be used after it is closed.
  bool get isClosed => _closed;

  ///If the stream is paused
  bool get isPaused {
    return _currentSubscription?.isPaused ?? _pauseCount > 0;
  }
}

class DownloadException extends HttpException {
  DownloadException(Uri uri, String message)
      : super('Download Exception: $message', uri: uri);
}

class DownloadStoppedException extends DownloadException {
  DownloadStoppedException(Uri uri) : super(uri, 'Download stopped');
}

class DownloadTimedOutException extends DownloadException {
  DownloadTimedOutException(Uri uri, Duration duration)
      : super(uri, 'Timed out after $duration');
}
