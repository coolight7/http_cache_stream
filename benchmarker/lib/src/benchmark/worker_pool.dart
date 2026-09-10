import 'dart:async';
import 'dart:isolate';

import 'benchmark_worker.dart';
import 'http_client_builder.dart';
import 'worker_protocol.dart';

/// A pool of long-lived worker isolates.
///
/// Isolates are spawned once and reused across benchmark runs: each holds a
/// single `http.Client` built by the configured [HttpClientBuilder], so
/// connection pools stay warm between runs. The pool is only respawned when the
/// worker count or the client implementation changes.
class WorkerPool {
  WorkerPool._(this.size, this.clientId);

  /// Number of worker isolates in this pool.
  final int size;

  /// Identifier of the [HttpClientOption] the workers were built with.
  final String clientId;

  final ReceivePort _eventPort = ReceivePort();
  final ReceivePort _exitPort = ReceivePort();
  final ReceivePort _errorPort = ReceivePort();
  final StreamController<WorkerEvent> _events =
      StreamController<WorkerEvent>.broadcast();
  final Map<int, Isolate> _isolates = {};
  final Map<int, SendPort> _commandPorts = {};

  bool _disposed = false;

  /// Events emitted by the workers: results, logs, job completions, failures.
  Stream<WorkerEvent> get events => _events.stream;

  /// Worker ids in this pool.
  Iterable<int> get workerIds => List<int>.generate(size, (index) => index);

  /// Spawns [size] isolates and waits until every one has built its client and
  /// reported itself ready.
  static Future<WorkerPool> spawn({
    required int size,
    required HttpClientOption clientOption,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    assert(size > 0);
    final pool = WorkerPool._(size, clientOption.id);
    try {
      await pool._start(clientOption.builder, timeout);
      return pool;
    } catch (_) {
      await pool.dispose();
      rethrow;
    }
  }

  Future<void> _start(HttpClientBuilder builder, Duration timeout) async {
    final ready = Completer<void>();

    _eventPort.listen((message) {
      if (message is! WorkerEvent) return;
      if (message is WorkerReadyEvent) {
        _commandPorts[message.workerId] = message.commandPort;
        if (!ready.isCompleted && _commandPorts.length == size) {
          ready.complete();
        }
        return;
      }
      if (!_events.isClosed) _events.add(message);
    });

    _errorPort.listen((message) {
      // Uncaught isolate errors arrive as [error, stackTrace].
      final description = message is List && message.isNotEmpty
          ? message.first.toString()
          : message.toString();
      if (!ready.isCompleted) {
        ready.completeError(StateError('Worker isolate error: $description'));
      } else if (!_events.isClosed) {
        _events.add(WorkerFatalEvent(-1, 'Isolate error: $description'));
      }
    });

    _exitPort.listen((_) {
      if (_disposed || _events.isClosed) return;
      _events.add(const WorkerFatalEvent(-1, 'A worker isolate exited.'));
    });

    for (var id = 0; id < size; id++) {
      _isolates[id] = await Isolate.spawn(
        benchmarkWorkerMain,
        WorkerBootstrap(
          workerId: id,
          mainPort: _eventPort.sendPort,
          clientBuilder: builder,
        ),
        debugName: 'benchmark-worker-$id',
        onExit: _exitPort.sendPort,
        onError: _errorPort.sendPort,
        errorsAreFatal: false,
      );
    }

    await ready.future.timeout(
      timeout,
      onTimeout: () =>
          throw TimeoutException('Workers did not start in time', timeout),
    );
  }

  /// Sends [command] to a single worker.
  void send(int workerId, WorkerCommand command) {
    _commandPorts[workerId]?.send(command);
  }

  /// Sends [command] to every worker.
  void broadcast(WorkerCommand command) {
    for (final port in _commandPorts.values) {
      port.send(command);
    }
  }

  /// Shuts the workers down and releases the pool's ports.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    broadcast(const ShutdownCommand());
    // Give the isolates a moment to close their clients before killing them.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    for (final isolate in _isolates.values) {
      isolate.kill(priority: Isolate.immediate);
    }
    _isolates.clear();
    _commandPorts.clear();
    _eventPort.close();
    _exitPort.close();
    _errorPort.close();
    await _events.close();
  }
}
