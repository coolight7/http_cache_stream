///A class that represents a range of exclusive integers, used for stream ranges.
class IntRange {
  final int start;
  final int? end;
  const IntRange([this.start = 0, this.end])
    : assert(start >= 0 && (end == null || end >= start));

  static IntRange full() => const IntRange(0);

  ///Constructs an IntRange with validation.
  static IntRange construct(int? start, int? end, int? max) {
    if ((start ??= 0) == 0 && end == null) {
      return IntRange.full();
    }
    if (end != null) {
      start = RangeError.checkValueInInterval(start, 0, end);
      end = RangeError.checkValueInInterval(end, start, max ?? end);
    } else if (max != null) {
      start = RangeError.checkValueInInterval(start, 0, max);
    } else {
      start = RangeError.checkNotNegative(start);
    }
    return IntRange(start, end);
  }

  bool exceeds(int value) {
    return greatest > value;
  }

  int get greatest => end ?? start;

  int? get range {
    if (end == null) return null;
    return end! - start;
  }

  IntRange copyWith({int? start, int? end}) {
    return IntRange(start ?? this.start, end ?? this.end);
  }

  bool get isFull => start == 0 && end == null;

  @override
  String toString() => 'IntRange($start, $end)';

  @override
  bool operator ==(Object other) =>
      other is IntRange && start == other.start && end == other.end;

  @override
  int get hashCode => start.hashCode ^ end.hashCode;
}
