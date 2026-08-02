import 'dart:isolate';

import 'http_client_builder.dart';

/// The spawn message handed to a worker isolate.
///
/// Only sendable values are carried: [clientBuilder] must be a top-level or
/// static function.
class WorkerBootstrap {
  const WorkerBootstrap({
    required this.workerId,
    required this.mainPort,
    required this.clientBuilder,
  });

  final int workerId;
  final SendPort mainPort;
  final HttpClientBuilder clientBuilder;
}

/// Main isolate -> worker isolate.
sealed class WorkerCommand {
  const WorkerCommand();
}

/// Issue [requestCount] sequential requests against [url].
class RunJobCommand extends WorkerCommand {
  const RunJobCommand({
    required this.jobId,
    required this.url,
    required this.requestCount,
    required this.firstSequence,
    this.rangeHeader,
  });

  final int jobId;

  /// Target URL as a string; [Uri] is parsed inside the worker.
  final String url;

  final int requestCount;

  /// Global index of this job's first request, used to label results.
  final int firstSequence;

  /// Value for the `Range` header, e.g. `bytes=0-1023`. Null requests the full
  /// response.
  final String? rangeHeader;
}

/// Stop the active job early. The worker still reports a [JobDoneEvent].
class CancelJobCommand extends WorkerCommand {
  const CancelJobCommand();
}

/// Close the worker's http client and let the isolate exit.
class ShutdownCommand extends WorkerCommand {
  const ShutdownCommand();
}

/// Worker isolate -> main isolate.
sealed class WorkerEvent {
  const WorkerEvent(this.workerId);

  final int workerId;
}

/// Handshake: the worker is up, its client is built, and it is ready for jobs.
class WorkerReadyEvent extends WorkerEvent {
  const WorkerReadyEvent(super.workerId, this.commandPort);

  final SendPort commandPort;
}

/// A batch of completed request measurements.
class ResultBatchEvent extends WorkerEvent {
  const ResultBatchEvent(super.workerId, this.results);

  final List<RequestResult> results;
}

/// A status or error line for the log view.
class WorkerLogEvent extends WorkerEvent {
  const WorkerLogEvent(super.workerId, this.message, {this.isError = false});

  final String message;
  final bool isError;
}

/// The worker finished (or cancelled) its job.
class JobDoneEvent extends WorkerEvent {
  const JobDoneEvent(super.workerId, this.jobId, {required this.cancelled});

  final int jobId;
  final bool cancelled;
}

/// The isolate died unexpectedly, or threw outside of a request.
class WorkerFatalEvent extends WorkerEvent {
  const WorkerFatalEvent(super.workerId, this.message);

  final String message;
}

/// How a single request ended.
enum RequestOutcome {
  /// 2xx and the received byte count matched `Content-Length`.
  success,

  /// 2xx but the received byte count did not match `Content-Length`.
  lengthMismatch,

  /// 2xx but the response carried no `Content-Length` to verify against.
  unverified,

  /// The response completed with a non-2xx status code.
  httpError,

  /// The request threw before completing.
  failure,
}

/// The measurement for one request.
class RequestResult {
  const RequestResult({
    required this.workerId,
    required this.sequence,
    required this.outcome,
    required this.totalMicros,
    required this.bytesReceived,
    this.statusCode,
    this.headerMicros,
    this.firstByteMicros,
    this.contentLength,
    this.error,
  });

  final int workerId;

  /// Global request index, for log lines.
  final int sequence;

  final RequestOutcome outcome;

  /// Time from request start until the response headers were available.
  final int? headerMicros;

  /// Time from request start until the first response body byte arrived.
  final int? firstByteMicros;

  /// Time from request start until the response body was fully read.
  final int totalMicros;

  final int bytesReceived;
  final int? contentLength;
  final int? statusCode;
  final String? error;

  bool get isSuccess =>
      outcome == RequestOutcome.success || outcome == RequestOutcome.unverified;

  /// A short description used for log lines and error grouping.
  String describeProblem() {
    switch (outcome) {
      case RequestOutcome.success:
        return 'ok';
      case RequestOutcome.unverified:
        return 'no Content-Length to verify against';
      case RequestOutcome.lengthMismatch:
        return 'byte mismatch: received $bytesReceived, '
            'Content-Length $contentLength';
      case RequestOutcome.httpError:
        return 'HTTP $statusCode';
      case RequestOutcome.failure:
        return error ?? 'unknown error';
    }
  }
}
