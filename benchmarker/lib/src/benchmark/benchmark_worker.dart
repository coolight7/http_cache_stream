import 'dart:async';
import 'dart:isolate';

import 'package:http/http.dart' as http;

import 'worker_protocol.dart';

/// Entry point of a benchmark worker isolate.
///
/// The isolate is long-lived: it builds one [http.Client] on startup, keeps it
/// for the lifetime of the isolate, and processes jobs until it is told to
/// shut down.
Future<void> benchmarkWorkerMain(WorkerBootstrap bootstrap) async {
  final worker = _BenchmarkWorker(bootstrap);
  await worker.serve();
}

/// How many results are buffered before being sent to the main isolate.
const int _maxBatchSize = 32;

/// How long results are buffered before being sent to the main isolate.
const Duration _maxBatchAge = Duration(milliseconds: 100);

class _BenchmarkWorker {
  _BenchmarkWorker(this._bootstrap);

  final WorkerBootstrap _bootstrap;
  final ReceivePort _commandPort = ReceivePort();
  final List<RequestResult> _pending = [];
  final Stopwatch _batchClock = Stopwatch();

  late final http.Client _client;
  final Completer<void> _shutdown = Completer<void>();
  bool _cancelRequested = false;
  bool _busy = false;

  int get _id => _bootstrap.workerId;

  Future<void> serve() async {
    try {
      _client = _bootstrap.clientBuilder();
    } catch (e) {
      _send(WorkerFatalEvent(_id, 'Failed to build http client: $e'));
      _commandPort.close();
      return;
    }

    _commandPort.listen(_onCommand);
    _send(WorkerReadyEvent(_id, _commandPort.sendPort));

    await _shutdown.future;

    try {
      _client.close();
    } catch (_) {
      // The client is being torn down; nothing useful to report.
    }
    _commandPort.close();
  }

  void _onCommand(Object? message) {
    switch (message) {
      case RunJobCommand job:
        if (_busy) {
          _send(
            WorkerLogEvent(
              _id,
              'Worker $_id received a job while still running one; ignored.',
              isError: true,
            ),
          );
          return;
        }
        unawaited(_runJob(job));
      case CancelJobCommand():
        _cancelRequested = true;
      case ShutdownCommand():
        _cancelRequested = true;
        if (!_shutdown.isCompleted) _shutdown.complete();
      default:
        _send(
          WorkerLogEvent(
            _id,
            'Worker $_id received unknown message: $message',
            isError: true,
          ),
        );
    }
  }

  Future<void> _runJob(RunJobCommand job) async {
    _busy = true;
    _cancelRequested = false;
    _batchClock
      ..reset()
      ..start();

    final uri = Uri.parse(job.url);
    try {
      for (var i = 0; i < job.requestCount; i++) {
        if (_cancelRequested) break;
        final result = await _executeRequest(uri, job.firstSequence + i);
        if (result == null) break; // Abandoned mid-response by a cancel.
        _pending.add(result);
        if (_pending.length >= _maxBatchSize ||
            _batchClock.elapsed >= _maxBatchAge) {
          _flush();
        }
      }
    } catch (e, stack) {
      _send(WorkerFatalEvent(_id, 'Worker $_id job failed: $e\n$stack'));
    } finally {
      _flush();
      _batchClock.stop();
      _busy = false;
      _send(JobDoneEvent(_id, job.jobId, cancelled: _cancelRequested));
    }
  }

  /// Issues one GET and measures header time, first-byte time, and completion
  /// time, verifying the received byte count against `Content-Length`.
  ///
  /// Returns null if the request was abandoned by a cancel before the response
  /// was fully read; such a request is not a measurement and is not reported.
  Future<RequestResult?> _executeRequest(Uri uri, int sequence) async {
    final stopwatch = Stopwatch()..start();
    int? headerMicros;
    int? firstByteMicros;
    var bytesReceived = 0;

    try {
      final response = await _client.send(http.Request('GET', uri));
      headerMicros = stopwatch.elapsedMicroseconds;

      await for (final chunk in response.stream) {
        if (chunk.isNotEmpty) {
          firstByteMicros ??= stopwatch.elapsedMicroseconds;
          bytesReceived += chunk.length;
        }
        // Breaking cancels the subscription, which closes the connection.
        if (_cancelRequested) return null;
      }
      stopwatch.stop();

      final contentLength = response.contentLength;
      final RequestOutcome outcome;
      if (response.statusCode < 200 || response.statusCode >= 300) {
        outcome = RequestOutcome.httpError;
      } else if (contentLength == null) {
        outcome = RequestOutcome.unverified;
      } else if (contentLength != bytesReceived) {
        outcome = RequestOutcome.lengthMismatch;
      } else {
        outcome = RequestOutcome.success;
      }

      return RequestResult(
        workerId: _id,
        sequence: sequence,
        outcome: outcome,
        headerMicros: headerMicros,
        firstByteMicros: firstByteMicros,
        totalMicros: stopwatch.elapsedMicroseconds,
        bytesReceived: bytesReceived,
        contentLength: contentLength,
        statusCode: response.statusCode,
      );
    } catch (e) {
      stopwatch.stop();
      // A cancel tears down in-flight connections; that is not a real failure.
      if (_cancelRequested) return null;
      return RequestResult(
        workerId: _id,
        sequence: sequence,
        outcome: RequestOutcome.failure,
        headerMicros: headerMicros,
        firstByteMicros: firstByteMicros,
        totalMicros: stopwatch.elapsedMicroseconds,
        bytesReceived: bytesReceived,
        error: '$e',
      );
    }
  }

  void _flush() {
    if (_pending.isEmpty) return;
    _send(ResultBatchEvent(_id, List<RequestResult>.of(_pending)));
    _pending.clear();
    _batchClock
      ..reset()
      ..start();
  }

  void _send(WorkerEvent event) => _bootstrap.mainPort.send(event);
}
