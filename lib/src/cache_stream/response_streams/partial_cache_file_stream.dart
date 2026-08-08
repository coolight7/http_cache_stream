import 'dart:async';
import 'dart:io';
import 'dart:math';

import '../../models/cache_files/cache_files.dart';
import '../../models/exceptions/partial_cache_feed_exceptions.dart';
import '../../models/stream_response/stream_response_range.dart';
import 'partial_cache_feed.dart';

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
/// Reads are pipelined like dart:io's File.openRead(): after one asynchronous
/// file read completes, the next eligible read is started before the current
/// block is synchronously emitted. This allows file I/O for the next block to
/// overlap downstream processing of the current block.
///
/// The reader never starts a read beyond [PartialCacheFeed.position]. A paused
/// listener stops further read-ahead after at most the single read that was
/// already in flight, matching File.openRead()'s bounded read-ahead behavior.
class _PartialCacheFileReader {
  static const int _maxReadSize = 256 * 1024;
  final CacheFiles _cacheFiles;
  final PartialCacheFeed _feed;
  final _controller = StreamController<List<int>>(sync: true);
  final int? _requestedEnd;

  int _readPosition;
  RandomAccessFile? _raf;
  PositionWaiter? _positionWaiter;
  bool _readInProgress = false;
  bool _closing = false;
  final _closeCompleter = Completer<void>();

  _PartialCacheFileReader(
    final StreamRange range,
    this._cacheFiles,
    this._feed,
  )   : _requestedEnd = range.absoluteEnd,
        _readPosition = range.start {
    _controller.onListen = _start;
    _controller.onResume = _pump;
    _controller.onCancel = _finish;
  }

  Stream<List<int>> get stream => _controller.stream;

  /// If the listener is gone, either because it cancelled or because the
  /// stream was closed.
  bool get _isDone => _controller.isClosed || !_controller.hasListener;

  bool get _atRequestedEnd =>
      _requestedEnd != null && _readPosition >= _requestedEnd;

  /// Performs the one-time setup. The hot read path is callback-driven rather
  /// than an async/await loop so each block can schedule the next read before
  /// the current block is emitted.
  Future<void> _start() async {
    RandomAccessFile? openedRaf;

    try {
      if (_isDone || _closing || _atRequestedEnd) {
        await _finish();
        return;
      }

      // Wait for the first requested byte before opening; the cache file may
      // not exist yet.
      while (_readPosition >= _feed.position) {
        if (_requestedEnd == null && _feed.isClosed) {
          _finishAtEndOfContent();
          return;
        }

        await _awaitPosition(_readPosition + 1);
        if (_isDone || _closing) {
          await _finish();
          return;
        }
      }

      openedRaf = await _openActiveCacheFile();
      if (_isDone || _closing) {
        return;
      }

      if (_readPosition > 0) {
        await openedRaf.setPosition(_readPosition);
        if (_isDone || _closing) {
          return;
        }
      }

      _raf = openedRaf;
      openedRaf = null;
      _pump();
    } on PositionWaiterCancelledException {
      // Cancelled while waiting for the feed; the listener is gone.
      await _finish();
    } catch (e, stackTrace) {
      _handleError(e, stackTrace);
    } finally {
      if (openedRaf != null) {
        try {
          await openedRaf.close();
        } catch (_) {
          // Intentionally ignored.
        }
      }
    }
  }

  /// Starts the next piece of work when possible.
  void _pump() {
    if (_closing || _controller.isPaused) return;
    if (_readInProgress || _positionWaiter != null) return;

    if (_atRequestedEnd) {
      _finish().ignore();
      return;
    }

    final raf = _raf;
    if (raf == null) return;

    final feedPosition = _feed.position;
    final committedEnd = min(feedPosition, _requestedEnd ?? feedPosition);
    final availableBytes = committedEnd - _readPosition;

    if (availableBytes <= 0) {
      if (_requestedEnd == null && _feed.isClosed) {
        _finishAtEndOfContent();
      } else {
        _waitForPosition(_readPosition + 1);
      }
      return;
    }

    _startRead(raf, min(_maxReadSize, availableBytes));
  }

  void _startRead(final RandomAccessFile raf, final int byteCount) {
    assert(!_readInProgress);
    assert(byteCount > 0);

    _readInProgress = true;
    raf.read(byteCount).then(
      _onRead,
      onError: (Object e, StackTrace stackTrace) {
        _readInProgress = false;
        _handleError(e, stackTrace);
      },
    );
  }

  void _onRead(final List<int> bytes) {
    _readInProgress = false;

    if (_closing || _isDone) {
      _finish().ignore();
      return;
    }

    final raf = _raf;
    if (raf == null) {
      _handleError(
        StateError('Partial cache file closed while a read was in progress'),
        StackTrace.current,
      );
      return;
    }

    if (bytes.isEmpty) {
      _handleError(
        FileSystemException(
          'Partial cache file ended before its committed position',
          raf.path,
        ),
        StackTrace.current,
      );
      return;
    }

    _readPosition += bytes.length;

    // Match dart:io File.openRead(): start the next eligible read (or register
    // the next feed wait) before synchronously delivering this block. If the
    // listener pauses while handling this block, at most one read is already
    // in flight and no further read is started until onResume calls _pump().
    _scheduleReadAhead();
    _controller.add(bytes);

    // Handles range completion, feed closure, or a pause that occurred while
    // the current block was being emitted. If read-ahead was already started,
    // _pump() is a no-op because _readInProgress/a waiter is active.
    _pump();
  }

  /// Schedules only work that is safe to begin before the current block is
  /// emitted. End-of-stream handling is deliberately left to [_pump] after the
  /// emission so the final block is never closed out before it is delivered.
  void _scheduleReadAhead() {
    if (_controller.isPaused || _atRequestedEnd) {
      return;
    }
    assert(!_readInProgress);
    assert(_positionWaiter?.isCompleted != false);

    final raf = _raf;
    if (raf == null) return;

    final feedPosition = _feed.position;
    final committedEnd = min(feedPosition, _requestedEnd ?? feedPosition);
    final availableBytes = committedEnd - _readPosition;

    if (availableBytes > 0) {
      _startRead(raf, min(_maxReadSize, availableBytes));
    } else if (!_feed.isClosed) {
      _waitForPosition(_readPosition + 1);
    }
  }

  void _waitForPosition(final int minPosition) {
    if (_closing || _isDone || _positionWaiter?.isCompleted == false) return;

    final waiter = _feed.waitForPosition(minPosition);
    _positionWaiter = waiter;

    waiter.future.then(
      (_) {
        if (!identical(_positionWaiter, waiter)) return;
        _positionWaiter = null;
        _pump();
      },
      onError: (Object e, StackTrace stackTrace) {
        if (identical(_positionWaiter, waiter)) {
          _positionWaiter = null;
        }
        _handleError(e, stackTrace);
      },
    );
  }

  Future<void> _awaitPosition(final int minPosition) async {
    assert(
      _positionWaiter?.isCompleted != false,
      'A previous position waiter is still pending; only one can be awaited at a time.',
    );
    assert(
      !_isDone,
      'Registering a position waiter after the listener is gone; it will never be cancelled.',
    );

    final waiter = _feed.waitForPosition(minPosition);
    _positionWaiter = waiter;
    try {
      await waiter.future;
    } finally {
      if (identical(_positionWaiter, waiter)) {
        _positionWaiter = null;
      }
    }
  }

  void _handleError(final Object e, final StackTrace stackTrace) {
    if (_closing || _isDone) {
      _finish().ignore();
      return;
    }

    if (e is PositionWaiterCancelledException) {
      _finish().ignore();
      return;
    }

    if (e is PartialCacheFeedClosedException && _requestedEnd == null) {
      _finishAtEndOfContent();
      return;
    }

    _controller.addError(e, stackTrace);
    _finish().ignore();
  }

  /// Ends a read with no known end position, now that the feed is closed.
  ///
  /// A closed feed is the only end-of-content signal available when the content
  /// length is unknown, so an aborted download has to be reported as an error.
  /// Returning normally would hand the listener a truncated body it would
  /// accept as complete.
  void _finishAtEndOfContent() {
    if (_closing || _isDone) {
      _finish().ignore();
      return;
    }
    if (_feed.failure case final Object failure) {
      _controller.addError(failure);
    }

    _finish().ignore();
  }

  /// Stops scheduling work and closes the file once any in-flight read has
  /// completed. This avoids closing a RandomAccessFile underneath raf.read().
  Future<void> _finish() {
    if (_closeCompleter.isCompleted) return _closeCompleter.future;

    _closing = true;
    _positionWaiter?.cancel();

    if (!_readInProgress) {
      _closeResources();
    }

    return _closeCompleter.future;
  }

  void _closeResources() async {
    if (_closeCompleter.isCompleted || _readInProgress) return;

    final raf = _raf;
    _raf = null;

    try {
      await raf?.close();
    } catch (_) {
      // Intentionally ignored.
    } finally {
      _controller.close().ignore();
      if (!_closeCompleter.isCompleted) {
        _closeCompleter.complete();
      }
    }
  }

  Future<RandomAccessFile> _openActiveCacheFile() async {
    assert(
      !_isDone,
      'The listener is gone; the read loop should not be running.',
    );
    try {
      return await _cacheFiles.activeCacheFile().open(mode: FileMode.read);
    } on FileSystemException {
      // The partial file may have been renamed after activeCacheFile() selected
      // it. Resolve the active path again and retry once.
      return _cacheFiles.activeCacheFile().open(mode: FileMode.read);
    }
  }
}
