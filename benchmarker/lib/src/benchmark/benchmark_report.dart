import 'dart:convert';

import '../util/formatting.dart';
import 'benchmark_config.dart';
import 'benchmark_result.dart';
import 'benchmark_stats.dart';

const JsonEncoder _encoder = JsonEncoder.withIndent('  ');

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
String buildJsonReport(BenchmarkResult result) =>
    _encoder.convert(buildReportMap(result));

/// Renders every run as a JSON list, oldest first.
String buildJsonReportList(Iterable<BenchmarkResult> results) =>
    _encoder.convert([for (final result in results) buildReportMap(result)]);

/// Builds the JSON structure describing a single run.
Map<String, Object?> buildReportMap(BenchmarkResult result) {
  final stats = result.stats;
  final config = result.config;

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
  return <String, Object?>{
    'run_id': result.id,
    'source_url': config?.sourceUrl.toString(),
    'target_url': result.targetUrl?.toString(),
    'cache_type': config?.type.name,
    'cache_type_label': config?.type.label,
    'status': result.status,
    'build_mode': result.mode.name,
    'started_at': result.startedAt.toIso8601String(),
    'ended_at': result.endedAt?.toIso8601String(),
    'wall_duration_us': result.wallDuration?.inMicroseconds,
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
}

/// Renders a run's configuration and results as an aligned plain-text summary.
String buildTextReport(BenchmarkResult result) {
  final stats = result.stats;
  final config = result.config;
  final buffer = StringBuffer()
    ..writeln(
      'http_cache_stream benchmark'
      '${config == null ? '' : ' — ${config.type.label}'} (run #${result.id})',
    );

  void field(String label, String? value) {
    if (value == null) return;
    buffer.writeln('${'$label:'.padRight(13)}$value');
  }

  field('Source', config?.sourceUrl.toString());
  field('Target', result.targetUrl?.toString());
  field('Client', config?.clientOption.label);
  field(
    'Concurrency',
    config == null ? null : '${config.concurrency} worker isolates',
  );
  field('Range', config == null ? null : describeRangePlan(config));
  field('Status', result.status);
  field('Mode', '${result.mode.label} build');
  field('Started', formatTimestamp(result.startedAt));
  field(
    'Ended',
    result.endedAt == null ? null : formatTimestamp(result.endedAt!),
  );
  field(
    'Duration',
    result.wallDuration == null ? null : formatDuration(result.wallDuration!),
  );

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
