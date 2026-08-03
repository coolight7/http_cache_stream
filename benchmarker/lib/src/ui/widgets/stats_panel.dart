import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../benchmark/benchmark_report.dart';
import '../../benchmark/benchmark_result.dart';
import '../../benchmark/benchmark_stats.dart';
import '../../util/formatting.dart';
import 'section_card.dart';

/// Clipboard formats offered by the copy button.
enum _CopyFormat { json, text, allJson }

/// Options offered by the clear button.
enum _ClearAction { current, all }

/// Aggregated results of the selected run, with the session's past runs behind
/// a dropdown.
class StatsPanel extends StatelessWidget {
  const StatsPanel({
    super.key,
    required this.result,
    required this.status,
    this.history = const [],
    this.onSelect,
    this.onDelete,
    this.onClearAll,
  });

  /// The run on show: the one in flight, or a past one picked from [history].
  final BenchmarkResult? result;

  /// Short status line shown when there is no result yet, e.g. `Idle`.
  final String status;

  /// Every completed run of this session, oldest first.
  final List<BenchmarkResult> history;

  /// Called with the id of the run to show.
  final ValueChanged<int>? onSelect;

  /// Called with the id of the run to drop from [history].
  final ValueChanged<int>? onDelete;

  /// Called to drop every run from [history].
  final VoidCallback? onClearAll;

  /// Whether the run on show has already been recorded, and so can be deleted.
  bool get _isRecorded {
    final result = this.result;
    return result != null && history.any((entry) => entry.id == result.id);
  }

  void _copy(BuildContext context, _CopyFormat format) {
    final result = this.result;
    final String report;
    final String message;
    switch (format) {
      case _CopyFormat.text:
        if (result == null) return;
        report = buildTextReport(result);
        message = 'Statistics copied as text.';
      case _CopyFormat.json:
        if (result == null) return;
        report = buildJsonReport(result);
        message = 'Statistics copied as JSON.';
      case _CopyFormat.allJson:
        if (history.isEmpty) return;
        report = buildJsonReportList(history);
        message = '${history.length} result(s) copied as a JSON list.';
    }
    Clipboard.setData(ClipboardData(text: report));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  void _clear(BuildContext context, _ClearAction action) {
    final String message;
    switch (action) {
      case _ClearAction.current:
        final result = this.result;
        if (result == null || !_isRecorded) return;
        onDelete?.call(result.id);
        message = 'Result #${result.id} deleted.';
      case _ClearAction.all:
        if (history.isEmpty) return;
        message = '${history.length} result(s) cleared.';
        onClearAll?.call();
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final result = this.result;
    final stats = result?.stats;

    return SectionCard(
      title: 'Statistics',
      subtitle: result == null ? status : result.status,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          PopupMenuButton<_CopyFormat>(
            enabled: result != null || history.isNotEmpty,
            tooltip: 'Copy statistics',
            icon: const Icon(Icons.copy_all_outlined),
            onSelected: (format) => _copy(context, format),
            itemBuilder: (context) => [
              PopupMenuItem<_CopyFormat>(
                value: _CopyFormat.text,
                enabled: result != null,
                child: const Text('Copy as text'),
              ),
              PopupMenuItem<_CopyFormat>(
                value: _CopyFormat.json,
                enabled: result != null,
                child: const Text('Copy as JSON'),
              ),
              PopupMenuItem<_CopyFormat>(
                value: _CopyFormat.allJson,
                enabled: history.isNotEmpty,
                child: Text('Export all results as JSON (${history.length})'),
              ),
            ],
          ),
          PopupMenuButton<_ClearAction>(
            enabled: history.isNotEmpty,
            tooltip: 'Clear results',
            icon: const Icon(Icons.delete_outline),
            onSelected: (action) => _clear(context, action),
            itemBuilder: (context) => [
              PopupMenuItem<_ClearAction>(
                value: _ClearAction.current,
                enabled: _isRecorded,
                child: const Text('Delete current result'),
              ),
              PopupMenuItem<_ClearAction>(
                value: _ClearAction.all,
                enabled: history.isNotEmpty,
                child: const Text('Clear all results'),
              ),
            ],
          ),
        ],
      ),
      child: result == null || stats == null
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
                _ResultSelector(
                  result: result,
                  history: history,
                  onSelect: onSelect,
                ),
                const SizedBox(height: 12),
                _RunMeta(result: result),
                const SizedBox(height: 12),
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

/// Dropdown listing the session's runs, most recent first, so a past result can
/// be brought back into the panel.
class _ResultSelector extends StatelessWidget {
  const _ResultSelector({
    required this.result,
    required this.history,
    this.onSelect,
  });

  final BenchmarkResult result;
  final List<BenchmarkResult> history;
  final ValueChanged<int>? onSelect;

  @override
  Widget build(BuildContext context) {
    // A run in flight is not recorded yet, so it is listed on top of the
    // history rather than taken from it.
    final entries = <BenchmarkResult>[
      if (!history.any((entry) => entry.id == result.id)) result,
      ...history.reversed,
    ];

    return InputDecorator(
      decoration: InputDecoration(
        labelText: 'Result',
        helperText: entries.length == 1
            ? 'Completed runs are kept here for this session.'
            : '${entries.length} runs this session',
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<int>(
          value: result.id,
          isExpanded: true,
          isDense: true,
          onChanged: onSelect == null || entries.length < 2
              ? null
              : (id) {
                  if (id != null) onSelect!(id);
                },
          selectedItemBuilder: (context) => [
            for (final entry in entries)
              Align(
                alignment: Alignment.centerLeft,
                child: Text(entry.label, overflow: TextOverflow.ellipsis),
              ),
          ],
          items: [
            for (final entry in entries)
              DropdownMenuItem<int>(
                value: entry.id,
                child: _ResultEntry(result: entry),
              ),
          ],
        ),
      ),
    );
  }
}

/// Two-line description of a run inside the dropdown.
class _ResultEntry extends StatelessWidget {
  const _ResultEntry({required this.result});

  final BenchmarkResult result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(result.label, overflow: TextOverflow.ellipsis),
        Text(
          result.detail,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// When the run ran, and in which build mode.
class _RunMeta extends StatelessWidget {
  const _RunMeta({required this.result});

  final BenchmarkResult result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ended = result.endedAt;
    return DefaultTextStyle.merge(
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
      child: Wrap(
        spacing: 12,
        runSpacing: 4,
        children: [
          Text('${result.mode.label} build'),
          Text('Started ${formatTimestamp(result.startedAt)}'),
          if (ended != null) Text('Ended ${formatTimestamp(ended)}'),
          if (result.wallDuration case final duration?)
            Text('Wall clock ${formatDuration(duration)}'),
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
