import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

part 'buffered_io_sink_feed.dart';
part 'partial_cache_feed.dart';
part 'position_waiter.dart';

/// An IO sink that supports adding data while flushing to disk asynchronously.
class BufferedIOSink {
  //Maximum number of bytes to write in a single write operation. This prevents long writes from stalling position waiters.
  static const int _maxWriteSize = 256 * 1024; // 256 KB

  final File file;
  BufferedIOSink(this.file, int initialPosition) : _flushedBytes = initialPosition {
    _feed = BufferedIOSinkFeed._(this);
  }

  int _flushedBytes;
  final _buffer = BytesBuilder(copy: false);
  RandomAccessFile? _openedRAF;
  bool _isClosed = false;
  Future<void>? _flushFuture;
  late final BufferedIOSinkFeed _feed;

  void add(List<int> data) {
    if (_isClosed) {
      throw StateError('Cannot add data to a closed sink.');
    }
    _buffer.add(data);
  }

  /// Flushes all buffered data to disk. If new data is added during flushing, it will continue flushing until the buffer is empty.
  /// If an error occurs during flushing, it will be propagated to the caller, and all future flush attempts will rethrow the same error.
  Future<void> flush() {
    if (_flushFuture != null) return _flushFuture!;
    if (_buffer.isEmpty) return Future.value();

    return _flushFuture = () async {
      try {
        RandomAccessFile? raf = _openedRAF;

        if (raf == null) {
          FileMode fileMode = FileMode.append;

          if (flushedBytes == 0) {
            await file.parent.create(recursive: true); //Ensure directory exists
            fileMode = FileMode.write; //Overwrite existing
          }

          raf = _openedRAF = await file.open(mode: fileMode);
        }

        while (_buffer.isNotEmpty) {
          final bytes = _buffer.takeBytes();
          for (int start = 0; start < bytes.length; start += _maxWriteSize) {
            final int uncappedEnd = start + _maxWriteSize;
            final int end = uncappedEnd < bytes.length ? uncappedEnd : bytes.length;
            await raf.writeFrom(bytes, start, end);
            _flushedBytes += end - start;
            _feed._notifyPositionWaiters();
          }
        }
        _flushFuture = null;
      } catch (e) {
        _feed._failPositionWaiters(e);
        rethrow;
      }
    }();
  }

  /// Returns a [PositionWaiter] that completes once [flushedBytes] reaches or exceeds [minFlushedBytes].
  /// Completes immediately if the position is already reached.
  /// Fails if the sink is closed, a flush error occurs before the position is reached, or the waiter is cancelled.
  PositionWaiter waitForPosition(int minFlushedBytes) => _feed.waitForPosition(minFlushedBytes);

  /// Closes the sink, resolving any waiters that can no longer be satisfied.
  ///
  /// Set [isDone] when the producer reached the end of its content. The feed is
  /// then left unfailed, so readers treat [flushedBytes] as the true end of the
  /// content. When [isDone] is false the download was aborted, and the feed
  /// fails with [PartialCacheAbortedException] so readers do not mistake the
  /// truncated content for an end of stream.
  Future<void> close({
    final bool flushBuffer = true,
    final bool isDone = false,
  }) async {
    if (_isClosed) return;
    _isClosed = true;

    try {
      if (!flushBuffer) {
        _buffer.clear();
      }
      await flush(); //Even if !flushBuffer, ongoing flush must complete before RAF can be closed
    } finally {
      _buffer.clear();
      try {
        if (_openedRAF case final RandomAccessFile raf) {
          _openedRAF = null;
          await raf.close();
        }
      } finally {
        _feed._close(
          failure: isDone ? null : PartialCacheAbortedException(_flushedBytes),
        );
      }
    }
  }

  int get bufferSize => _buffer.length;
  int get flushedBytes => _flushedBytes;
  PartialCacheFeed get feed => _feed;
  bool get flushed => _buffer.isEmpty && !isFlushing;
  bool get isFlushing => _flushFuture != null;
  bool get isClosed => _isClosed;
}
