import 'dart:convert';

import 'package:benchmarker/src/benchmark/benchmark_config.dart';
import 'package:benchmarker/src/benchmark/benchmark_result.dart';
import 'package:benchmarker/src/benchmark/benchmark_stats.dart';
import 'package:benchmarker/src/benchmark/http_client_builder.dart';
import 'package:benchmarker/src/benchmark/worker_protocol.dart';
import 'package:benchmarker/src/ui/widgets/stats_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final config = BenchmarkConfig(
    sourceUrl: Uri.parse('https://example.com/file.bin'),
    concurrency: 2,
    totalRequests: 2,
    type: BenchmarkType.nonCached,
    clientOption: kHttpClientOptions.first,
    rangePlan: RangePlan.sequential(const ByteRange(0, 2047), 2),
  );
  final targetUrl = Uri.parse('http://127.0.0.1:4612/https/example.com/f');
  final startedAt = DateTime(2024, 5, 6, 7, 8, 9);

  BenchmarkStats statsFor(int completed) {
    final accumulator = StatsAccumulator(2);
    for (var i = 0; i < completed; i++) {
      accumulator.add(
        RequestResult(
          workerId: i,
          sequence: i,
          outcome: RequestOutcome.success,
          totalMicros: 1500,
          headerMicros: 250,
          firstByteMicros: 400,
          bytesReceived: 1024,
          contentLength: 1024,
          statusCode: 206,
        ),
      );
    }
    return accumulator.snapshot(const Duration(seconds: 1));
  }

  BenchmarkResult resultFor(
    int id, {
    int completed = 2,
    String status = 'Finished',
    bool inFlight = false,
  }) {
    final start = startedAt.add(Duration(minutes: id));
    return BenchmarkResult(
      id: id,
      stats: statsFor(completed),
      status: status,
      startedAt: start,
      endedAt: inFlight ? null : start.add(const Duration(seconds: 3)),
      config: config,
      targetUrl: targetUrl,
      mode: BuildMode.debug,
    );
  }

  /// Captures whatever the panel writes to the clipboard.
  String? copied;

  setUp(() {
    copied = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<void> pumpPanel(
    WidgetTester tester, {
    BenchmarkResult? result,
    List<BenchmarkResult> history = const [],
    ValueChanged<int>? onSelect,
    ValueChanged<int>? onDelete,
    VoidCallback? onClearAll,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: StatsPanel(
              result: result,
              status: 'Idle',
              history: history,
              onSelect: onSelect,
              onDelete: onDelete,
              onClearAll: onClearAll,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> openMenu(WidgetTester tester, IconData icon) async {
    await tester.tap(find.byIcon(icon));
    await tester.pumpAndSettle();
  }

  testWidgets('copies the run and its statistics as text', (tester) async {
    final result = resultFor(1);
    await pumpPanel(tester, result: result, history: [result]);

    await openMenu(tester, Icons.copy_all_outlined);
    await tester.tap(find.text('Copy as text'));
    await tester.pumpAndSettle();

    expect(copied, contains('https://example.com/file.bin'));
    expect(copied, contains('http://127.0.0.1:4612/https/example.com/f'));
    expect(copied, contains('Non-cached'));
    expect(copied, contains('Sequential windows: 2 × 1.00 KB'));
    expect(copied, contains('Requests:    2 / 2 completed'));
    expect(copied, contains('Mode:        Debug build'));
    expect(copied, contains('Started:     2024-05-06 07:09:09'));
    expect(copied, contains('Ended:       2024-05-06 07:09:12'));
    expect(copied, contains('Completion'));
    expect(find.text('Statistics copied as text.'), findsOneWidget);
  });

  testWidgets('copies the run and its statistics as JSON', (tester) async {
    final result = resultFor(1);
    await pumpPanel(tester, result: result, history: [result]);

    await openMenu(tester, Icons.copy_all_outlined);
    await tester.tap(find.text('Copy as JSON'));
    await tester.pumpAndSettle();

    final json = jsonDecode(copied!) as Map<String, Object?>;
    expect(json['run_id'], 1);
    expect(json['source_url'], 'https://example.com/file.bin');
    expect(json['target_url'], 'http://127.0.0.1:4612/https/example.com/f');
    expect(json['cache_type'], 'nonCached');
    expect(json['status'], 'Finished');
    expect(json['build_mode'], 'debug');
    expect(json['started_at'], isNotNull);
    expect(json['ended_at'], isNotNull);
    expect((json['range']! as Map)['mode'], 'sequential');
    expect((json['requests']! as Map)['completed'], 2);
    expect(find.text('Statistics copied as JSON.'), findsOneWidget);
  });

  testWidgets('exports every recorded result as a JSON list', (tester) async {
    final history = [resultFor(1), resultFor(2, completed: 1)];
    await pumpPanel(tester, result: history.last, history: history);

    await openMenu(tester, Icons.copy_all_outlined);
    await tester.tap(find.text('Export all results as JSON (2)'));
    await tester.pumpAndSettle();

    final json = jsonDecode(copied!) as List<Object?>;
    expect(json, hasLength(2));
    expect((json.first! as Map)['run_id'], 1);
    expect((json.last! as Map)['run_id'], 2);
    expect(
      ((json.last! as Map)['requests']! as Map)['completed'],
      1,
    );
    expect(find.text('2 result(s) copied as a JSON list.'), findsOneWidget);
  });

  testWidgets('lists past runs in the dropdown and reports the pick',
      (tester) async {
    final history = [
      resultFor(1, status: 'Cancelled'),
      resultFor(2),
    ];
    int? selected;
    await pumpPanel(
      tester,
      result: history.last,
      history: history,
      onSelect: (id) => selected = id,
    );

    expect(find.text(history.last.label), findsOneWidget);

    await tester.tap(find.byType(DropdownButton<int>));
    await tester.pumpAndSettle();
    // Most recent first, so the older run sits below the current one.
    expect(find.text(history.first.detail), findsOneWidget);

    await tester.tap(find.text(history.first.detail));
    await tester.pumpAndSettle();

    expect(selected, 1);
  });

  testWidgets('lists the run in flight above the recorded ones',
      (tester) async {
    final history = [resultFor(1)];
    final live = resultFor(2, status: 'Running · 2 workers', inFlight: true);
    await pumpPanel(
      tester,
      result: live,
      history: history,
      onSelect: (_) {},
    );

    expect(find.text('Running · 2 workers'), findsOneWidget);
    expect(find.text(live.label), findsOneWidget);
    expect(find.text('2 runs this session'), findsOneWidget);
  });

  testWidgets('deletes the result on show', (tester) async {
    final history = [resultFor(1), resultFor(2)];
    int? deleted;
    await pumpPanel(
      tester,
      result: history.last,
      history: history,
      onDelete: (id) => deleted = id,
      onClearAll: () {},
    );

    await openMenu(tester, Icons.delete_outline);
    await tester.tap(find.text('Delete current result'));
    await tester.pumpAndSettle();

    expect(deleted, 2);
    expect(find.text('Result #2 deleted.'), findsOneWidget);
  });

  testWidgets('clears every recorded result', (tester) async {
    final history = [resultFor(1), resultFor(2)];
    var clearedAll = false;
    await pumpPanel(
      tester,
      result: history.last,
      history: history,
      onDelete: (_) {},
      onClearAll: () => clearedAll = true,
    );

    await openMenu(tester, Icons.delete_outline);
    await tester.tap(find.text('Clear all results'));
    await tester.pumpAndSettle();

    expect(clearedAll, isTrue);
    expect(find.text('2 result(s) cleared.'), findsOneWidget);
  });

  testWidgets('a run in flight cannot be deleted', (tester) async {
    int? deleted;
    await pumpPanel(
      tester,
      result: resultFor(2, status: 'Running · 2 workers', inFlight: true),
      history: [resultFor(1)],
      onDelete: (id) => deleted = id,
      onClearAll: () {},
    );

    await openMenu(tester, Icons.delete_outline);
    await tester.tap(find.text('Delete current result'));
    await tester.pumpAndSettle();

    expect(deleted, isNull);
  });

  testWidgets('the copy and clear buttons are disabled before the first run',
      (tester) async {
    await pumpPanel(tester);

    for (final icon in [Icons.copy_all_outlined, Icons.delete_outline]) {
      final button = tester.widget<IconButton>(
        find.ancestor(
          of: find.byIcon(icon),
          matching: find.byType(IconButton),
        ),
      );
      expect(button.onPressed, isNull, reason: '$icon should be disabled');
    }
    expect(find.text('Run a benchmark to see results.'), findsOneWidget);
    expect(find.byType(DropdownButton<int>), findsNothing);
  });
}
