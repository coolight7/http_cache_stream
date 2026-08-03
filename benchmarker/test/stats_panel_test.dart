import 'dart:convert';

import 'package:benchmarker/src/benchmark/benchmark_config.dart';
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

  Future<void> pumpPanel(WidgetTester tester, {BenchmarkStats? stats}) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: StatsPanel(
              stats: stats,
              status: 'Finished',
              config: config,
              targetUrl: Uri.parse('http://127.0.0.1:4612/https/example.com/f'),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('copies the run and its statistics as text', (tester) async {
    await pumpPanel(tester, stats: statsFor(2));

    await tester.tap(find.byIcon(Icons.copy_all_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy as text'));
    await tester.pumpAndSettle();

    expect(copied, contains('https://example.com/file.bin'));
    expect(copied, contains('http://127.0.0.1:4612/https/example.com/f'));
    expect(copied, contains('Non-cached'));
    expect(copied, contains('Sequential windows: 2 × 1.00 KB'));
    expect(copied, contains('Requests:    2 / 2 completed'));
    expect(copied, contains('Completion'));
    expect(find.text('Statistics copied as text.'), findsOneWidget);
  });

  testWidgets('copies the run and its statistics as JSON', (tester) async {
    await pumpPanel(tester, stats: statsFor(2));

    await tester.tap(find.byIcon(Icons.copy_all_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy as JSON'));
    await tester.pumpAndSettle();

    final json = jsonDecode(copied!) as Map<String, Object?>;
    expect(json['source_url'], 'https://example.com/file.bin');
    expect(json['target_url'], 'http://127.0.0.1:4612/https/example.com/f');
    expect(json['cache_type'], 'nonCached');
    expect(json['status'], 'Finished');
    expect((json['range']! as Map)['mode'], 'sequential');
    expect((json['requests']! as Map)['completed'], 2);
    expect(find.text('Statistics copied as JSON.'), findsOneWidget);
  });

  testWidgets('the copy button is disabled before the first run',
      (tester) async {
    await pumpPanel(tester);

    final button = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.copy_all_outlined),
        matching: find.byType(IconButton),
      ),
    );
    expect(button.onPressed, isNull);
  });
}
