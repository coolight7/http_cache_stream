import 'dart:async';
import 'dart:io';

import 'package:benchmarker/src/benchmark/benchmark_config.dart';
import 'package:benchmarker/src/benchmark/benchmark_controller.dart';
import 'package:benchmarker/src/benchmark/http_client_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_cache_stream/http_cache_stream.dart';

/// End-to-end coverage of a benchmark run: a real origin server, a real
/// [HttpCacheManager] with its local cache server, and real worker isolates.
void main() {
  final payload = List<int>.generate(256 * 1024, (index) => index % 256);
  late HttpServer origin;
  late Directory cacheDir;
  late BenchmarkController controller;
  late Uri sourceUrl;
  var originRequests = 0;

  setUp(() async {
    originRequests = 0;
    origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(() async {
      await for (final request in origin) {
        originRequests++;
        request.response.headers.contentLength = payload.length;
        request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        request.response.add(payload);
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

  BenchmarkConfig configFor(BenchmarkType type, {int workers = 2, int total = 4}) {
    return BenchmarkConfig(
      sourceUrl: sourceUrl,
      concurrency: workers,
      totalRequests: total,
      type: type,
      clientOption: kHttpClientOptions.first,
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
