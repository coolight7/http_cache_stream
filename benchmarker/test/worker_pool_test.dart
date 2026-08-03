import 'dart:async';
import 'dart:io';

import 'package:benchmarker/src/benchmark/benchmark_config.dart';
import 'package:benchmarker/src/benchmark/http_client_builder.dart';
import 'package:benchmarker/src/benchmark/worker_pool.dart';
import 'package:benchmarker/src/benchmark/worker_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

/// Serves a fixed payload with a correct `Content-Length`, honoring single
/// byte ranges, plus endpoints for a chunked (length-less) response and an
/// error status.
Future<HttpServer> _startOrigin(
  List<int> payload,
  List<String> receivedRanges,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  unawaited(() async {
    await for (final request in server) {
      final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
      if (rangeHeader != null) receivedRanges.add(rangeHeader);
      switch (request.uri.path) {
        case '/chunked':
          request.response.headers.chunkedTransferEncoding = true;
          request.response.add(payload);
        case '/error':
          request.response.statusCode = HttpStatus.notFound;
        default:
          final range = _parseRange(rangeHeader, payload.length);
          if (range == null) {
            request.response.headers.contentLength = payload.length;
            request.response.add(payload);
          } else {
            request.response.statusCode = HttpStatus.partialContent;
            request.response.headers.contentLength =
                range.end - range.start + 1;
            request.response.headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes ${range.start}-${range.end}/${payload.length}',
            );
            request.response.add(payload.sublist(range.start, range.end + 1));
          }
      }
      await request.response.close();
    }
  }());
  return server;
}

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

void main() {
  final payload = List<int>.generate(64 * 1024, (index) => index % 256);
  final receivedRanges = <String>[];
  late HttpServer origin;
  late WorkerPool pool;

  setUp(() async {
    receivedRanges.clear();
    origin = await _startOrigin(payload, receivedRanges);
    pool = await WorkerPool.spawn(
      size: 2,
      clientOption: kHttpClientOptions.first,
    );
  });

  tearDown(() async {
    await pool.dispose();
    await origin.close(force: true);
  });

  /// Dispatches [perWorker] requests to each worker and collects every result.
  Future<List<RequestResult>> run(
    String path,
    List<int> perWorker, {
    RangePlan? rangePlan,
  }) async {
    final results = <RequestResult>[];
    final done = <int>{};
    final completer = Completer<void>();
    final outstanding = <int>{
      for (var id = 0; id < perWorker.length; id++)
        if (perWorker[id] > 0) id,
    };

    final subscription = pool.events.listen((event) {
      if (event is ResultBatchEvent) {
        results.addAll(event.results);
      } else if (event is JobDoneEvent) {
        done.add(event.workerId);
        if (done.containsAll(outstanding) && !completer.isCompleted) {
          completer.complete();
        }
      }
    });

    var sequence = 0;
    for (var id = 0; id < perWorker.length; id++) {
      if (perWorker[id] == 0) continue;
      pool.send(
        id,
        RunJobCommand(
          jobId: 1,
          url: 'http://${origin.address.host}:${origin.port}$path',
          requestCount: perWorker[id],
          firstSequence: sequence,
          rangePlan: rangePlan,
        ),
      );
      sequence += perWorker[id];
    }

    await completer.future.timeout(const Duration(seconds: 30));
    await subscription.cancel();
    return results;
  }

  test('workers report one verified result per request', () async {
    final results = await run('/payload.bin', [3, 2]);

    expect(results, hasLength(5));
    expect(
      results.every((result) => result.outcome == RequestOutcome.success),
      isTrue,
      reason: results.map((result) => result.describeProblem()).join(', '),
    );
    expect(
      results.every((result) => result.bytesReceived == payload.length),
      isTrue,
    );
    expect(results.map((result) => result.workerId).toSet(), {0, 1});
    expect(results.map((result) => result.sequence).toSet(), {0, 1, 2, 3, 4});
    for (final result in results) {
      expect(result.headerMicros, isNotNull);
      expect(result.firstByteMicros, isNotNull);
      expect(result.totalMicros, greaterThanOrEqualTo(result.headerMicros!));
      expect(result.contentLength, payload.length);
    }
  });

  test('a response without Content-Length is reported as unverified', () async {
    final results = await run('/chunked', [1, 0]);

    expect(results, hasLength(1));
    expect(results.single.outcome, RequestOutcome.unverified);
    expect(results.single.bytesReceived, payload.length);
    expect(results.single.contentLength, isNull);
  });

  test('a non-2xx response is reported as an http error', () async {
    final results = await run('/error', [1, 0]);

    expect(results, hasLength(1));
    expect(results.single.outcome, RequestOutcome.httpError);
    expect(results.single.statusCode, HttpStatus.notFound);
  });

  test('a fixed range plan yields a verified partial response', () async {
    final results = await run(
      '/payload.bin',
      [2, 1],
      rangePlan: RangePlan.fixed(const ByteRange(1024, 5119)),
    );

    expect(results, hasLength(3));
    for (final result in results) {
      expect(result.statusCode, HttpStatus.partialContent);
      expect(result.outcome, RequestOutcome.success);
      expect(result.bytesReceived, 4096);
      expect(result.contentLength, 4096);
    }
    expect(receivedRanges, everyElement('bytes=1024-5119'));
  });

  test('a sequential plan walks the range one window per request', () async {
    // 8 KB across 4 requests: four back-to-back 2 KB windows.
    final plan = RangePlan.sequential(const ByteRange(0, 8191), 4);
    final results = await run('/payload.bin', [2, 2], rangePlan: plan);

    expect(plan.windowSize, 2048);
    expect(results, hasLength(4));
    for (final result in results) {
      expect(result.statusCode, HttpStatus.partialContent);
      expect(result.outcome, RequestOutcome.success);
      expect(result.bytesReceived, 2048);
    }
    // Each request asked for a distinct, contiguous window; the workers split
    // the sequence between them.
    expect(receivedRanges..sort(), [
      'bytes=0-2047',
      'bytes=2048-4095',
      'bytes=4096-6143',
      'bytes=6144-8191',
    ]);
  });

  test('the pool reuses its isolates across jobs', () async {
    final first = await run('/payload.bin', [1, 1]);
    final second = await run('/payload.bin', [1, 1]);

    expect(first, hasLength(2));
    expect(second, hasLength(2));
    expect(pool.size, 2);
  });
}
