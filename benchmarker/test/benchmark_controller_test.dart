import 'dart:async';
import 'dart:io';

import 'package:benchmarker/src/benchmark/benchmark_config.dart';
import 'package:benchmarker/src/benchmark/benchmark_controller.dart';
import 'package:benchmarker/src/benchmark/benchmark_result.dart';
import 'package:benchmarker/src/benchmark/http_client_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_cache_stream/http_cache_stream.dart';

/// Parses a single `bytes=start-end` range against a known total length.
({int start, int end})? _parseRange(String? header, int totalLength) {
  if (header == null || !header.startsWith('bytes=')) return null;
  final parts = header.substring('bytes='.length).split('-');
  if (parts.length != 2) return null;
  final start = int.tryParse(parts[0]);
  final end = int.tryParse(parts[1]) ?? totalLength - 1;
  if (start == null || start < 0 || end >= totalLength || end < start) {
    return null;
  }
  return (start: start, end: end);
}

/// End-to-end coverage of a benchmark run: a real origin server, a real
/// [HttpCacheManager] with its local cache server, and real worker isolates.
void main() {
  final payload = List<int>.generate(256 * 1024, (index) => index % 256);
  late HttpServer origin;
  late Directory cacheDir;
  late BenchmarkController controller;
  late Uri sourceUrl;
  var originRequests = 0;
  final receivedRanges = <String>[];

  setUp(() async {
    originRequests = 0;
    receivedRanges.clear();
    origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(() async {
      await for (final request in origin) {
        originRequests++;
        request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
        if (rangeHeader != null) receivedRanges.add(rangeHeader);
        final range = _parseRange(rangeHeader, payload.length);
        if (range == null) {
          request.response.headers.contentLength = payload.length;
          request.response.add(payload);
        } else {
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.contentLength = range.end - range.start + 1;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes ${range.start}-${range.end}/${payload.length}',
          );
          request.response.add(payload.sublist(range.start, range.end + 1));
        }
        await request.response.close();
      }
    }());
    // Addressed as `localhost` rather than the bound `127.0.0.1` so the source
    // host differs from the cache server's host; otherwise http_cache_stream
    // treats the source URL as an already-encoded cache URL.
    sourceUrl = Uri.parse('http://localhost:${origin.port}/payload.bin');

    cacheDir = await Directory.systemTemp.createTemp('benchmarker_test');
    await HttpCacheManager.init(
      config: GlobalCacheConfig(cacheDirectory: cacheDir),
    );
    controller = BenchmarkController();
  });

  tearDown(() async {
    controller.dispose();
    await HttpCacheManager.instanceOrNull?.dispose();
    await origin.close(force: true);
    if (cacheDir.existsSync()) {
      await cacheDir.delete(recursive: true);
    }
  });

  BenchmarkConfig configFor(
    BenchmarkType type, {
    int workers = 2,
    int total = 4,
    RangePlan? rangePlan,
  }) {
    return BenchmarkConfig(
      sourceUrl: sourceUrl,
      concurrency: workers,
      totalRequests: total,
      type: type,
      clientOption: kHttpClientOptions.first,
      rangePlan: rangePlan,
    );
  }

  test('direct run bypasses the cache server', () async {
    await controller.start(configFor(BenchmarkType.direct));

    expect(controller.phase, BenchmarkPhase.finished);
    expect(controller.targetUrl, sourceUrl);
    expect(controller.showsCacheProgress, isFalse);
    expect(controller.cacheState, isNull);

    final stats = controller.stats!;
    expect(stats.completed, 4);
    expect(stats.succeeded, 4);
    expect(stats.errorCount, 0);
    expect(stats.totalBytes, 4 * payload.length);
    expect(stats.headerTime!.count, 4);
    expect(stats.firstByteTime!.count, 4);
    expect(stats.completionTime!.count, 4);
    expect(originRequests, 4);
    expect(cacheDir.listSync(), isEmpty);
  });

  test('pre-cached run serves every request from the completed cache',
      () async {
    await controller.start(configFor(BenchmarkType.preCached));

    expect(controller.phase, BenchmarkPhase.finished);
    expect(controller.targetUrl, isNot(sourceUrl));
    expect(controller.showsCacheProgress, isTrue);
    expect(controller.cacheState!.isComplete, isTrue);
    expect(controller.cacheState!.sourceLength, payload.length);

    final stats = controller.stats!;
    expect(stats.completed, 4);
    expect(stats.succeeded, 4);
    expect(stats.errorCount, 0);
    expect(stats.totalBytes, 4 * payload.length);
    // One download to pre-cache; the benchmarked requests are served from disk.
    expect(originRequests, 1);
  });

  test('non-cached run wipes the cache and downloads while serving', () async {
    await controller.start(configFor(BenchmarkType.preCached, total: 2));
    expect(controller.stats!.errorCount, 0);
    final requestsAfterPreCache = originRequests;

    await controller.start(configFor(BenchmarkType.nonCached, total: 2));

    expect(controller.phase, BenchmarkPhase.finished);
    final stats = controller.stats!;
    expect(stats.completed, 2);
    expect(stats.succeeded, 2);
    expect(stats.errorCount, 0);
    expect(stats.totalBytes, 2 * payload.length);
    // The cache was wiped, so the source had to be fetched again.
    expect(originRequests, greaterThan(requestsAfterPreCache));
    expect(
      controller.logs.map((entry) => entry.message),
      contains('Cache wiped.'),
    );
  });

  test('direct run requests only the selected byte range', () async {
    const range = ByteRange(1024, 5119);
    await controller.start(
      configFor(BenchmarkType.direct, rangePlan: RangePlan.fixed(range)),
    );

    expect(controller.phase, BenchmarkPhase.finished);
    final stats = controller.stats!;
    expect(stats.completed, 4);
    expect(stats.succeeded, 4);
    expect(stats.errorCount, 0);
    expect(stats.totalBytes, 4 * range.length);
    expect(stats.avgBytesPerRequest, range.length.toDouble());
    expect(
      controller.logs.map((entry) => entry.message),
      contains(contains('Fixed range bytes=1024-5119')),
    );
  });

  test('pre-cached run serves the selected byte range from the cache',
      () async {
    const range = ByteRange(4096, 8191);
    await controller.start(
      configFor(BenchmarkType.preCached, rangePlan: RangePlan.fixed(range)),
    );

    expect(controller.phase, BenchmarkPhase.finished);
    expect(controller.cacheState!.isComplete, isTrue);

    final stats = controller.stats!;
    expect(stats.completed, 4);
    expect(stats.succeeded, 4);
    expect(stats.errorCount, 0);
    expect(stats.totalBytes, 4 * range.length);
    // Only the pre-cache download reached the origin.
    expect(originRequests, 1);
    // A 206 was returned, so no "range ignored" warning was logged.
    expect(
      controller.logs.map((entry) => entry.message),
      isNot(contains(contains('may be ignoring the requested range'))),
    );
  });

  test('sequential windows walk the range once across all workers', () async {
    // The whole payload divided between 8 requests on 2 workers.
    final plan = RangePlan.sequential(ByteRange(0, payload.length - 1), 8);
    await controller.start(
      configFor(BenchmarkType.direct, total: 8, rangePlan: plan),
    );

    expect(controller.phase, BenchmarkPhase.finished);
    final stats = controller.stats!;
    expect(stats.completed, 8);
    expect(stats.succeeded, 8);
    expect(stats.errorCount, 0);
    // Every window is the same size and together they cover the payload once.
    expect(stats.totalBytes, payload.length);
    expect(stats.avgBytesPerRequest, plan.windowSize.toDouble());
    expect(receivedRanges..sort(), [
      for (var sequence = 0; sequence < 8; sequence++)
        plan.windowFor(sequence).header,
    ]..sort());
    expect(
      controller.logs.map((entry) => entry.message),
      contains(contains('Sequential windows: 8 ×')),
    );
  });

  test('sequential windows are served from the cache', () async {
    final plan = RangePlan.sequential(ByteRange(0, payload.length - 1), 4);
    await controller.start(
      configFor(BenchmarkType.preCached, total: 4, rangePlan: plan),
    );

    expect(controller.phase, BenchmarkPhase.finished);
    final stats = controller.stats!;
    expect(stats.completed, 4);
    expect(stats.succeeded, 4);
    expect(stats.errorCount, 0);
    expect(stats.totalBytes, payload.length);
    // Only the pre-cache download reached the origin.
    expect(originRequests, 1);
  });

  test('completed runs are kept, selectable and removable', () async {
    expect(controller.results, isEmpty);
    expect(controller.selectedResult, isNull);

    final before = DateTime.now();
    await controller.start(configFor(BenchmarkType.direct, total: 2));
    await controller.start(configFor(BenchmarkType.direct, total: 2));
    final after = DateTime.now();

    expect(controller.results.map((result) => result.id), [1, 2]);

    final first = controller.results.first;
    expect(first.status, 'Finished');
    expect(first.stats.completed, 2);
    expect(first.config!.type, BenchmarkType.direct);
    expect(first.targetUrl, sourceUrl);
    expect(first.mode, BuildMode.current);
    expect(first.isComplete, isTrue);
    expect(first.startedAt.isBefore(first.endedAt!), isTrue);
    expect(first.startedAt.isBefore(before), isFalse);
    expect(first.endedAt!.isAfter(after), isFalse);
    // The wall clock covers preparation as well as the measured requests.
    expect(
      first.wallDuration!.inMicroseconds,
      greaterThanOrEqualTo(first.stats.elapsed.inMicroseconds),
    );

    // The panel follows the newest run until an older one is picked.
    expect(controller.selectedResultId, 2);
    controller.selectResult(1);
    expect(controller.selectedResultId, 1);

    controller.deleteResult(1);
    expect(controller.results.map((result) => result.id), [2]);
    expect(controller.selectedResultId, 2);

    controller.clearResults();
    expect(controller.results, isEmpty);
    expect(controller.selectedResult, isNull);
  });

  test('a run in flight is selectable before it is recorded', () async {
    final run = controller.start(configFor(BenchmarkType.direct, total: 4));

    // start() sets the phase before its first suspension, so the run is
    // already in flight here.
    expect(controller.phase.isBusy, isTrue);
    final live = controller.liveResult!;
    expect(live.id, 1);
    expect(live.isComplete, isFalse);
    expect(live.wallDuration, isNull);
    expect(live.status, controller.statusLabel);
    expect(controller.results, isEmpty);

    await run;

    expect(controller.liveResult, isNull);
    expect(controller.results.single.id, live.id);
    expect(controller.selectedResult!.isComplete, isTrue);
  });

  test('the worker pool is reused between runs with the same settings',
      () async {
    await controller.start(configFor(BenchmarkType.direct, total: 2));
    await controller.start(configFor(BenchmarkType.direct, total: 2));

    expect(controller.phase, BenchmarkPhase.finished);
    expect(controller.poolSize, 2);
    expect(
      controller.logs.map((entry) => entry.message),
      contains('Reusing 2 warm worker isolates.'),
    );
  });
}
