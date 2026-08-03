import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http_cache_stream/http_cache_stream.dart';

import '../util/formatting.dart';
import 'benchmark_config.dart';
import 'benchmark_log.dart';
import 'benchmark_report.dart';
import 'benchmark_result.dart';
import 'benchmark_stats.dart';
import 'worker_pool.dart';
import 'worker_protocol.dart';

enum BenchmarkPhase {
  idle('Idle'),
  preparing('Preparing…'),
  running('Running'),
  cancelling('Cancelling…'),
  finished('Finished'),
  cancelled('Cancelled'),
  failed('Failed');

  const BenchmarkPhase(this.label);

  /// Human-readable name of the phase.
  final String label;

  bool get isBusy =>
      this == BenchmarkPhase.preparing ||
      this == BenchmarkPhase.running ||
      this == BenchmarkPhase.cancelling;

  /// Whether a run in this phase is over and can be recorded.
  bool get isTerminal =>
      this == BenchmarkPhase.finished ||
      this == BenchmarkPhase.cancelled ||
      this == BenchmarkPhase.failed;
}

/// Drives a benchmark run: prepares the cache, dispatches work to the isolate
/// pool, aggregates the results, and exposes everything the UI renders.
class BenchmarkController extends ChangeNotifier {
  /// How often the UI is refreshed while a run is in progress.
  static const Duration refreshInterval = Duration(milliseconds: 250);

  /// Maximum number of log lines retained.
  static const int maxLogEntries = 500;

  final List<LogEntry> _logs = [];
  final Map<String, int> _problemCounts = {};
  final Stopwatch _runClock = Stopwatch();

  /// Completed runs of this session, oldest first.
  final List<BenchmarkResult> _results = [];

  WorkerPool? _pool;
  StreamSubscription<WorkerEvent>? _poolEvents;
  HttpCacheStream? _cacheStream;
  StreamSubscription<CacheState>? _cacheStateEvents;
  StatsAccumulator? _accumulator;
  Completer<void>? _runCompleter;
  Timer? _ticker;

  final Set<int> _outstandingWorkers = {};
  int _jobId = 0;
  int _runId = 0;
  bool _cancelRequested = false;
  bool _dirty = false;
  bool _warnedUnverified = false;
  bool _warnedRangeIgnored = false;
  bool _disposed = false;

  BenchmarkPhase _phase = BenchmarkPhase.idle;
  BenchmarkConfig? _config;
  BenchmarkStats? _stats;
  CacheState? _cacheState;
  Uri? _targetUrl;
  DateTime? _startedAt;

  /// Id of the recorded result the UI is pinned to, or null while it follows
  /// the run in flight.
  int? _selectedResultId;

  BenchmarkPhase get phase => _phase;

  /// The config of the current or most recent run.
  BenchmarkConfig? get config => _config;

  /// The latest statistics snapshot, or null before the first run.
  BenchmarkStats? get stats => _stats;

  /// Latest cache state for the URL under test. Null for direct runs.
  CacheState? get cacheState => _cacheState;

  /// The URL the workers are hitting: the cache URL, or the source URL for
  /// direct runs.
  Uri? get targetUrl => _targetUrl;

  /// Whether cache progress applies to the current run.
  bool get showsCacheProgress => _config?.type.usesCacheServer ?? false;

  List<LogEntry> get logs => List.unmodifiable(_logs);

  /// Number of live worker isolates, or 0 when no pool is spawned.
  int get poolSize => _pool?.size ?? 0;

  /// Status line of the current phase, e.g. `Running · 4 workers`.
  String get statusLabel => _phase == BenchmarkPhase.running
      ? '${_phase.label} · $poolSize workers'
      : _phase.label;

  /// Every completed run of this session, oldest first.
  List<BenchmarkResult> get results => List.unmodifiable(_results);

  /// The run in flight, or null when no run is in progress.
  BenchmarkResult? get liveResult {
    final stats = _stats;
    final startedAt = _startedAt;
    if (!_phase.isBusy || stats == null || startedAt == null) return null;
    return BenchmarkResult(
      id: _runId,
      stats: stats,
      status: statusLabel,
      startedAt: startedAt,
      config: _config,
      targetUrl: _targetUrl,
    );
  }

  /// The result the UI shows: the pinned one from the history, or the run in
  /// flight when nothing is pinned.
  BenchmarkResult? get selectedResult {
    final id = _selectedResultId;
    if (id != null) {
      for (final result in _results) {
        if (result.id == id) return result;
      }
    }
    return liveResult;
  }

  /// Id of the result the UI shows, or null when there is nothing to show.
  int? get selectedResultId => selectedResult?.id;

  /// Pins the history entry with [id]. Selecting the run in flight, or an id
  /// that is no longer in the history, follows the live run again.
  void selectResult(int? id) {
    _selectedResultId =
        id == null || (liveResult != null && id == liveResult!.id) ? null : id;
    notifyListeners();
  }

  /// Removes a single run from the history.
  ///
  /// A run in flight is never recorded yet, so it cannot be deleted.
  void deleteResult(int id) {
    final removed = _results.indexWhere((result) => result.id == id);
    if (removed < 0) return;
    _results.removeAt(removed);
    if (_selectedResultId == id) {
      // Fall back to the neighbouring run, or to the live run when the history
      // is empty.
      final next = removed < _results.length ? removed : _results.length - 1;
      _selectedResultId = next < 0 ? null : _results[next].id;
    }
    notifyListeners();
  }

  /// Drops every recorded run. The run in flight, if any, keeps going.
  void clearResults() {
    if (_results.isEmpty) return;
    _results.clear();
    _selectedResultId = null;
    notifyListeners();
  }

  /// Starts a run. Does nothing when a run is already in progress.
  Future<void> start(BenchmarkConfig config) async {
    if (_phase.isBusy || _disposed) return;

    _config = config;
    _cancelRequested = false;
    _warnedUnverified = false;
    _warnedRangeIgnored = false;
    _problemCounts.clear();
    _accumulator = StatsAccumulator(config.totalRequests);
    _stats = BenchmarkStats.empty(config.totalRequests);
    _cacheState = null;
    _targetUrl = null;
    _startedAt = DateTime.now();
    // The stats panel follows the new run rather than whatever the user was
    // reading in the history.
    _selectedResultId = null;
    _runId++;
    _runClock
      ..reset()
      ..stop();

    _log('── Run #$_runId · ${config.type.label}: ${config.sourceUrl}');
    _log(
      'Started ${formatTimestamp(_startedAt!)} · '
      '${BuildMode.current.label} build',
    );
    _log(
      '${config.totalRequests} requests · ${config.concurrency} workers · '
      '${config.clientOption.label}',
    );
    if (config.rangePlan case final plan?) {
      _log(
        '${describeRangePlan(config)}'
        '${plan.isSequential ? '; each request asks for the next window.' : '.'}',
      );
    }

    _setPhase(BenchmarkPhase.preparing);
    _startTicker();

    try {
      final target = _targetUrl = await _prepare(config);
      if (_cancelRequested) {
        _completeRun(BenchmarkPhase.cancelled);
        return;
      }

      await _ensurePool(config);
      if (_cancelRequested) {
        _completeRun(BenchmarkPhase.cancelled);
        return;
      }

      _log('Benchmarking $target');
      _setPhase(BenchmarkPhase.running);
      _runClock
        ..reset()
        ..start();
      _dispatch(config, target);

      await _runCompleter!.future;
      _runClock.stop();
      _completeRun(
        _cancelRequested ? BenchmarkPhase.cancelled : BenchmarkPhase.finished,
      );
    } catch (error, stack) {
      _runClock.stop();
      _log('Run failed: $error', level: LogLevel.error);
      debugPrint('Benchmark run failed: $error\n$stack');
      _completeRun(BenchmarkPhase.failed);
    }
  }

  /// Requests cancellation of the active run.
  Future<void> cancel() async {
    if (!_phase.isBusy || _cancelRequested) return;
    _cancelRequested = true;
    _log('Cancelling…', level: LogLevel.warning);

    if (_phase == BenchmarkPhase.running) {
      _setPhase(BenchmarkPhase.cancelling);
      _pool?.broadcast(const CancelJobCommand());
    } else {
      // Still preparing: tearing the stream down aborts an in-flight pre-cache.
      _setPhase(BenchmarkPhase.cancelling);
      await _cacheStream?.dispose(force: true).timeout(
            const Duration(seconds: 5),
            onTimeout: () {},
          );
    }
  }

  /// Clears the log view.
  void clearLogs() {
    _logs.clear();
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Run lifecycle
  // ---------------------------------------------------------------------------

  /// Resolves the URL the workers should hit, preparing the cache as the
  /// benchmark type requires.
  Future<Uri> _prepare(BenchmarkConfig config) async {
    if (config.type == BenchmarkType.direct) {
      _log('Direct mode: http_cache_stream is bypassed.');
      return config.sourceUrl;
    }

    final manager = HttpCacheManager.instance;
    await _teardownCacheStream();

    if (config.type == BenchmarkType.nonCached) {
      final existing = manager.getExistingStream(config.sourceUrl);
      if (existing != null) {
        await existing.dispose(force: true).timeout(
              const Duration(seconds: 5),
              onTimeout: () {},
            );
      }
      final deleted = await manager.getCacheFiles(config.sourceUrl).delete();
      _log(deleted ? 'Cache wiped.' : 'No cache files to wipe.');
    }

    final stream = manager.createStream(config.sourceUrl);
    _cacheStream = stream;
    _watchCacheStream(stream);
    _log('Cache URL: ${stream.cacheUrl}');

    if (config.type == BenchmarkType.preCached) {
      _log('Pre-caching source…');
      final file = await stream.download();
      final length = await file.length();
      _log(
        'Pre-cache complete: ${formatBytes(length)} ($length bytes)',
        level: LogLevel.success,
      );
    }

    return stream.cacheUrl;
  }

  /// Spawns the worker pool, reusing the existing one when it already matches
  /// the requested concurrency and client implementation.
  Future<void> _ensurePool(BenchmarkConfig config) async {
    final pool = _pool;
    if (pool != null &&
        pool.size == config.concurrency &&
        pool.clientId == config.clientOption.id) {
      _log('Reusing ${pool.size} warm worker isolates.');
      return;
    }

    if (pool != null) {
      await _poolEvents?.cancel();
      _poolEvents = null;
      _pool = null;
      await pool.dispose();
    }

    _log(
      'Spawning ${config.concurrency} worker isolates '
      '(${config.clientOption.label})…',
    );
    final newPool = await WorkerPool.spawn(
      size: config.concurrency,
      clientOption: config.clientOption,
    );
    _poolEvents = newPool.events.listen(_onWorkerEvent);
    _pool = newPool;
    _log('Worker pool ready.');
  }

  /// Divides the requests between workers and starts them.
  void _dispatch(BenchmarkConfig config, Uri target) {
    final pool = _pool!;
    final distribution = config.requestDistribution();
    final jobId = ++_jobId;

    _outstandingWorkers
      ..clear()
      ..addAll(
        List<int>.generate(config.concurrency, (index) => index)
            .where((index) => distribution[index] > 0),
      );
    _runCompleter = Completer<void>();

    var sequence = 0;
    for (var workerId = 0; workerId < config.concurrency; workerId++) {
      final count = distribution[workerId];
      if (count == 0) continue;
      pool.send(
        workerId,
        RunJobCommand(
          jobId: jobId,
          url: target.toString(),
          requestCount: count,
          firstSequence: sequence,
          rangePlan: config.rangePlan,
        ),
      );
      sequence += count;
    }

    _log(
      'Dispatched ${config.totalRequests} requests across '
      '${_outstandingWorkers.length} worker(s): [${distribution.join(', ')}].',
    );

    if (_outstandingWorkers.isEmpty && !_runCompleter!.isCompleted) {
      _runCompleter!.complete();
    }
  }

  void _completeRun(BenchmarkPhase phase) {
    _stopTicker();
    _refreshStats();
    _summarize(phase);
    _record(phase);
    unawaited(_releaseCacheStream());
    _setPhase(phase);
  }

  /// Files the finished run in the history and pins the stats panel to it,
  /// unless the user has pinned an older run in the meantime.
  void _record(BenchmarkPhase phase) {
    final stats = _stats;
    final startedAt = _startedAt;
    if (!phase.isTerminal || stats == null || startedAt == null) return;

    final endedAt = DateTime.now();
    final result = BenchmarkResult(
      id: _runId,
      stats: stats,
      status: phase.label,
      startedAt: startedAt,
      endedAt: endedAt,
      config: _config,
      targetUrl: _targetUrl,
    );
    _results.add(result);
    _selectedResultId ??= result.id;

    _log(
      'Ended ${formatTimestamp(endedAt)} · '
      '${formatDuration(result.wallDuration!)} wall clock',
    );
  }

  void _summarize(BenchmarkPhase phase) {
    final stats = _stats;
    if (stats == null) return;

    switch (phase) {
      case BenchmarkPhase.finished:
        _log(
          'Run complete: ${stats.completed}/${stats.totalRequests} requests in '
          '${formatDuration(stats.elapsed)} · '
          '${formatRate(stats.requestsPerSecond, 'req/s')} · '
          '${formatBytesPerSecond(stats.bytesPerSecond)}',
          level: stats.errorCount == 0 ? LogLevel.success : LogLevel.warning,
        );
      case BenchmarkPhase.cancelled:
        _log(
          'Run cancelled after ${stats.completed} requests.',
          level: LogLevel.warning,
        );
      default:
        break;
    }

    if (stats.errorCount > 0) {
      _log(
        '${stats.errorCount} problem request(s): '
        '${stats.lengthMismatches} byte mismatch, ${stats.httpErrors} HTTP '
        'error, ${stats.failures} failure.',
        level: LogLevel.error,
      );
      for (final entry in _problemCounts.entries) {
        _log('  ×${entry.value}  ${entry.key}', level: LogLevel.error);
      }
    } else if (stats.completed > 0) {
      _log(
        'All ${stats.completed} responses matched their Content-Length.',
        level: LogLevel.success,
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Worker events
  // ---------------------------------------------------------------------------

  void _onWorkerEvent(WorkerEvent event) {
    switch (event) {
      case ResultBatchEvent(:final results):
        final accumulator = _accumulator;
        if (accumulator == null) return;
        for (final result in results) {
          accumulator.add(result);
          _noteResult(result);
        }
        _dirty = true;
      case WorkerLogEvent(:final workerId, :final message, :final isError):
        _log(
          'Worker $workerId: $message',
          level: isError ? LogLevel.error : LogLevel.info,
        );
      case JobDoneEvent(:final workerId, :final jobId):
        if (jobId != _jobId) return;
        _outstandingWorkers.remove(workerId);
        if (_outstandingWorkers.isEmpty &&
            _runCompleter != null &&
            !_runCompleter!.isCompleted) {
          _runCompleter!.complete();
        }
      case WorkerFatalEvent(:final workerId, :final message):
        _log('Worker $workerId fatal: $message', level: LogLevel.error);
      case WorkerReadyEvent():
        break;
    }
  }

  /// Logs problems without flooding the log: the first occurrence of each
  /// distinct problem is logged, then only at power-of-ten milestones.
  void _noteResult(RequestResult result) {
    if (_config?.rangePlan != null &&
        !_warnedRangeIgnored &&
        result.statusCode != null &&
        result.statusCode != HttpStatus.partialContent) {
      _warnedRangeIgnored = true;
      _log(
        'Range request answered with HTTP ${result.statusCode} instead of 206; '
        'the server may be ignoring the requested range.',
        level: LogLevel.warning,
      );
    }
    if (result.outcome == RequestOutcome.unverified && !_warnedUnverified) {
      _warnedUnverified = true;
      _log(
        'Response has no Content-Length; byte counts cannot be verified.',
        level: LogLevel.warning,
      );
      return;
    }
    if (result.isSuccess) return;

    final key = result.describeProblem();
    final count = (_problemCounts[key] ?? 0) + 1;
    _problemCounts[key] = count;
    if (count == 1) {
      _log(
        'Request #${result.sequence} (worker ${result.workerId}): $key',
        level: LogLevel.error,
      );
    } else if (count == 10 || count == 100 || count == 1000) {
      _log('$key — ×$count', level: LogLevel.error);
    }
  }

  // ---------------------------------------------------------------------------
  // Cache stream
  // ---------------------------------------------------------------------------

  void _watchCacheStream(HttpCacheStream stream) {
    _cacheStateEvents = stream.cacheStateStream.listen(
      (state) {
        _cacheState = state;
        _dirty = true;
      },
      onError: (Object error) {
        _log('Cache stream error: $error', level: LogLevel.error);
      },
      cancelOnError: false,
    );
  }

  Future<void> _releaseCacheStream() async {
    final stream = _cacheStream;
    if (stream == null) return;
    await _cacheStateEvents?.cancel();
    _cacheStateEvents = null;
    _cacheStream = null;
    // Matches the retain taken by createStream; the local server may still hold
    // retains from in-flight requests, which release on their own.
    await stream.dispose().timeout(
          const Duration(seconds: 5),
          onTimeout: () {},
        );
  }

  Future<void> _teardownCacheStream() => _releaseCacheStream();

  // ---------------------------------------------------------------------------
  // UI refresh
  // ---------------------------------------------------------------------------

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(refreshInterval, (_) {
      if (_dirty || _runClock.isRunning) _refreshStats();
    });
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  void _refreshStats() {
    final accumulator = _accumulator;
    if (accumulator == null) return;
    _dirty = false;
    _stats = accumulator.snapshot(_runClock.elapsed);
    notifyListeners();
  }

  void _setPhase(BenchmarkPhase phase) {
    _phase = phase;
    notifyListeners();
  }

  void _log(String message, {LogLevel level = LogLevel.info}) {
    _logs.add(LogEntry(message, level: level));
    if (_logs.length > maxLogEntries) {
      _logs.removeRange(0, _logs.length - maxLogEntries);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _stopTicker();
    unawaited(_poolEvents?.cancel());
    unawaited(_pool?.dispose());
    unawaited(_cacheStateEvents?.cancel());
    unawaited(_cacheStream?.dispose());
    super.dispose();
  }
}
