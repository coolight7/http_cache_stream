part of 'buffered_io_sink.dart';

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

  /// Completes once the feed reaches [minPosition].
  ///
  /// Fails with the feed's failure if it fails or closes before reaching
  /// [minPosition], or with [PositionWaiterCancelledException] if [cancel] is
  /// called first.
  Future<void> get future;

  /// Whether [future] has already completed, successfully or otherwise.
  bool get isCompleted;

  /// Abandons the wait, releasing it from the feed.
  ///
  /// Does nothing if [future] has already completed. Otherwise [future] fails
  /// with [PositionWaiterCancelledException].
  void cancel();

  @override
  int compareTo(PositionWaiter other) => minPosition.compareTo(other.minPosition);

  @override
  String toString() => '$runtimeType(minPosition: $minPosition, isCompleted: $isCompleted)';
}

/// A [PositionWaiter] that was already resolved when it was created.
///
/// The feed never tracks these, so [cancel] has nothing to release.
final class _CompletedPositionWaiter extends PositionWaiter {
  @override
  final Future<void> future;

  /// The requested position was already committed to the cache file.
  _CompletedPositionWaiter.reached(super.minPosition) : future = Future<void>.value();

  /// The feed had already failed or closed short of the requested position.
  _CompletedPositionWaiter.failed(super.minPosition, final Object error) : future = Future<void>.error(error);

  @override
  bool get isCompleted => true;

  @override
  void cancel() {}
}

/// A [PositionWaiter] tracked by a [PartialCacheFeed] until it resolves.
///
/// Uses a synchronous completer so a waiter is resumed within the same event
/// loop as the write that satisfied it, rather than a microtask later.
final class _PendingPositionWaiter extends PositionWaiter {
  final PartialCacheFeed _feed;
  final _completer = Completer<void>();

  _PendingPositionWaiter(this._feed, super.minPosition);

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

/// Thrown when a [PositionWaiter] is cancelled before its position is reached.
class PositionWaiterCancelledException implements Exception {
  /// The position that was being waited for.
  final int minPosition;
  const PositionWaiterCancelledException(this.minPosition);

  @override
  String toString() => 'PositionWaiterCancelledException: Cancelled while waiting for partial '
      'cache position $minPosition';
}
