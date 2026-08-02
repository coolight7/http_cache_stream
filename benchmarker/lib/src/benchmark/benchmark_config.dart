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

/// A single benchmark run's inputs.
class BenchmarkConfig {
  const BenchmarkConfig({
    required this.sourceUrl,
    required this.concurrency,
    required this.totalRequests,
    required this.type,
    required this.clientOption,
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
