import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// By default, IOSink retains all data in memory until the sink is closed or flushed. This can lead to high memory usage if large amounts of data are written to the sink without flushing.
/// To avoid this, we use a buffered IOSink that flushes data in chunks, while still allowing data to be buffered while waiting for the sink to flush.
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
    assert(!_isClosed, 'BufferedIOSink is closed');
    _buffer.add(data);
  }

  Future<void> close({final bool flushBuffer = true}) async {
    if (flushBuffer) {
      while (_flushFuture != null || _buffer.isNotEmpty) {
        await flush();
      }
    } else {
      _buffer.clear(); //Clear the buffer if we are not flushing
    }
    return _sink.close().whenComplete(() {
      _isClosed = true; //Set the sink to closed
      _buffer.clear(); //Clear the buffer just in case
    });
  }

  Future<void> flush() async {
    while (_flushFuture != null) {
      await _flushFuture!; //Allow any previous flush to complete
    }
    if (_buffer.isEmpty) {
      return; //Nothing to flush
    }
    try {
      final bufferedData =
          _buffer.takeBytes(); //Take the buffered data, and clear the buffer
      _sink.add(bufferedData); //Add the buffer to the sink
      await (_flushFuture =
          _sink.flush()); //Set the flush future and wait for it to complete
    } finally {
      _flushFuture = null; //Reset the flush future
    }
  }

  int get bufferSize => _buffer.length;
  bool get isFlushing => _flushFuture != null;
  bool get isClosed => _isClosed;
  bool _isClosed = false;
  Future? _flushFuture;
}
