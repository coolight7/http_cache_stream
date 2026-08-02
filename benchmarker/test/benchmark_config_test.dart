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
