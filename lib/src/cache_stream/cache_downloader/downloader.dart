import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart';
import 'package:http_cache_stream/http_cache_stream.dart';
import 'package:http_cache_stream/src/etc/exceptions.dart';
import 'package:http_cache_stream/src/etc/http_util.dart';

class Downloader {
  final Uri sourceUrl;
  final IntRange downloadRange;
  final StreamCacheConfig cacheConfig;
  final Duration timeout;
  Downloader(
    this.sourceUrl,
    this.downloadRange,
    this.cacheConfig, {
    this.timeout = const Duration(seconds: 15),
  });

  Future<void> download({
    ///If [onError] is provided, handles IO errors (e.g. connection errors) and calls [onError] with the error. Otherwise, closes the stream with the error.
    final void Function(Object e)? onError,
    final void Function(CachedResponseHeaders responseHeaders)? onHeaders,
    final void Function()? onDone,
    required final void Function(List<int> data) onData,
  }) async {
    StreamedResponse?
        unListenedResponse; //In case the stream is cancelled before it is listened to
    try {
      while (isActive) {
        try {
          final response = unListenedResponse = await HttpUtil.get(
            cacheConfig.httpClient,
            sourceUrl,
            IntRange(position, downloadRange.end),
            cacheConfig.combinedRequestHeaders(),
          );
          if (!isActive) {
            break; //Async gap, check if cancelled
          }
          if (onHeaders != null) {
            final cachedResponseHeaders =
                CachedResponseHeaders.fromResponse(response);
            onHeaders(cachedResponseHeaders);
          }
          unListenedResponse = null; //Set to null upon listening
          await _listenResponse(response.stream, onData, onDone);
        } catch (e) {
          if (!isActive) {
            break;
          } else if (onError != null && e is! InvalidCacheException) {
            onError(e);
            await Future.delayed(Duration(seconds: 5)); //Wait before retrying
          } else {
            rethrow;
          }
        }
      }
    } finally {
      if (unListenedResponse != null) {
        HttpUtil.cancelStreamedResponse(unListenedResponse);
        unListenedResponse = null;
      }
      close();
    }
  }

  Future<void> _listenResponse(
    final Stream<List<int>> response,
    final void Function(List<int> data) onData,
    final void Function()? onDone,
  ) {
    final subscriptionCompleter = _subscriptionCompleter = Completer<void>();
    final buffer = BytesBuilder(copy: false);
    final minChunkSize = cacheConfig.minChunkSize;

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
        onDone?.call();
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

  void close() {
    final subscriptionCompleter = _subscriptionCompleter;
    if (subscriptionCompleter != null && !subscriptionCompleter.isCompleted) {
      subscriptionCompleter.completeError(DownloadStoppedException(sourceUrl));
    }
    _closed = true;
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

  ///If the stream is paused, null if the downloader is closed.
  bool? get isPaused {
    if (isClosed) return null;
    return _currentSubscription?.isPaused ?? _pauseCount > 0;
  }

  bool get isReceivingData {
    return _currentSubscription?.isPaused == false &&
        _subscriptionCompleter?.isCompleted == false &&
        receivedBytes > 0;
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
