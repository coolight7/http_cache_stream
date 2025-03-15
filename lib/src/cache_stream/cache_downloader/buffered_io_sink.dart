import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// A buffered IO sink that allows writing data to an [IOSink] in chunks, allowing data to be buffered while waiting for the sink to flush.
/// This is useful for writing large amounts of data to a file without blocking the main thread, and improves performance by reducing the number of I/O operations.
class BufferedIOSink {
  final File file;
  final int start;
  BufferedIOSink(this.file, {this.start = 0})
    : _sink = file.openWrite(
        mode: start > 0 ? FileMode.append : FileMode.write,
      );
  final IOSink _sink;

  final _buffer = BytesBuilder(copy: false);

  void add(List<int> data) {
    _buffer.add(data);
  }

  Future<void> close() {
    _buffer.clear();
    return _sink.close();
  }

  Future<void> flush() async {
    while (_flushFuture != null) {
      await _flushFuture!; //Allow any previous flush to complete
    }
    if (_buffer.isEmpty) {
      return; //Nothing to flush
    }
    try {
      _sink.add(_buffer.takeBytes()); //Add the buffer to the sink and clear it
      await (_flushFuture =
          _sink.flush()); //Set the flush future and wait for it to complete
    } finally {
      _flushFuture = null; //Reset the flush future
    }
  }

  int get bufferSize => _buffer.length;
  bool get isFlushed => _buffer.isEmpty && _flushFuture == null;
  bool get isFlushing => _flushFuture != null;
  Future? _flushFuture;
}
