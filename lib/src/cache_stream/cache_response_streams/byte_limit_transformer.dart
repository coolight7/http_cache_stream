import 'dart:async';

///A stream transformer that limits the number of bytes emitted from the source stream.
class ByteLimitTransformer extends StreamTransformerBase<List<int>, List<int>> {
  final int limit;
  ByteLimitTransformer(this.limit);

  @override
  Stream<List<int>> bind(Stream<List<int>> stream) {
    return Stream<List<int>>.eventTransformed(
      stream,
      (EventSink<List<int>> sink) => ByteLimitSink(sink, limit),
    );
  }
}

class ByteLimitSink implements EventSink<List<int>> {
  final EventSink<List<int>> _outputSink;
  final int endPosition;
  int _receivedBytes = 0;

  ByteLimitSink(this._outputSink, this.endPosition);

  @override
  void add(List<int> data) {
    final nextPosition = _receivedBytes + data.length;
    if (nextPosition >= endPosition) {
      // Take only what we need
      final remaining = endPosition - _receivedBytes;
      if (remaining > 0) {
        _outputSink.add(data.sublist(0, remaining));
      }
      close();
    } else {
      _outputSink.add(data);
      _receivedBytes = nextPosition;
    }
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    _outputSink.addError(error, stackTrace);
  }

  @override
  void close() {
    _outputSink.close();
  }
}
