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

    test('returns null for a full selection so no Range header is sent', () {
      expect(ByteRange.fromFractions(0, 1, 1000), isNull);
      // Rounds up to the last byte, which is still the whole body.
      expect(ByteRange.fromFractions(0, 0.9999, 1000), isNull);
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
