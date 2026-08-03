import 'package:benchmarker/src/benchmark/benchmark_stats.dart';
import 'package:benchmarker/src/benchmark/worker_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

RequestResult _result({
  required RequestOutcome outcome,
  int totalMicros = 1000,
  int? headerMicros = 100,
  int? firstByteMicros = 200,
  int bytes = 1024,
  int? contentLength = 1024,
}) {
  return RequestResult(
    workerId: 0,
    sequence: 0,
    outcome: outcome,
    totalMicros: totalMicros,
    bytesReceived: bytes,
    contentLength: contentLength,
    headerMicros: headerMicros,
    firstByteMicros: firstByteMicros,
    statusCode: 200,
  );
}

void main() {
  group('TimingStats', () {
    test('returns null without samples', () {
      expect(TimingStats.fromSamples([]), isNull);
    });

    test('computes average, extremes and percentiles', () {
      final stats = TimingStats.fromSamples(
        List<int>.generate(100, (index) => (index + 1) * 10),
      )!;
      expect(stats.count, 100);
      expect(stats.minMicros, 10);
      expect(stats.maxMicros, 1000);
      expect(stats.avgMicros, closeTo(505, 0.001));
      // Percentiles use the nearest rank of the sorted samples.
      expect(stats.p50Micros, 510);
      expect(stats.p90Micros, 900);
      expect(stats.p99Micros, 990);
    });
  });

  group('StatsAccumulator', () {
    test('counts outcomes and bytes', () {
      final accumulator = StatsAccumulator(4)
        ..add(_result(outcome: RequestOutcome.success))
        ..add(_result(outcome: RequestOutcome.unverified, contentLength: null))
        ..add(_result(outcome: RequestOutcome.lengthMismatch, bytes: 512))
        ..add(
          _result(
            outcome: RequestOutcome.failure,
            bytes: 0,
            headerMicros: null,
            firstByteMicros: null,
          ),
        );

      final stats = accumulator.snapshot(const Duration(seconds: 2));
      expect(stats.completed, 4);
      expect(stats.succeeded, 1);
      expect(stats.unverified, 1);
      expect(stats.lengthMismatches, 1);
      expect(stats.failures, 1);
      expect(stats.errorCount, 2);
      expect(stats.totalBytes, 1024 + 1024 + 512);
      expect(stats.requestsPerSecond, closeTo(2, 0.0001));
      expect(stats.bytesPerSecond, closeTo(1280, 0.0001));
    });

    test('excludes failed requests from the timing series', () {
      final accumulator = StatsAccumulator(2)
        ..add(_result(outcome: RequestOutcome.success, totalMicros: 500))
        ..add(
          _result(
            outcome: RequestOutcome.failure,
            totalMicros: 9999,
            headerMicros: null,
            firstByteMicros: null,
          ),
        );

      final stats = accumulator.snapshot(const Duration(seconds: 1));
      expect(stats.completionTime!.count, 1);
      expect(stats.completionTime!.maxMicros, 500);
      expect(stats.headerTime!.count, 1);
      expect(stats.firstByteTime!.count, 1);
    });

    test('reports progress against the configured total', () {
      final accumulator = StatsAccumulator(10)
        ..add(_result(outcome: RequestOutcome.success));
      expect(accumulator.snapshot(Duration.zero).progress, closeTo(0.1, 1e-9));
    });
  });
}
