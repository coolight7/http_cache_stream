import 'package:benchmarker/src/benchmark/benchmark_config.dart';
import 'package:benchmarker/src/benchmark/source_probe.dart';
import 'package:benchmarker/src/ui/benchmark_form.dart';
import 'package:benchmarker/src/ui/widgets/config_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the range slider drives the requested byte range',
      (tester) async {
    final form = BenchmarkForm(
      url: 'https://example.com/file.bin',
      probe: (uri) async =>
          const SourceInfo(contentLength: 1000, acceptsRanges: true),
    );
    addTearDown(form.dispose);
    BenchmarkConfig? started;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ConfigPanel(
              form: form,
              isBusy: false,
              canCancel: false,
              onRun: (config) => started = config,
              onCancel: () {},
            ),
          ),
        ),
      ),
    );

    RangeSlider slider() => tester.widget<RangeSlider>(find.byType(RangeSlider));

    // Without a known source length the slider is disabled.
    expect(slider().onChanged, isNull);
    expect(
      find.text('Fetch the source length to request partial responses.'),
      findsOneWidget,
    );

    await tester.tap(find.text('Fetch length'));
    await tester.pumpAndSettle();

    expect(slider().onChanged, isNotNull);
    expect(find.textContaining('Full response'), findsOneWidget);

    // Selecting a sub-range shows it in bytes and sends it with the run.
    form.rangeFraction = const RangeValues(0.25, 0.75);
    await tester.pumpAndSettle();
    expect(find.textContaining('Range bytes=250-749'), findsOneWidget);

    await tester.tap(find.text('Run benchmark'));
    await tester.pumpAndSettle();

    expect(started!.range, const ByteRange(250, 749));
  });

  testWidgets('an empty range selection blocks the run', (tester) async {
    final form = BenchmarkForm(
      url: 'https://example.com/file.bin',
      probe: (uri) async =>
          const SourceInfo(contentLength: 1000, acceptsRanges: true),
    );
    addTearDown(form.dispose);
    var runs = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ConfigPanel(
              form: form,
              isBusy: false,
              canCancel: false,
              onRun: (_) => runs++,
              onCancel: () {},
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Fetch length'));
    await tester.pumpAndSettle();
    form.rangeFraction = const RangeValues(0.5, 0.5);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Run benchmark'));
    await tester.pumpAndSettle();

    expect(runs, 0);
    expect(find.text('The selected range is empty.'), findsWidgets);
  });
}
