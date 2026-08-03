import 'http_client_builder.dart';

/// What the benchmark measures.
enum BenchmarkType {
  /// The file is fully downloaded before the run starts, so every request is
  /// served from the completed cache file.
  preCached(
    'Pre-cached',
    'Fully pre-cache the file, then benchmark the cache server serving it from disk.',
  ),

  /// The cache is wiped before the run, so requests race the cache download.
  nonCached(
    'Non-cached',
    'Wipe the cache first; requests are served while the source is still downloading.',
  ),

  /// http_cache_stream is bypassed entirely.
  direct(
    'Direct',
    'Bypass http_cache_stream and request the source URL directly.',
  );

  const BenchmarkType(this.label, this.description);

  final String label;
  final String description;

  /// Whether this type routes requests through the local cache server.
  bool get usesCacheServer => this != BenchmarkType.direct;
}

/// An inclusive byte range, matching HTTP `Range` semantics.
class ByteRange {
  const ByteRange(this.start, this.end)
      : assert(start >= 0),
        assert(end >= start);

  /// First byte requested, inclusive.
  final int start;

  /// Last byte requested, inclusive.
  final int end;

  /// Number of bytes the response should carry.
  int get length => end - start + 1;

  /// Value for the `Range` request header.
  String get header => 'bytes=$start-$end';

  /// Builds a range from two fractions of [contentLength], as produced by the
  /// range slider. Returns null when the content length is unknown or the
  /// selection is empty.
  static ByteRange? fromFractions(
    double startFraction,
    double endFraction,
    int contentLength,
  ) {
    final bounds = resolveBounds(startFraction, endFraction, contentLength);
    if (bounds == null) return null;
    if (bounds.endExclusive <= bounds.start) return null; // Empty selection.
    return ByteRange(bounds.start, bounds.endExclusive - 1);
  }

  /// Whether the given fractions select no bytes at all.
  static bool isEmptySelection(
    double startFraction,
    double endFraction,
    int contentLength,
  ) {
    final bounds = resolveBounds(startFraction, endFraction, contentLength);
    return bounds != null && bounds.endExclusive <= bounds.start;
  }

  /// Resolves slider fractions to absolute byte offsets, or null when the
  /// content length is unknown.
  static ({int start, int endExclusive})? resolveBounds(
    double startFraction,
    double endFraction,
    int contentLength,
  ) {
    if (contentLength <= 0) return null;
    return (
      start: (startFraction.clamp(0.0, 1.0) * contentLength).floor(),
      endExclusive: (endFraction.clamp(0.0, 1.0) * contentLength).round(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ByteRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'bytes $start-$end';
}

/// How each request's `Range` header is chosen.
enum RangeMode {
  /// No `Range` header: every request asks for the whole body.
  full(
    'Full response',
    'Every request downloads the entire source.',
  ),

  /// Every request asks for the same selected range.
  fixed(
    'Fixed range',
    'Every request asks for the same byte range.',
  ),

  /// Each request asks for the next window of the selected range.
  sequential(
    'Sequential windows',
    'The selected range is divided between the requests: each one asks for the '
        'next window, the same size as the last.',
  );

  const RangeMode(this.label, this.description);

  final String label;
  final String description;

  /// Whether this mode needs the source's content length to be known.
  bool get needsContentLength => this != RangeMode.full;
}

/// The `Range` each request in a run asks for.
///
/// A plan covers both [RangeMode.fixed] — where [windowSize] spans the whole
/// range, so every request resolves to the same window — and
/// [RangeMode.sequential], where consecutive requests advance by [windowSize].
class RangePlan {
  const RangePlan({
    required this.start,
    required this.end,
    required this.windowSize,
  })  : assert(start >= 0),
        assert(end >= start),
        assert(windowSize >= 1);

  /// First byte of the region requests are taken from, inclusive.
  final int start;

  /// Last byte of the region, inclusive.
  final int end;

  /// Bytes each individual request asks for.
  final int windowSize;

  /// Size of the region the windows are taken from.
  int get length => end - start + 1;

  /// Whether consecutive requests ask for different windows.
  bool get isSequential => windowSize < length;

  /// Highest start offset that still leaves a full window before [end].
  int get _maxWindowStart => end - windowSize + 1;

  /// The window the request with this global [sequence] number asks for.
  ///
  /// Windows tile the region back to back. The final window slides back so it
  /// ends exactly on [end], which keeps every request the same size at the cost
  /// of a small overlap with the window before it. Sequences past the end of
  /// the region resolve to that final window.
  ByteRange windowFor(int sequence) {
    final offset = start + sequence * windowSize;
    final windowStart = offset > _maxWindowStart ? _maxWindowStart : offset;
    return ByteRange(windowStart, windowStart + windowSize - 1);
  }

  /// Builds a plan that divides [range] between [requestCount] requests.
  ///
  /// The window is rounded up so the windows always reach [ByteRange.end]; the
  /// last one slides back to stay the same size as the rest.
  static RangePlan sequential(ByteRange range, int requestCount) {
    assert(requestCount >= 1);
    final windowSize =
        (range.length / requestCount).ceil().clamp(1, range.length);
    return RangePlan(
      start: range.start,
      end: range.end,
      windowSize: windowSize,
    );
  }

  /// Builds a plan where every request asks for [range].
  static RangePlan fixed(ByteRange range) => RangePlan(
        start: range.start,
        end: range.end,
        windowSize: range.length,
      );

  @override
  String toString() =>
      'RangePlan(bytes $start-$end, window $windowSize, '
      'sequential: $isSequential)';
}

/// A single benchmark run's inputs.
class BenchmarkConfig {
  const BenchmarkConfig({
    required this.sourceUrl,
    required this.concurrency,
    required this.totalRequests,
    required this.type,
    required this.clientOption,
    this.rangePlan,
  });

  /// The remote URL under test.
  final Uri sourceUrl;

  /// Number of worker isolates. Requests are divided between them.
  final int concurrency;

  /// Total requests to issue across all workers.
  final int totalRequests;

  final BenchmarkType type;

  /// Which [HttpClientBuilder] the workers use.
  final HttpClientOption clientOption;

  /// Which bytes each request asks for, or null to request full responses.
  final RangePlan? rangePlan;

  /// Splits [totalRequests] across [concurrency] workers as evenly as possible.
  ///
  /// The remainder is handed to the lowest-numbered workers, so the returned
  /// counts differ by at most one and always sum to [totalRequests].
  List<int> requestDistribution() {
    final base = totalRequests ~/ concurrency;
    final remainder = totalRequests % concurrency;
    return List<int>.generate(
      concurrency,
      (index) => base + (index < remainder ? 1 : 0),
    );
  }

  /// Returns a human-readable validation error, or null when the config is
  /// runnable.
  static String? validate({
    required String url,
    required int? concurrency,
    required int? totalRequests,
  }) {
    final uri = Uri.tryParse(url.trim());
    if (url.trim().isEmpty || uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return 'Enter a valid absolute source URL.';
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      return 'Source URL must use http or https.';
    }
    if (concurrency == null || concurrency < 1) {
      return 'Concurrency must be at least 1.';
    }
    if (totalRequests == null || totalRequests < 1) {
      return 'Total requests must be at least 1.';
    }
    if (totalRequests < concurrency) {
      return 'Total requests must be at least the concurrency ($concurrency).';
    }
    return null;
  }
}
