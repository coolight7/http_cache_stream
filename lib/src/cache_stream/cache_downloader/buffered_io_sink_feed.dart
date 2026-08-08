part of 'buffered_io_sink.dart';

/// Read-only partial-cache progress backed by a [BufferedIOSink].
final class BufferedIOSinkFeed implements PartialCacheFeed {
  final BufferedIOSink _sink;
  final List<_BufferedPositionWaiter> _positionWaiters = [];
  bool _isClosed = false;
  Object? _failure;

  BufferedIOSinkFeed._(this._sink);

  @override
  int get position => _sink.flushedBytes;

  @override
  bool get isClosed => _isClosed;

  @override
  Object? get failure => _failure;

  @override
  PositionWaiter waitForPosition(final int minPosition) {
    if (position >= minPosition) {
      return PositionWaiter.reached(minPosition);
    }

    final failure = _failure;
    if (failure != null) {
      return PositionWaiter.failed(minPosition, failure);
    }

    if (isClosed) {
      return PositionWaiter.failed(
        minPosition,
        PartialCacheFeedClosedException(minPosition),
      );
    }

    final waiter = _BufferedPositionWaiter(this, minPosition);
    _positionWaiters.add(waiter);
    return waiter;
  }

  void _close({final Object? failure}) {
    if (_isClosed) return;
    _isClosed = true;
    _failure ??= failure;

    if (_positionWaiters.isEmpty) return;
    final waiters = List<_BufferedPositionWaiter>.of(_positionWaiters);
    _positionWaiters.clear();
    for (final waiter in waiters) {
      waiter._completeError(
        _failure ?? PartialCacheFeedClosedException(waiter.minPosition),
      );
    }
  }

  void _notifyPositionWaiters() {
    if (_positionWaiters.isEmpty) return;
    final currentPosition = position;
    for (int i = _positionWaiters.length - 1; i >= 0; i--) {
      if (currentPosition >= _positionWaiters[i].minPosition) {
        _positionWaiters.removeAt(i)._complete();
      }
    }
  }

  void _failPositionWaiters(final Object error) {
    _failure ??= error;
    if (_positionWaiters.isEmpty) return;
    final waiters = List<_BufferedPositionWaiter>.of(_positionWaiters);
    _positionWaiters.clear();
    for (final waiter in waiters) {
      waiter._completeError(_failure!);
    }
  }
}

final class _BufferedPositionWaiter extends PositionWaiter {
  final BufferedIOSinkFeed _feed;
  final _completer = Completer<void>();

  _BufferedPositionWaiter(this._feed, super.minPosition);

  @override
  Future<void> get future => _completer.future;

  @override
  bool get isCompleted => _completer.isCompleted;

  @override
  void cancel() {
    if (_completer.isCompleted) return;
    _feed._positionWaiters.remove(this);
    _completer.completeError(PositionWaiterCancelledException(minPosition));
  }

  void _complete() {
    if (_completer.isCompleted) return;
    _completer.complete();
  }

  void _completeError(final Object error) {
    if (_completer.isCompleted) return;
    _completer.completeError(error);
  }
}
