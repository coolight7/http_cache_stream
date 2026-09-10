import 'package:benchmarker/src/benchmark/benchmark_config.dart';
import 'package:benchmarker/src/benchmark/source_probe.dart';
import 'package:benchmarker/src/ui/benchmark_form.dart';
import 'package:benchmarker/src/ui/widgets/config_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late BenchmarkForm form;
  BenchmarkConfig? started;
  var runs = 0;

  Future<void> pumpPanel(WidgetTester tester, {int totalRequests = 4}) async {
    started = null;
    runs = 0;
    form = BenchmarkForm(
      url: 'https://example.com/file.bin',
      totalRequests: totalRequests,
      probe: (uri) async =>
          const SourceInfo(contentLength: 1000, acceptsRanges: true),
    );
    addTearDown(form.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ConfigPanel(
              form: form,
              isBusy: false,
              canCancel: false,
              onRun: (config) {
                started = config;
                runs++;
              },
              onCancel: () {},
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('range modes stay disabled until the length is fetched',
      (tester) async {
    await pumpPanel(tester);

    RangeSlider slider() =>
        tester.widget<RangeSlider>(find.byType(RangeSlider));
    ButtonSegment<RangeMode> segment(RangeMode mode) => tester
        .widget<SegmentedButton<RangeMode>>(
          find.byType(SegmentedButton<RangeMode>),
        )
        .segments
        .whereType<ButtonSegment<RangeMode>>()
        .firstWhere((segment) => segment.value == mode);

    expect(slider().onChanged, isNull);
    expect(segment(RangeMode.full).enabled, isTrue);
    expect(segment(RangeMode.fixed).enabled, isFalse);
    expect(segment(RangeMode.sequential).enabled, isFalse);
    expect(find.textContaining('no Range header'), findsOneWidget);

    await tester.tap(find.text('Fetch length'));
    await tester.pumpAndSettle();

    expect(segment(RangeMode.fixed).enabled, isTrue);
    expect(segment(RangeMode.sequential).enabled, isTrue);
    // The slider only bites once a partial mode is selected.
    expect(slider().onChanged, isNull);

    await tester.tap(find.text(RangeMode.fixed.label));
    await tester.pumpAndSettle();
    expect(slider().onChanged, isNotNull);
  });

  testWidgets('fixed mode sends the slider selection with every request',
      (tester) async {
    await pumpPanel(tester);
    await tester.tap(find.text('Fetch length'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(RangeMode.fixed.label));
    await tester.pumpAndSettle();

    form.rangeFraction = const RangeValues(0.25, 0.75);
    await tester.pumpAndSettle();
    expect(find.textContaining('Every request: Range bytes=250-749'),
        findsOneWidget);

    await tester.tap(find.text('Run benchmark'));
    await tester.pumpAndSettle();

    final plan = started!.rangePlan!;
    expect(plan.isSequential, isFalse);
    expect(plan.windowFor(0), const ByteRange(250, 749));
  });

  testWidgets('sequential mode divides the range across the requests',
      (tester) async {
    await pumpPanel(tester, totalRequests: 4);
    await tester.tap(find.text('Fetch length'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(RangeMode.sequential.label));
    await tester.pumpAndSettle();

    expect(find.textContaining('4 windows × 250 B'), findsOneWidget);

    // The window size follows the total request count as it is edited.
    await tester.enterText(find.byType(TextField).at(2), '10');
    await tester.pumpAndSettle();
    expect(find.textContaining('10 windows × 100 B'), findsOneWidget);

    await tester.tap(find.text('Run benchmark'));
    await tester.pumpAndSettle();

    final plan = started!.rangePlan!;
    expect(plan.isSequential, isTrue);
    expect(plan.windowSize, 100);
    expect(plan.windowFor(0), const ByteRange(0, 99));
    expect(plan.windowFor(9), const ByteRange(900, 999));
  });

  testWidgets('an empty range selection blocks the run', (tester) async {
    await pumpPanel(tester);
    await tester.tap(find.text('Fetch length'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(RangeMode.fixed.label));
    await tester.pumpAndSettle();

    form.rangeFraction = const RangeValues(0.5, 0.5);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Run benchmark'));
    await tester.pumpAndSettle();

    expect(runs, 0);
    expect(find.text('The selected range is empty.'), findsWidgets);
  });
}
