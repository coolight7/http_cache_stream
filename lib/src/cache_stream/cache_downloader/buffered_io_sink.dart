import 'dart:io';
import 'dart:typed_data';

/// An IO sink that supports adding data while flushing to disk asynchronously.
class BufferedIOSink {
  final File file;
  BufferedIOSink(this.file, final int start)
      : _raf = file.openSync(
          mode: start > 0 ? FileMode.append : FileMode.write,
        );

  final RandomAccessFile _raf;
  final _buffer = BytesBuilder(copy: false);
  int _flushedBytes = 0;
  bool _isClosed = false;
  Future<void>? _flushFuture;

  void add(List<int> data) {
    if (_isClosed) {
      throw StateError('Cannot add data to a closed sink.');
    }
    _buffer.add(data);
  }

  /// Flushes all buffered data to disk. If new data is added during flushing, it will continue flushing until the buffer is empty.
  /// If an error occurs during flushing, it will be propagated to the caller, and all future flush attempts will rethrow the same error.
  Future<void> flush() {
    if (_buffer.isEmpty) return _flushFuture ?? Future.value();
    return _flushFuture ??= () async {
      while (_buffer.isNotEmpty) {
        final bytes = _buffer.takeBytes();
        await _raf.writeFrom(bytes, 0, bytes.length);
        _flushedBytes += bytes.length;
      }
      _flushFuture = null;
    }();
  }

  Future<void> close({final bool flushBuffer = true}) async {
    if (_isClosed) return;
    _isClosed = true;

    try {
      if (flushBuffer) {
        try {
          await flush();
        } finally {
          await _raf.flush();
        }
      }
    } finally {
      _buffer.clear();
      await _raf.close();
    }
  }

  int get bufferSize => _buffer.length;
  int get flushedBytes => _flushedBytes;
  bool get flushed => _buffer.isEmpty && !isFlushing;
  bool get isFlushing => _flushFuture != null;
  bool get isClosed => _isClosed;
}
