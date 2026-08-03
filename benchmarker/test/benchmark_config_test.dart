import 'package:benchmarker/src/benchmark/benchmark_config.dart';
import 'package:benchmarker/src/benchmark/http_client_builder.dart';
import 'package:flutter_test/flutter_test.dart';

BenchmarkConfig _config({required int concurrency, required int total}) {
  return BenchmarkConfig(
    sourceUrl: Uri.parse('https://example.com/file.mp3'),
    concurrency: concurrency,
    totalRequests: total,
    type: BenchmarkType.direct,
    clientOption: kHttpClientOptions.first,
  );
}

void main() {
  group('requestDistribution', () {
    test('divides evenly when it can', () {
      expect(
        _config(concurrency: 4, total: 40).requestDistribution(),
        [10, 10, 10, 10],
      );
    });

    test('hands the remainder to the lowest-numbered workers', () {
      expect(
        _config(concurrency: 4, total: 10).requestDistribution(),
        [3, 3, 2, 2],
      );
    });

    test('always sums to the total request count', () {
      for (var concurrency = 1; concurrency <= 16; concurrency++) {
        for (var total = concurrency; total <= 200; total += 7) {
          final distribution =
              _config(concurrency: concurrency, total: total).requestDistribution();
          expect(distribution, hasLength(concurrency));
          expect(distribution.reduce((a, b) => a + b), total);
          expect(distribution.every((count) => count > 0), isTrue);
        }
      }
    });
  });

  group('ByteRange.fromFractions', () {
    test('resolves fractions to an inclusive byte range', () {
      final range = ByteRange.fromFractions(0.25, 0.5, 1000)!;
      expect(range.start, 250);
      expect(range.end, 499);
      expect(range.length, 250);
      expect(range.header, 'bytes=250-499');
    });

    test('spans the whole source for a full selection', () {
      expect(ByteRange.fromFractions(0, 1, 1000), const ByteRange(0, 999));
      // Rounds up to the last byte, which is still the whole body.
      expect(ByteRange.fromFractions(0, 0.9999, 1000), const ByteRange(0, 999));
    });

    test('returns null for an empty selection', () {
      expect(ByteRange.fromFractions(0.5, 0.5, 1000), isNull);
      expect(ByteRange.isEmptySelection(0.5, 0.5, 1000), isTrue);
      expect(ByteRange.isEmptySelection(0, 1, 1000), isFalse);
      expect(ByteRange.isEmptySelection(0, 0.9999, 1000), isFalse);
    });

    test('keeps the tail range within the source', () {
      final range = ByteRange.fromFractions(0.5, 1, 1001)!;
      expect(range.start, 500);
      expect(range.end, 1000);
      expect(range.length, 501);
    });

    test('returns null when the content length is unknown or zero', () {
      expect(ByteRange.fromFractions(0.1, 0.2, 0), isNull);
      expect(ByteRange.resolveBounds(0.1, 0.2, 0), isNull);
    });
  });

  group('RangePlan', () {
    test('a fixed plan gives every request the same window', () {
      final plan = RangePlan.fixed(const ByteRange(100, 199));

      expect(plan.windowSize, 100);
      expect(plan.isSequential, isFalse);
      for (var sequence = 0; sequence < 5; sequence++) {
        expect(plan.windowFor(sequence), const ByteRange(100, 199));
      }
    });

    test('a sequential plan tiles the range back to back', () {
      final plan = RangePlan.sequential(const ByteRange(0, 999), 4);

      expect(plan.windowSize, 250);
      expect(plan.isSequential, isTrue);
      expect(plan.windowFor(0), const ByteRange(0, 249));
      expect(plan.windowFor(1), const ByteRange(250, 499));
      expect(plan.windowFor(2), const ByteRange(500, 749));
      expect(plan.windowFor(3), const ByteRange(750, 999));
    });

    test('windows start where the previous one ended', () {
      const requestCount = 7;
      final plan = RangePlan.sequential(const ByteRange(4096, 20479), requestCount);

      // Every window but the last starts directly after its predecessor; the
      // last slides back to end on the final byte, so it may overlap.
      for (var sequence = 1; sequence < requestCount - 1; sequence++) {
        final previous = plan.windowFor(sequence - 1);
        final current = plan.windowFor(sequence);
        expect(
          current.start,
          previous.end + 1,
          reason: 'window $sequence should follow window ${sequence - 1}',
        );
      }

      final last = plan.windowFor(requestCount - 1);
      final secondToLast = plan.windowFor(requestCount - 2);
      expect(last.end, 20479);
      expect(last.length, plan.windowSize);
      expect(last.start, lessThanOrEqualTo(secondToLast.end + 1));
      expect(last.start, greaterThan(secondToLast.start));
    });

    test('every window is the same size, the last sliding back to the end', () {
      // 1000 bytes over 3 requests does not divide evenly.
      final plan = RangePlan.sequential(const ByteRange(0, 999), 3);

      expect(plan.windowSize, 334);
      expect(plan.windowFor(0), const ByteRange(0, 333));
      expect(plan.windowFor(1), const ByteRange(334, 667));
      // Slid back so it stays 334 bytes and still ends on the last byte.
      expect(plan.windowFor(2), const ByteRange(666, 999));
      for (var sequence = 0; sequence < 3; sequence++) {
        expect(plan.windowFor(sequence).length, plan.windowSize);
      }
    });

    test('the windows cover the whole selected range', () {
      for (final requestCount in [1, 2, 3, 7, 16, 100]) {
        final plan = RangePlan.sequential(const ByteRange(500, 1499), requestCount);
        expect(plan.windowFor(0).start, 500);
        expect(plan.windowFor(requestCount - 1).end, 1499);
      }
    });

    test('a single request covers the entire range', () {
      final plan = RangePlan.sequential(const ByteRange(0, 999), 1);

      expect(plan.windowSize, 1000);
      expect(plan.isSequential, isFalse);
      expect(plan.windowFor(0), const ByteRange(0, 999));
    });

    test('sequences past the end resolve to the final window', () {
      final plan = RangePlan.sequential(const ByteRange(0, 999), 4);

      expect(plan.windowFor(4), const ByteRange(750, 999));
      expect(plan.windowFor(99), const ByteRange(750, 999));
    });

    test('more requests than bytes still produce valid windows', () {
      final plan = RangePlan.sequential(const ByteRange(0, 9), 40);

      expect(plan.windowSize, 1);
      expect(plan.windowFor(0), const ByteRange(0, 0));
      expect(plan.windowFor(9), const ByteRange(9, 9));
      expect(plan.windowFor(39), const ByteRange(9, 9));
    });
  });

  group('validate', () {
    test('accepts a well-formed config', () {
      expect(
        BenchmarkConfig.validate(
          url: 'https://example.com/file.mp3',
          concurrency: 4,
          totalRequests: 40,
        ),
        isNull,
      );
    });

    test('rejects a malformed or non-http url', () {
      expect(
        BenchmarkConfig.validate(url: '', concurrency: 1, totalRequests: 1),
        isNotNull,
      );
      expect(
        BenchmarkConfig.validate(
          url: 'not a url',
          concurrency: 1,
          totalRequests: 1,
        ),
        isNotNull,
      );
      expect(
        BenchmarkConfig.validate(
          url: 'ftp://example.com/file.mp3',
          concurrency: 1,
          totalRequests: 1,
        ),
        isNotNull,
      );
    });

    test('rejects out-of-range counts', () {
      expect(
        BenchmarkConfig.validate(
          url: 'https://example.com/f',
          concurrency: 0,
          totalRequests: 10,
        ),
        isNotNull,
      );
      expect(
        BenchmarkConfig.validate(
          url: 'https://example.com/f',
          concurrency: 4,
          totalRequests: 2,
        ),
        isNotNull,
      );
    });
  });
}
