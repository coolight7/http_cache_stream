/// Thrown when a cleanly closed cache download cannot reach a requested
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

/// Thrown when a cache download stops before reaching the end of its
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
