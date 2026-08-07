part of 'buffered_io_sink.dart';

/// A read-only view of the bytes committed to an active partial cache file.
///
/// Implementations provide the current [position] and lifecycle state. This
/// class owns the shared position-waiting behavior so consumers do not need to
/// poll the file system.
abstract class PartialCacheFeed {
  final List<_PendingPositionWaiter> _positionWaiters = [];
  bool _isClosed = false;
  Object? _failure;

  /// The exclusive end position currently safe to read from the cache file.
  int get position;

  /// Whether the producer can no longer commit additional bytes.
  bool get isClosed => _isClosed;

  /// The error this feed ended with, or null if it is still open or reached the
  /// end of its content cleanly.
  ///
  /// A closed feed with no [failure] means [position] is the true end of the
  /// content. A closed feed with a [failure] stopped short of it, so readers
  /// that do not know the content length must not treat it as an end of stream.
  Object? get failure => _failure;

  /// Returns a [PositionWaiter] that completes once [position] reaches or
  /// exceeds [minPosition].
  ///
  /// The waiter is returned synchronously and may already be completed. It
  /// fails if the feed fails, closes before reaching the requested position, or
  /// is cancelled via [PositionWaiter.cancel]. Callers that no longer need the
  /// position must cancel the waiter to release it.
  PositionWaiter waitForPosition(final int minPosition) {
    if (position >= minPosition) {
      return _CompletedPositionWaiter.reached(minPosition);
    }

    final failure = _failure;
    if (failure != null) {
      return _CompletedPositionWaiter.failed(minPosition, failure);
    }

    if (isClosed) {
      return _CompletedPositionWaiter.failed(
        minPosition,
        PartialCacheFeedClosedException(minPosition),
      );
    }

    final waiter = _PendingPositionWaiter(this, minPosition);
    _positionWaiters.add(waiter);
    return waiter;
  }

  /// Closes the feed and resolves every waiter the producer can no longer
  /// satisfy.
  ///
  /// Without a [failure], [position] is the true end of the content. With a
  /// [failure], the producer stopped short and readers must not interpret the
  /// final position as a clean end of stream.
  void _close({final Object? failure}) {
    if (_isClosed) return;
    _isClosed = true;
    _failure ??= failure;

    if (_positionWaiters.isEmpty) return;
    final waiters = List<_PendingPositionWaiter>.of(_positionWaiters);
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
    final waiters = List<_PendingPositionWaiter>.of(_positionWaiters);
    _positionWaiters.clear();
    for (final waiter in waiters) {
      waiter._completeError(_failure!);
    }
  }
}
