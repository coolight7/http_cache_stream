part of 'buffered_io_sink.dart';

/// A read-only view of the bytes committed to an active partial cache file.
///
/// Implementations provide the current [position] and lifecycle state. This
/// class owns the shared position-waiting behavior so consumers do not need to
/// poll the file system.
abstract class PartialCacheFeed {
  final List<({int position, Completer<void> completer})> _positionWaiters = [];
  Object? _failure;

  /// The exclusive end position currently safe to read from the cache file.
  int get position;

  /// Whether the producer can no longer commit additional bytes.
  bool get isClosed;

  /// Completes once [position] reaches or exceeds [minPosition].
  ///
  /// The future fails if the feed fails or closes before reaching the requested
  /// position. It also fails if [timeout] elapses first.
  Future<void> waitForPosition(
    final int minPosition, [
    final Duration timeout = const Duration(seconds: 30),
  ]) {
    if (position >= minPosition) return Future<void>.value();

    final failure = _failure;
    if (failure != null) return Future<void>.error(failure);
    if (isClosed) {
      return Future<void>.error(
        StateError(
          'Partial cache feed closed before reaching position $minPosition',
        ),
      );
    }

    final completer = Completer<void>();
    _positionWaiters.add((position: minPosition, completer: completer));
    return completer.future.timeout(timeout, onTimeout: () {
      _positionWaiters.removeWhere((waiter) => waiter.completer == completer);
      throw TimeoutException(
        'Timeout while waiting for partial cache position to reach '
        '$minPosition',
        timeout,
      );
    });
  }

  void _notifyPositionWaiters() {
    if (_positionWaiters.isEmpty) return;
    final currentPosition = position;
    for (int i = _positionWaiters.length - 1; i >= 0; i--) {
      if (currentPosition >= _positionWaiters[i].position) {
        _positionWaiters.removeAt(i).completer.complete();
      }
    }
  }

  void _failPositionWaiters(final Object error) {
    _failure ??= error;
    if (_positionWaiters.isEmpty) return;
    for (final waiter in _positionWaiters) {
      waiter.completer.completeError(_failure!);
    }
    _positionWaiters.clear();
  }
}
