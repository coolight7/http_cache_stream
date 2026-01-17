import 'dart:async';
import 'dart:typed_data';

class ChunkedBytesBuffer {
  final void Function(List<int> data) _onChunk;
  final int minChunkSize;
  ChunkedBytesBuffer(this._onChunk, this.minChunkSize);
  final _buffer = BytesBuilder(copy: false);

  void add(final List<int> bytes) {
    if (_buffer.isNotEmpty) {
      _buffer.add(bytes);
      if (_buffer.length >= minChunkSize) {
        flush();
      }
    } else if (bytes.length >= minChunkSize) {
      _onChunk(bytes);
    } else {
      _buffer.add(bytes);
    }
  }

  void flush() {
    if (_buffer.isNotEmpty) {
      _onChunk(_buffer.takeBytes());
    }
  }

  void clear() {
    _buffer.clear();
  }

  bool get isEmpty => _buffer.isEmpty;
  int get bufferSize => _buffer.length;
}

class ChunkedBytesTransformer
    extends StreamTransformerBase<List<int>, List<int>> {
  final int minChunkSize;
  ChunkedBytesTransformer(this.minChunkSize);

  @override
  Stream<List<int>> bind(Stream<List<int>> stream) {
    return Stream<List<int>>.eventTransformed(
      stream,
      (EventSink<List<int>> sink) => _ChunkedBytesSink(sink, minChunkSize),
    );
  }
}

class _ChunkedBytesSink implements EventSink<List<int>> {
  final EventSink<List<int>> _outputSink;
  final ChunkedBytesBuffer _buffer;
  _ChunkedBytesSink(this._outputSink, int minChunkSize)
      : _buffer = ChunkedBytesBuffer(_outputSink.add, minChunkSize);

  @override
  void add(List<int> data) {
    _buffer.add(data);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    _buffer.flush();
    _outputSink.addError(error, stackTrace);
  }

  @override
  void close() {
    if (_isClosed) return;
    _isClosed = true;
    _buffer.flush();
    _outputSink.close();
  }

  bool _isClosed = false;
}
