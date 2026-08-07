import 'dart:async';
import 'dart:io';
import 'dart:math';

import '../../models/cache_files/cache_files.dart';
import '../../models/exceptions/partial_cache_feed_exceptions.dart';
import '../../models/stream_response/stream_response_range.dart';
import '../cache_downloader/buffered_io_sink.dart';

/// Streams committed bytes from a partial cache file while it is being saved.
///
/// Every listener owns its file handle and read position. When it catches up to
/// the committed position exposed by [feed], it waits for more data while
/// retaining the same file handle.
///
/// No timeout is applied while waiting for the feed to advance; the listener is
/// responsible for bounding how long it is willing to wait.
class PartialCacheFileStream extends Stream<List<int>> {
  final StreamRange range;
  final CacheFiles cacheFiles;
  final PartialCacheFeed feed;
  const PartialCacheFileStream(this.range, this.cacheFiles, this.feed);

  @override
  StreamSubscription<List<int>> listen(
    final void Function(List<int> event)? onData, {
    final Function? onError,
    final void Function()? onDone,
    final bool? cancelOnError,
  }) {
    return _PartialCacheFileReader(range, cacheFiles, feed).stream.listen(
          onData,
          onError: onError,
          onDone: onDone,
          cancelOnError: cancelOnError,
        );
  }
}

/// Reads one range of a partial cache file into a single-subscription stream.
///
/// The read loop only makes progress while the listener is active and not
/// paused. Every suspension point — opening the file, waiting on the feed,
/// reading — is followed by a check of the controller state, so a cancelled
/// listener releases the file handle promptly and a paused one applies real
/// backpressure instead of buffering.
class _PartialCacheFileReader {
  static const int _readSize = 64 * 1024;

  final StreamRange _range;
  final CacheFiles _cacheFiles;
  final PartialCacheFeed _feed;
  final _controller = StreamController<List<int>>(sync: true);

  ///Completed when the listener resumes or cancels. Created only while the read loop is waiting on a paused listener.
  Completer<void>? _resumeCompleter;

  ///The feed position currently being awaited, if any. Retained so it can be cancelled when the listener cancels.
  PositionWaiter? _positionWaiter;

  _PartialCacheFileReader(this._range, this._cacheFiles, this._feed) {
    ///Start reading in a microtask; a sync controller must not emit from within [onListen].
    _controller.onListen = () => scheduleMicrotask(_read);
    _controller.onResume = _signalResume;
    _controller.onCancel = () {
      _signalResume(); //Release the read loop if it is waiting on a pause
      _positionWaiter?.cancel(); //Release the read loop if it is waiting on the feed
    };
  }

  Stream<List<int>> get stream => _controller.stream;

  ///If the listener is gone, either because it cancelled or because the stream was closed.
  bool get _isDone => _controller.isClosed || !_controller.hasListener;

  Future<void> _read() async {
    final int? requestedEnd = _range.absoluteEnd;
    int readPosition = _range.start;
    RandomAccessFile? raf;

    try {
      if (_isDone) return; //Cancelled before the read loop was scheduled
      if (requestedEnd != null && readPosition >= requestedEnd) return;

      ///Wait for the first requested byte before opening; the cache file may not exist yet.
      while (readPosition >= _feed.position) {
        if (requestedEnd == null && _feed.isClosed) return _endOfContent();
        await _awaitPosition(readPosition + 1); //Wait for more bytes to be committed
        if (_isDone) return;
      }

      raf = await _openActiveCacheFile();
      if (_isDone) return;

      if (readPosition > 0) {
        await raf.setPosition(readPosition);
      }

      while (!_isDone && (requestedEnd == null || readPosition < requestedEnd)) {
        if (_controller.isPaused) {
          await _resumeFuture;
          continue;
        }

        final int committedEnd = min(_feed.position, requestedEnd ?? _feed.position);
        final int availableBytes = committedEnd - readPosition;

        if (availableBytes <= 0) {
          if (_feed.isClosed && requestedEnd == null) return _endOfContent();
          await _awaitPosition(readPosition + 1); //Wait for more bytes to be committed
          continue;
        }

        final List<int> bytes = await raf.read(min(_readSize, availableBytes));
        if (_isDone) return;
        if (bytes.isEmpty) {
          throw FileSystemException(
            'Partial cache file ended before its committed position',
            raf.path,
          );
        }

        readPosition += bytes.length;
        _controller.add(bytes);
      }
    } on PositionWaiterCancelledException {
//Canceled while waiting for the feed to advance; the listener is gone, so exit the read loop.
    } on PartialCacheFeedClosedException catch (e, stackTrace) {
      if (requestedEnd != null && !_isDone) {
        _controller.addError(e, stackTrace);
      }
    } catch (e, stackTrace) {
      if (!_isDone) {
        _controller.addError(e, stackTrace);
      }
    } finally {
      try {
        await raf?.close();
      } catch (_) {
        //Intentionally ignored
      }
      _controller.close().ignore();
    }
  }

  ///Ends a read with no known end position, now that the feed is closed.
  ///
  ///A closed feed is the only end-of-content signal available when the content
  ///length is unknown, so an aborted download has to be reported as an error.
  ///Returning normally would hand the listener a truncated body it would accept
  ///as complete.
  void _endOfContent() {
    if (_feed.failure case final Object failure) {
      throw failure;
    }
  }

  Future<void> get _resumeFuture {
    if (_controller.isPaused && !_isDone) {
      return (_resumeCompleter ??= Completer<void>()).future;
    }
    return Future.value();
  }

  void _signalResume() {
    final completer = _resumeCompleter;
    if (completer == null) return;
    _resumeCompleter = null;
    if (!completer.isCompleted) completer.complete();
  }

  Future<void> _awaitPosition(final int minPosition) {
    assert(_positionWaiter?.isCompleted != false, 'A previous position waiter is still pending; only one can be awaited at a time.');
    assert(!_isDone, 'Registering a position waiter after the listener is gone; it will never be cancelled.');

    return (_positionWaiter = _feed.waitForPosition(minPosition)).future;
  }

  Future<RandomAccessFile> _openActiveCacheFile() async {
    assert(!_isDone, 'The listener is gone; the read loop should not be running.');
    try {
      return await _cacheFiles.activeCacheFile().open(mode: FileMode.read);
    } on FileSystemException {
      // The partial file may have been renamed after activeCacheFile() selected
      // it. Resolve the active path again and retry once.
      return _cacheFiles.activeCacheFile().open(mode: FileMode.read);
    }
  }
}
