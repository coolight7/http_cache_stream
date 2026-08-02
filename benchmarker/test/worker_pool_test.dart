import 'dart:async';
import 'dart:io';

import 'package:benchmarker/src/benchmark/http_client_builder.dart';
import 'package:benchmarker/src/benchmark/worker_pool.dart';
import 'package:benchmarker/src/benchmark/worker_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

/// Serves a fixed payload with a correct `Content-Length`, plus endpoints for a
/// chunked (length-less) response and an error status.
Future<HttpServer> _startOrigin(List<int> payload) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  unawaited(() async {
    await for (final request in server) {
      switch (request.uri.path) {
        case '/chunked':
          request.response.headers.chunkedTransferEncoding = true;
          request.response.add(payload);
        case '/error':
          request.response.statusCode = HttpStatus.notFound;
        default:
          request.response.headers.contentLength = payload.length;
          request.response.add(payload);
      }
      await request.response.close();
    }
  }());
  return server;
}

void main() {
  final payload = List<int>.generate(64 * 1024, (index) => index % 256);
  late HttpServer origin;
  late WorkerPool pool;

  setUp(() async {
    origin = await _startOrigin(payload);
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
  Future<List<RequestResult>> run(String path, List<int> perWorker) async {
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

  test('the pool reuses its isolates across jobs', () async {
    final first = await run('/payload.bin', [1, 1]);
    final second = await run('/payload.bin', [1, 1]);

    expect(first, hasLength(2));
    expect(second, hasLength(2));
    expect(pool.size, 2);
  });
}
