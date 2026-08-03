import 'dart:convert';

import 'package:benchmarker/src/benchmark/benchmark_config.dart';
import 'package:benchmarker/src/benchmark/benchmark_report.dart';
import 'package:benchmarker/src/benchmark/benchmark_stats.dart';
import 'package:benchmarker/src/benchmark/http_client_builder.dart';
import 'package:benchmarker/src/benchmark/worker_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

BenchmarkConfig _config({RangePlan? rangePlan, int total = 4}) {
  return BenchmarkConfig(
    sourceUrl: Uri.parse('https://example.com/file.bin'),
    concurrency: 2,
    totalRequests: total,
    type: BenchmarkType.preCached,
    clientOption: kHttpClientOptions.first,
    rangePlan: rangePlan,
  );
}

BenchmarkStats _stats({int completed = 4}) {
  final accumulator = StatsAccumulator(4);
  for (var i = 0; i < completed; i++) {
    accumulator.add(
      RequestResult(
        workerId: i % 2,
        sequence: i,
        outcome: RequestOutcome.success,
        totalMicros: 1000 + i,
        headerMicros: 100 + i,
        firstByteMicros: 200 + i,
        bytesReceived: 1024,
        contentLength: 1024,
        statusCode: 200,
      ),
    );
  }
  return accumulator.snapshot(const Duration(seconds: 2));
}

void main() {
  group('describeRangePlan', () {
    test('describes a full response', () {
      expect(describeRangePlan(_config()), 'Full response (no Range header)');
    });

    test('describes a fixed range', () {
      expect(
        describeRangePlan(
          _config(rangePlan: RangePlan.fixed(const ByteRange(1024, 5119))),
        ),
        'Fixed range bytes=1024-5119 (4.00 KB per request)',
      );
    });

    test('describes sequential windows', () {
      expect(
        describeRangePlan(
          _config(
            rangePlan: RangePlan.sequential(const ByteRange(0, 4095), 4),
            total: 4,
          ),
        ),
        'Sequential windows: 4 × 1.00 KB across bytes 0-4095',
      );
    });
  });

  group('buildJsonReport', () {
    test('carries the run inputs and results', () {
      final json = jsonDecode(
        buildJsonReport(
          stats: _stats(),
          config: _config(
            rangePlan: RangePlan.sequential(const ByteRange(0, 4095), 4),
          ),
          targetUrl: Uri.parse('http://127.0.0.1:4612/https/example.com/f.bin'),
          status: 'Finished',
        ),
      ) as Map<String, Object?>;

      expect(json['source_url'], 'https://example.com/file.bin');
      expect(json['target_url'], 'http://127.0.0.1:4612/https/example.com/f.bin');
      expect(json['cache_type'], 'preCached');
      expect(json['cache_type_label'], 'Pre-cached');
      expect(json['status'], 'Finished');
      expect(json['concurrency'], 2);
      expect(json['http_client'], kHttpClientOptions.first.label);

      final range = json['range']! as Map<String, Object?>;
      expect(range['mode'], 'sequential');
      expect(range['start'], 0);
      expect(range['end'], 4095);
      expect(range['window_size'], 1024);
      expect(range['first_window'], 'bytes=0-1023');

      final requests = json['requests']! as Map<String, Object?>;
      expect(requests['total'], 4);
      expect(requests['completed'], 4);
      expect(requests['verified'], 4);
      expect(requests['failures'], 0);

      final throughput = json['throughput']! as Map<String, Object?>;
      expect(throughput['elapsed_us'], 2000000);
      expect(throughput['requests_per_second'], 2);
      expect(throughput['total_bytes'], 4096);

      final timings = json['timings']! as Map<String, Object?>;
      final completion = timings['completion']! as Map<String, Object?>;
      expect(completion['samples'], 4);
      expect(completion['min_us'], 1000);
      expect(completion['max_us'], 1003);
    });

    test('marks a full-response run and omits range bounds', () {
      final json = jsonDecode(
        buildJsonReport(stats: _stats(), config: _config()),
      ) as Map<String, Object?>;

      final range = json['range']! as Map<String, Object?>;
      expect(range['mode'], 'full');
      expect(range.containsKey('window_size'), isFalse);
    });

    test('renders without a config', () {
      final json = jsonDecode(buildJsonReport(stats: _stats()))
          as Map<String, Object?>;

      expect(json['source_url'], isNull);
      expect((json['requests']! as Map<String, Object?>)['completed'], 4);
    });
  });

  group('buildTextReport', () {
    test('lists the run inputs above the results', () {
      final text = buildTextReport(
        stats: _stats(),
        config: _config(
          rangePlan: RangePlan.fixed(const ByteRange(1024, 5119)),
        ),
        targetUrl: Uri.parse('http://127.0.0.1:4612/https/example.com/f.bin'),
        status: 'Finished',
      );

      expect(text, contains('http_cache_stream benchmark — Pre-cached'));
      expect(text, contains('Source:      https://example.com/file.bin'));
      expect(text, contains('Target:      http://127.0.0.1:4612/'));
      expect(text, contains('Client:      ${kHttpClientOptions.first.label}'));
      expect(text, contains('Concurrency: 2 worker isolates'));
      expect(text, contains('Range:       Fixed range bytes=1024-5119'));
      expect(text, contains('Status:      Finished'));
      expect(text, contains('Requests:    4 / 4 completed · 4 verified'));
      expect(text, contains('Elapsed:     2.00 s'));
      expect(text, contains('Throughput:  2.00 req/s'));
      expect(text, contains('Bytes:       4.00 KB total'));
    });

    test('aligns the timing table and marks missing series', () {
      final text = buildTextReport(
        stats: const BenchmarkStats.empty(10),
        config: _config(),
        status: 'Idle',
      );

      final lines = text.split('\n');
      final header = lines.firstWhere((line) => line.startsWith('Timing'));
      final completion =
          lines.firstWhere((line) => line.startsWith('Completion'));
      expect(header.length, completion.length);
      expect(completion, contains('—'));
    });
  });
}
