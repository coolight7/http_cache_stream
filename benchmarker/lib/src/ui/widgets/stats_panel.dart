import 'package:flutter/material.dart';

import '../../benchmark/benchmark_stats.dart';
import '../../util/formatting.dart';
import 'section_card.dart';

/// Aggregated results of the current or most recent run.
class StatsPanel extends StatelessWidget {
  const StatsPanel({super.key, required this.stats, required this.status});

  final BenchmarkStats? stats;

  /// Short status line shown next to the title, e.g. `Running`.
  final String status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stats = this.stats;

    return SectionCard(
      title: 'Statistics',
      subtitle: status,
      child: stats == null
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(
                'Run a benchmark to see results.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: stats.progress,
                    minHeight: 6,
                  ),
                ),
                const SizedBox(height: 16),
                _TileGrid(stats: stats),
                const SizedBox(height: 20),
                _TimingTable(stats: stats),
                const SizedBox(height: 16),
                _OutcomeChips(stats: stats),
              ],
            ),
    );
  }
}

class _TileGrid extends StatelessWidget {
  const _TileGrid({required this.stats});

  final BenchmarkStats stats;

  @override
  Widget build(BuildContext context) {
    final tiles = <_Tile>[
      _Tile('Requests', '${stats.completed} / ${stats.totalRequests}'),
      _Tile('Throughput', formatRate(stats.requestsPerSecond, 'req/s')),
      _Tile('Bandwidth', formatBytesPerSecond(stats.bytesPerSecond)),
      _Tile('Elapsed', formatDuration(stats.elapsed)),
      _Tile(
        'Avg completion',
        stats.completionTime == null
            ? '—'
            : formatDuration(stats.completionTime!.avg),
      ),
      _Tile(
        'Avg headers',
        stats.headerTime == null ? '—' : formatDuration(stats.headerTime!.avg),
      ),
      _Tile(
        'Avg first byte',
        stats.firstByteTime == null
            ? '—'
            : formatDuration(stats.firstByteTime!.avg),
      ),
      _Tile('Bytes received', formatBytes(stats.totalBytes)),
      _Tile('Avg response size', formatBytes(stats.avgBytesPerRequest)),
      _Tile(
        'Problems',
        '${stats.errorCount}',
        isError: stats.errorCount > 0,
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        const spacing = 12.0;
        final columns = constraints.maxWidth ~/ 170;
        final columnCount = columns.clamp(2, 5);
        final tileWidth =
            (constraints.maxWidth - spacing * (columnCount - 1)) / columnCount;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (final tile in tiles)
              SizedBox(width: tileWidth, child: tile),
          ],
        );
      },
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile(this.label, this.value, {this.isError = false});

  final String label;
  final String value;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: theme.textTheme.titleMedium?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
                color: isError ? theme.colorScheme.error : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TimingTable extends StatelessWidget {
  const _TimingTable({required this.stats});

  final BenchmarkStats stats;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = <({String label, TimingStats? timing})>[
      (label: 'Response headers', timing: stats.headerTime),
      (label: 'First byte', timing: stats.firstByteTime),
      (label: 'Completion', timing: stats.completionTime),
    ];

    Widget cell(String text, {bool header = false, bool leading = false}) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Text(
          text,
          textAlign: leading ? TextAlign.left : TextAlign.right,
          style: (header
                  ? theme.textTheme.labelSmall
                  : theme.textTheme.bodySmall)
              ?.copyWith(
            color: header ? theme.colorScheme.onSurfaceVariant : null,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 520),
        child: Table(
          columnWidths: const {0: IntrinsicColumnWidth()},
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          border: TableBorder(
            horizontalInside: BorderSide(
              color: theme.colorScheme.outlineVariant,
              width: 0.5,
            ),
          ),
          children: [
            TableRow(
              children: [
                cell('Timing', header: true, leading: true),
                cell('avg', header: true),
                cell('p50', header: true),
                cell('p90', header: true),
                cell('p99', header: true),
                cell('min', header: true),
                cell('max', header: true),
              ],
            ),
            for (final row in rows)
              TableRow(
                children: [
                  cell(row.label, leading: true),
                  cell(_format(row.timing?.avg)),
                  cell(_format(row.timing?.p50)),
                  cell(_format(row.timing?.p90)),
                  cell(_format(row.timing?.p99)),
                  cell(_format(row.timing?.min)),
                  cell(_format(row.timing?.max)),
                ],
              ),
          ],
        ),
      ),
    );
  }

  static String _format(Duration? duration) =>
      duration == null ? '—' : formatDuration(duration);
}

class _OutcomeChips extends StatelessWidget {
  const _OutcomeChips({required this.stats});

  final BenchmarkStats stats;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entries = <({String label, int count, bool bad})>[
      (label: 'verified', count: stats.succeeded, bad: false),
      (label: 'unverified', count: stats.unverified, bad: false),
      (label: 'byte mismatch', count: stats.lengthMismatches, bad: true),
      (label: 'HTTP errors', count: stats.httpErrors, bad: true),
      (label: 'failures', count: stats.failures, bad: true),
    ];

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final entry in entries)
          Chip(
            visualDensity: VisualDensity.compact,
            label: Text('${entry.label}: ${entry.count}'),
            side: BorderSide(
              color: entry.bad && entry.count > 0
                  ? theme.colorScheme.error
                  : theme.colorScheme.outlineVariant,
            ),
          ),
      ],
    );
  }
}
