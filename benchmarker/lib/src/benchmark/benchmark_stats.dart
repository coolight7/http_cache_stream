import 'worker_protocol.dart';

/// Summary of a single timing series, in microseconds.
class TimingStats {
  const TimingStats({
    required this.count,
    required this.avgMicros,
    required this.minMicros,
    required this.maxMicros,
    required this.p50Micros,
    required this.p90Micros,
    required this.p99Micros,
  });

  final int count;
  final double avgMicros;
  final int minMicros;
  final int maxMicros;
  final int p50Micros;
  final int p90Micros;
  final int p99Micros;

  Duration get avg => Duration(microseconds: avgMicros.round());
  Duration get min => Duration(microseconds: minMicros);
  Duration get max => Duration(microseconds: maxMicros);
  Duration get p50 => Duration(microseconds: p50Micros);
  Duration get p90 => Duration(microseconds: p90Micros);
  Duration get p99 => Duration(microseconds: p99Micros);

  /// Builds a summary from an unsorted list of microsecond samples.
  /// Returns null when there are no samples.
  static TimingStats? fromSamples(List<int> samples) {
    if (samples.isEmpty) return null;
    final sorted = List<int>.of(samples)..sort();
    var sum = 0;
    for (final value in sorted) {
      sum += value;
    }
    return TimingStats(
      count: sorted.length,
      avgMicros: sum / sorted.length,
      minMicros: sorted.first,
      maxMicros: sorted.last,
      p50Micros: _percentile(sorted, 0.50),
      p90Micros: _percentile(sorted, 0.90),
      p99Micros: _percentile(sorted, 0.99),
    );
  }

  static int _percentile(List<int> sorted, double fraction) {
    final index = ((sorted.length - 1) * fraction).round();
    return sorted[index.clamp(0, sorted.length - 1)];
  }
}

/// An immutable snapshot of a benchmark run, safe to hand to the UI.
class BenchmarkStats {
  const BenchmarkStats({
    required this.totalRequests,
    required this.completed,
    required this.succeeded,
    required this.lengthMismatches,
    required this.unverified,
    required this.httpErrors,
    required this.failures,
    required this.totalBytes,
    required this.elapsed,
    required this.headerTime,
    required this.firstByteTime,
    required this.completionTime,
  });

  const BenchmarkStats.empty(this.totalRequests)
      : completed = 0,
        succeeded = 0,
        lengthMismatches = 0,
        unverified = 0,
        httpErrors = 0,
        failures = 0,
        totalBytes = 0,
        elapsed = Duration.zero,
        headerTime = null,
        firstByteTime = null,
        completionTime = null;

  /// Requests the run was configured to issue.
  final int totalRequests;

  /// Requests that have reported a result so far.
  final int completed;

  /// Requests that returned 2xx with a byte count matching `Content-Length`.
  final int succeeded;

  /// Requests that returned 2xx but whose byte count did not match.
  final int lengthMismatches;

  /// Requests that returned 2xx without a `Content-Length` to verify against.
  final int unverified;

  /// Requests that completed with a non-2xx status.
  final int httpErrors;

  /// Requests that threw before completing.
  final int failures;

  /// Total response body bytes received.
  final int totalBytes;

  /// Wall-clock time since the run started.
  final Duration elapsed;

  /// Time until the response headers were available.
  final TimingStats? headerTime;

  /// Time until the first response body byte arrived.
  final TimingStats? firstByteTime;

  /// Time until the response body was fully read.
  final TimingStats? completionTime;

  /// Requests that neither succeeded nor were merely unverified.
  int get errorCount => lengthMismatches + httpErrors + failures;

  double get progress =>
      totalRequests == 0 ? 0 : (completed / totalRequests).clamp(0.0, 1.0);

  /// Completed requests per second of wall-clock time.
  double get requestsPerSecond {
    final seconds = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    if (seconds <= 0) return 0;
    return completed / seconds;
  }

  /// Aggregate throughput across all workers.
  double get bytesPerSecond {
    final seconds = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    if (seconds <= 0) return 0;
    return totalBytes / seconds;
  }

  /// Mean response size.
  double get avgBytesPerRequest => completed == 0 ? 0 : totalBytes / completed;
}

/// Accumulates [RequestResult]s streamed back from the workers and produces
/// [BenchmarkStats] snapshots on demand.
class StatsAccumulator {
  StatsAccumulator(this.totalRequests);

  final int totalRequests;

  final List<int> _headerMicros = [];
  final List<int> _firstByteMicros = [];
  final List<int> _completionMicros = [];

  int _completed = 0;
  int _succeeded = 0;
  int _lengthMismatches = 0;
  int _unverified = 0;
  int _httpErrors = 0;
  int _failures = 0;
  int _totalBytes = 0;

  int get completed => _completed;

  void add(RequestResult result) {
    _completed++;
    _totalBytes += result.bytesReceived;

    switch (result.outcome) {
      case RequestOutcome.success:
        _succeeded++;
      case RequestOutcome.lengthMismatch:
        _lengthMismatches++;
      case RequestOutcome.unverified:
        _unverified++;
      case RequestOutcome.httpError:
        _httpErrors++;
      case RequestOutcome.failure:
        _failures++;
    }

    // Timings are only meaningful for requests that actually delivered a
    // response, so failed requests are excluded from the latency series.
    if (result.outcome == RequestOutcome.failure) return;
    if (result.headerMicros case final micros?) _headerMicros.add(micros);
    if (result.firstByteMicros case final micros?) {
      _firstByteMicros.add(micros);
    }
    _completionMicros.add(result.totalMicros);
  }

  BenchmarkStats snapshot(Duration elapsed) {
    return BenchmarkStats(
      totalRequests: totalRequests,
      completed: _completed,
      succeeded: _succeeded,
      lengthMismatches: _lengthMismatches,
      unverified: _unverified,
      httpErrors: _httpErrors,
      failures: _failures,
      totalBytes: _totalBytes,
      elapsed: elapsed,
      headerTime: TimingStats.fromSamples(_headerMicros),
      firstByteTime: TimingStats.fromSamples(_firstByteMicros),
      completionTime: TimingStats.fromSamples(_completionMicros),
    );
  }
}
