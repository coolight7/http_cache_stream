part of 'buffered_io_sink.dart';

/// Read-only partial-cache progress backed by a [BufferedIOSink].
final class BufferedIOSinkFeed extends PartialCacheFeed {
  final BufferedIOSink _sink;
  BufferedIOSinkFeed._(this._sink);

  @override
  int get position => _sink.flushedBytes;
}
