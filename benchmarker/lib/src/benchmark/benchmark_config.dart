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
  /// range slider. Returns null when the selection covers the whole source —
  /// no `Range` header is sent then — or when it is empty.
  static ByteRange? fromFractions(
    double startFraction,
    double endFraction,
    int contentLength,
  ) {
    final bounds = resolveBounds(startFraction, endFraction, contentLength);
    if (bounds == null) return null;
    if (bounds.start <= 0 && bounds.endExclusive >= contentLength) {
      return null; // Whole body.
    }
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

/// A single benchmark run's inputs.
class BenchmarkConfig {
  const BenchmarkConfig({
    required this.sourceUrl,
    required this.concurrency,
    required this.totalRequests,
    required this.type,
    required this.clientOption,
    this.range,
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

  /// Byte range each request asks for, or null to request the full response.
  final ByteRange? range;

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
