import 'package:benchmarker/src/benchmark/benchmark_config.dart';
import 'package:benchmarker/src/benchmark/http_client_builder.dart';
import 'package:benchmarker/src/ui/benchmark_page.dart';
import 'package:benchmarker/src/ui/widgets/config_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('configuration survives the panel scrolling out of view',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: BenchmarkPage()));

    Future<void> tapVisible(Finder finder) async {
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    // The URL field is the first text field on the page, followed by the
    // concurrency and total request fields.
    await tester.enterText(
      find.byType(TextField).first,
      'https://example.com/custom.bin',
    );
    await tester.enterText(find.byType(TextField).at(1), '7');
    await tester.enterText(find.byType(TextField).at(2), '21');
    await tapVisible(find.text(BenchmarkType.direct.label));

    final selectedClient = kHttpClientOptions[1];
    await tapVisible(find.byType(DropdownButton<HttpClientOption>));
    await tapVisible(find.text(selectedClient.label).last);

    // Scroll far enough that the panel leaves the list's cache extent and is
    // disposed, then scroll back.
    await tester.drag(find.byType(ListView), const Offset(0, -3000));
    await tester.pumpAndSettle();
    expect(find.byType(ConfigPanel), findsNothing);

    await tester.drag(find.byType(ListView), const Offset(0, 3000));
    await tester.pumpAndSettle();
    expect(find.byType(ConfigPanel), findsOneWidget);

    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      'https://example.com/custom.bin',
    );
    expect(
      tester.widget<TextField>(find.byType(TextField).at(1)).controller!.text,
      '7',
    );
    expect(
      tester.widget<TextField>(find.byType(TextField).at(2)).controller!.text,
      '21',
    );
    expect(
      tester
          .widget<SegmentedButton<BenchmarkType>>(
            find.byType(SegmentedButton<BenchmarkType>),
          )
          .selected,
      {BenchmarkType.direct},
    );
    expect(
      tester
          .widget<DropdownButton<HttpClientOption>>(
            find.byType(DropdownButton<HttpClientOption>),
          )
          .value,
      selectedClient,
    );
  });
}
