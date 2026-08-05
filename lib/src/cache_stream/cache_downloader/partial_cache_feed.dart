part of 'buffered_io_sink.dart';

/// A read-only view of the bytes committed to an active partial cache file.
///
/// Implementations provide the current [position] and lifecycle state. This
/// class owns the shared position-waiting behavior so consumers do not need to
/// poll the file system.
abstract class PartialCacheFeed {
  final List<_PendingPositionWaiter> _positionWaiters = [];
  Object? _failure;

  /// The exclusive end position currently safe to read from the cache file.
  int get position;

  /// Whether the producer can no longer commit additional bytes.
  bool get isClosed;

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
        _closedError(minPosition),
      );
    }

    final waiter = _PendingPositionWaiter(this, minPosition);
    _positionWaiters.add(waiter);
    return waiter;
  }

  static StateError _closedError(final int minPosition) => StateError(
        'Partial cache feed closed before reaching position $minPosition',
      );

  /// Resolves the waiters left pending when the producer reached the end of its
  /// content.
  ///
  /// The feed is not marked as failed: [position] is the true end of the
  /// content, so a reader that does not know the content length has reached the
  /// end of the stream. Only waiters past that end are failed, since they can
  /// no longer be satisfied.
  void _closePositionWaiters() {
    if (_positionWaiters.isEmpty) return;
    final waiters = List<_PendingPositionWaiter>.of(_positionWaiters);
    _positionWaiters.clear();
    for (final waiter in waiters) {
      waiter._completeError(_closedError(waiter.minPosition));
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

/// Thrown when a [PartialCacheFeed] stops before reaching the end of its
/// content, because the download that fills it was aborted.
///
/// Distinguishes an aborted download from a clean end of content, which readers
/// that do not know the content length cannot tell apart from [position] alone.
class PartialCacheAbortedException implements Exception {
  /// The position the feed stopped at.
  final int position;
  const PartialCacheAbortedException(this.position);

  @override
  String toString() =>
      'PartialCacheAbortedException: Download aborted at position $position, '
      'before the end of the content';
}
