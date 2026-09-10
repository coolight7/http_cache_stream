import 'package:flutter/foundation.dart';

import '../util/formatting.dart';
import 'benchmark_config.dart';
import 'benchmark_stats.dart';

/// The Flutter build mode the benchmarker itself was compiled in.
///
/// Results are only comparable between runs of the same mode: debug builds pay
/// for assertions and an unoptimised VM, so their numbers are not
/// representative of a shipped app.
enum BuildMode {
  debug('Debug'),
  profile('Profile'),
  release('Release');

  const BuildMode(this.label);

  final String label;

  /// The mode this binary is running in.
  static BuildMode get current {
    if (kDebugMode) return BuildMode.debug;
    if (kProfileMode) return BuildMode.profile;
    return BuildMode.release;
  }
}

/// One benchmark run: its inputs, its results, and when it ran.
///
/// The controller builds a live instance while a run is in flight and keeps a
/// final one in its history once the run reaches a terminal phase.
class BenchmarkResult {
  BenchmarkResult({
    required this.id,
    required this.stats,
    required this.status,
    required this.startedAt,
    this.endedAt,
    this.config,
    this.targetUrl,
    BuildMode? mode,
  }) : mode = mode ?? BuildMode.current;

  /// Run number, counting from 1 within the session.
  final int id;

  /// Results as of the last snapshot taken.
  final BenchmarkStats stats;

  /// Human-readable phase of the run, e.g. `Finished` or `Running · 4 workers`.
  final String status;

  /// Wall-clock time the run was started, before any preparation.
  final DateTime startedAt;

  /// Wall-clock time the run reached a terminal phase, or null while running.
  final DateTime? endedAt;

  /// Inputs of the run.
  final BenchmarkConfig? config;

  /// URL the workers hit: the cache URL, or the source URL for direct runs.
  final Uri? targetUrl;

  /// Build mode the run was measured in.
  final BuildMode mode;

  /// Whether the run has reached a terminal phase.
  bool get isComplete => endedAt != null;

  /// Wall-clock time from start to end, including cache preparation. Null while
  /// the run is still in flight.
  ///
  /// This is longer than [BenchmarkStats.elapsed], which only covers the
  /// measured requests.
  Duration? get wallDuration => endedAt?.difference(startedAt);

  /// Label of the benchmark type, or a placeholder when the run has no config.
  String get typeLabel => config?.type.label ?? 'Run';

  /// Single line identifying the run in the history dropdown.
  String get label => '#$id · $typeLabel · ${formatClockTime(startedAt)}';

  /// Second line of the history dropdown: how the run went.
  String get detail => '$status · ${mode.label} · ${stats.completed}/'
      '${stats.totalRequests} requests · ${formatDuration(stats.elapsed)}';
}
