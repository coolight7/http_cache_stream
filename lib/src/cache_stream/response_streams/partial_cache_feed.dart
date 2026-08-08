import 'dart:async';

import '../../models/exceptions/partial_cache_feed_exceptions.dart';

/// A read-only view of the bytes committed to a partial cache file.
abstract interface class PartialCacheFeed {
  /// Creates a feed that is already closed at [finalPosition].
  const factory PartialCacheFeed.completed(final int finalPosition) =
      CompletedPartialCacheFeed;

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
  Object? get failure;

  /// Returns a waiter that completes once [position] reaches or exceeds
  /// [minPosition].
  ///
  /// The waiter is returned synchronously and may already be completed. It
  /// fails if the feed fails, closes before reaching the requested position, or
  /// is cancelled via [PositionWaiter.cancel]. Callers that no longer need the
  /// position must cancel the waiter to release it.
  PositionWaiter waitForPosition(int minPosition);
}

/// A partial-cache feed whose final position is already known.
///
/// This feed is closed successfully from construction. Requests at or before
/// [position] complete immediately; later requests fail because the cache file
/// cannot grow any further.
final class CompletedPartialCacheFeed implements PartialCacheFeed {
  @override
  final int position;

  const CompletedPartialCacheFeed(this.position)
      : assert(position >= 0, 'The final position cannot be negative.');

  @override
  bool get isClosed => true;

  @override
  Object? get failure => null;

  @override
  PositionWaiter waitForPosition(final int minPosition) {
    if (position >= minPosition) {
      return PositionWaiter.reached(minPosition);
    }
    return PositionWaiter.failed(
      minPosition,
      PartialCacheFeedClosedException(minPosition),
    );
  }
}

/// A request for a [PartialCacheFeed] to reach [minPosition].
///
/// Returned synchronously by [PartialCacheFeed.waitForPosition], and may
/// already be completed. Await [future] to observe the result, or call [cancel]
/// to abandon a wait that is no longer needed.
abstract class PositionWaiter implements Comparable<PositionWaiter> {
  /// The position [PartialCacheFeed.position] must reach for [future] to
  /// complete successfully.
  final int minPosition;
  const PositionWaiter(this.minPosition);

  /// Creates a waiter for a position that has already been reached.
  factory PositionWaiter.reached(final int minPosition) =
      _CompletedPositionWaiter.reached;

  /// Creates a waiter for a position that can no longer be reached.
  factory PositionWaiter.failed(
    final int minPosition,
    final Object error,
  ) = _CompletedPositionWaiter.failed;

  /// Completes once the feed reaches [minPosition].
  Future<void> get future;

  /// Whether [future] has already completed, successfully or otherwise.
  bool get isCompleted;

  /// Abandons the wait, releasing it from the feed.
  void cancel();

  @override
  int compareTo(final PositionWaiter other) =>
      minPosition.compareTo(other.minPosition);

  @override
  String toString() =>
      '$runtimeType(minPosition: $minPosition, isCompleted: $isCompleted)';
}

/// A waiter that was already resolved when it was created.
///
/// Feed implementations can use this for positions that have already been
/// reached or can no longer be reached.
final class _CompletedPositionWaiter extends PositionWaiter {
  @override
  final Future<void> future;

  _CompletedPositionWaiter.reached(super.minPosition)
      : future = Future<void>.value();

  _CompletedPositionWaiter.failed(
    super.minPosition,
    final Object error,
  ) : future = Future<void>.error(error);

  @override
  bool get isCompleted => true;

  @override
  void cancel() {}
}

/// Thrown when a [PositionWaiter] is cancelled before its position is reached.
class PositionWaiterCancelledException implements Exception {
  /// The position that was being waited for.
  final int minPosition;
  const PositionWaiterCancelledException(this.minPosition);

  @override
  String toString() =>
      'PositionWaiterCancelledException: Cancelled while waiting for partial '
      'cache position $minPosition';
}
