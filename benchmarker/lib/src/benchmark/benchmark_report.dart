import 'dart:convert';

import '../util/formatting.dart';
import 'benchmark_config.dart';
import 'benchmark_stats.dart';

/// One line describing what each request in [config] asks for.
String describeRangePlan(BenchmarkConfig config) {
  final plan = config.rangePlan;
  if (plan == null) return 'Full response (no Range header)';
  if (plan.isSequential) {
    return 'Sequential windows: ${config.totalRequests} × '
        '${formatBytes(plan.windowSize)} across bytes ${plan.start}-${plan.end}';
  }
  return 'Fixed range bytes=${plan.start}-${plan.end} '
      '(${formatBytes(plan.length)} per request)';
}

/// Renders a run's configuration and results as indented JSON.
String buildJsonReport({
  required BenchmarkStats stats,
  BenchmarkConfig? config,
  Uri? targetUrl,
  String? status,
}) {
  Map<String, Object?> timing(TimingStats? timing) {
    if (timing == null) return {};
    return {
      'samples': timing.count,
      'avg_us': timing.avgMicros.round(),
      'p50_us': timing.p50Micros,
      'p90_us': timing.p90Micros,
      'p99_us': timing.p99Micros,
      'min_us': timing.minMicros,
      'max_us': timing.maxMicros,
    };
  }

  final plan = config?.rangePlan;
  final report = <String, Object?>{
    'source_url': config?.sourceUrl.toString(),
    'target_url': targetUrl?.toString(),
    'cache_type': config?.type.name,
    'cache_type_label': config?.type.label,
    'status': status,
    'concurrency': config?.concurrency,
    'http_client': config?.clientOption.label,
    'range': {
      'mode': plan == null
          ? 'full'
          : plan.isSequential
              ? 'sequential'
              : 'fixed',
      'description': config == null ? null : describeRangePlan(config),
      if (plan != null) ...{
        'start': plan.start,
        'end': plan.end,
        'window_size': plan.windowSize,
        'region_length': plan.length,
        'first_window': plan.windowFor(0).header,
      },
    },
    'requests': {
      'total': stats.totalRequests,
      'completed': stats.completed,
      'verified': stats.succeeded,
      'unverified': stats.unverified,
      'length_mismatches': stats.lengthMismatches,
      'http_errors': stats.httpErrors,
      'failures': stats.failures,
    },
    'throughput': {
      'elapsed_us': stats.elapsed.inMicroseconds,
      'requests_per_second': _round(stats.requestsPerSecond),
      'bytes_per_second': _round(stats.bytesPerSecond),
      'total_bytes': stats.totalBytes,
      'avg_bytes_per_request': _round(stats.avgBytesPerRequest),
    },
    'timings': {
      'response_headers': timing(stats.headerTime),
      'first_byte': timing(stats.firstByteTime),
      'completion': timing(stats.completionTime),
    },
  };

  return const JsonEncoder.withIndent('  ').convert(report);
}

/// Renders a run's configuration and results as an aligned plain-text summary.
String buildTextReport({
  required BenchmarkStats stats,
  BenchmarkConfig? config,
  Uri? targetUrl,
  String? status,
}) {
  final buffer = StringBuffer()
    ..writeln(
      'http_cache_stream benchmark'
      '${config == null ? '' : ' — ${config.type.label}'}',
    );

  void field(String label, String? value) {
    if (value == null) return;
    buffer.writeln('${'$label:'.padRight(13)}$value');
  }

  field('Source', config?.sourceUrl.toString());
  field('Target', targetUrl?.toString());
  field('Client', config?.clientOption.label);
  field(
    'Concurrency',
    config == null ? null : '${config.concurrency} worker isolates',
  );
  field('Range', config == null ? null : describeRangePlan(config));
  field('Status', status);

  buffer
    ..writeln()
    ..writeln(
      '${'Requests:'.padRight(13)}${stats.completed} / ${stats.totalRequests} '
      'completed · ${stats.succeeded} verified, ${stats.unverified} '
      'unverified, ${stats.lengthMismatches} byte mismatch, '
      '${stats.httpErrors} HTTP error, ${stats.failures} failure',
    )
    ..writeln('${'Elapsed:'.padRight(13)}${formatDuration(stats.elapsed)}')
    ..writeln(
      '${'Throughput:'.padRight(13)}'
      '${formatRate(stats.requestsPerSecond, 'req/s')} · '
      '${formatBytesPerSecond(stats.bytesPerSecond)}',
    )
    ..writeln(
      '${'Bytes:'.padRight(13)}${formatBytes(stats.totalBytes)} total · '
      '${formatBytes(stats.avgBytesPerRequest)} per request',
    )
    ..writeln();

  const columns = ['avg', 'p50', 'p90', 'p99', 'min', 'max'];
  const labelWidth = 18;
  const columnWidth = 11;

  buffer.writeln(
    'Timing'.padRight(labelWidth) +
        columns.map((column) => column.padLeft(columnWidth)).join(),
  );

  void timingRow(String label, TimingStats? timing) {
    final values = timing == null
        ? List<String>.filled(columns.length, '—')
        : [
            formatDuration(timing.avg),
            formatDuration(timing.p50),
            formatDuration(timing.p90),
            formatDuration(timing.p99),
            formatDuration(timing.min),
            formatDuration(timing.max),
          ];
    buffer.writeln(
      label.padRight(labelWidth) +
          values.map((value) => value.padLeft(columnWidth)).join(),
    );
  }

  timingRow('Response headers', stats.headerTime);
  timingRow('First byte', stats.firstByteTime);
  timingRow('Completion', stats.completionTime);

  return buffer.toString();
}

/// Keeps floating point values readable in reports.
double _round(double value) => (value * 100).roundToDouble() / 100;
