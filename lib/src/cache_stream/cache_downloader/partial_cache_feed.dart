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
        _closedError(minPosition),
      );
    }

    final waiter = _PendingPositionWaiter(this, minPosition);
    _positionWaiters.add(waiter);
    return waiter;
  }

  static PartialCacheFeedClosedException _closedError(
    final int minPosition,
  ) =>
      PartialCacheFeedClosedException(minPosition);

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
        _failure ?? _closedError(waiter.minPosition),
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

/// Thrown when a cleanly closed [PartialCacheFeed] cannot reach a requested
/// position.
///
/// Readers without a known end position may interpret this as end of content.
/// Readers with a requested end must retain the error because the feed ended
/// before satisfying their range.
class PartialCacheFeedClosedException extends StateError {
  /// The position the closed feed could not reach.
  final int minPosition;

  PartialCacheFeedClosedException(this.minPosition)
      : super(
          'Partial cache feed closed before reaching position $minPosition',
        );
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
  String toString() => 'PartialCacheAbortedException: Download aborted at position $position, '
      'before the end of the content';
}
