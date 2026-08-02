import 'package:flutter/material.dart';

import '../benchmark/benchmark_controller.dart';
import 'widgets/cache_progress_panel.dart';
import 'widgets/config_panel.dart';
import 'widgets/log_panel.dart';
import 'widgets/stats_panel.dart';

/// The single page of the benchmarker app.
class BenchmarkPage extends StatefulWidget {
  const BenchmarkPage({super.key});

  @override
  State<BenchmarkPage> createState() => _BenchmarkPageState();
}

class _BenchmarkPageState extends State<BenchmarkPage> {
  final BenchmarkController _controller = BenchmarkController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String get _status {
    final controller = _controller;
    switch (controller.phase) {
      case BenchmarkPhase.idle:
        return 'Idle';
      case BenchmarkPhase.preparing:
        return 'Preparing…';
      case BenchmarkPhase.running:
        return 'Running · ${controller.poolSize} workers';
      case BenchmarkPhase.cancelling:
        return 'Cancelling…';
      case BenchmarkPhase.finished:
        return 'Finished';
      case BenchmarkPhase.cancelled:
        return 'Cancelled';
      case BenchmarkPhase.failed:
        return 'Failed';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('http_cache_stream benchmarker'),
        actions: [
          ListenableBuilder(
            listenable: _controller,
            builder: (context, _) {
              if (!_controller.phase.isBusy) return const SizedBox.shrink();
              return const Padding(
                padding: EdgeInsets.only(right: 16),
                child: Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              );
            },
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) {
          final isBusy = _controller.phase.isBusy;
          final config = ConfigPanel(
            isBusy: isBusy,
            canCancel: isBusy && _controller.phase != BenchmarkPhase.cancelling,
            onRun: _controller.start,
            onCancel: _controller.cancel,
          );
          final progress = _controller.showsCacheProgress
              ? CacheProgressPanel(
                  cacheState: _controller.cacheState,
                  cacheUrl: _controller.targetUrl,
                )
              : null;
          final stats = StatsPanel(stats: _controller.stats, status: _status);
          final log = LogPanel(
            logs: _controller.logs,
            onClear: _controller.clearLogs,
          );

          return LayoutBuilder(
            builder: (context, constraints) {
              final isWide = constraints.maxWidth >= 900;
              if (!isWide) {
                return ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    config,
                    if (progress != null) ...[
                      const SizedBox(height: 16),
                      progress,
                    ],
                    const SizedBox(height: 16),
                    stats,
                    const SizedBox(height: 16),
                    log,
                  ],
                );
              }
              return Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 420,
                      child: ListView(
                        children: [
                          config,
                          if (progress != null) ...[
                            const SizedBox(height: 16),
                            progress,
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: ListView(
                        children: [
                          stats,
                          const SizedBox(height: 16),
                          log,
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}
