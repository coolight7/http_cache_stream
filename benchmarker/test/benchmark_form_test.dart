import 'package:benchmarker/src/benchmark/benchmark_config.dart';
import 'package:benchmarker/src/benchmark/source_probe.dart';
import 'package:benchmarker/src/ui/benchmark_form.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

BenchmarkForm _form({
  int? contentLength = 1000,
  bool acceptsRanges = true,
  Object? failWith,
  int totalRequests = 40,
}) {
  return BenchmarkForm(
    url: 'https://example.com/file.bin',
    totalRequests: totalRequests,
    probe: (uri) async {
      if (failWith != null) throw failWith;
      return SourceInfo(
        contentLength: contentLength,
        acceptsRanges: acceptsRanges,
      );
    },
  );
}

void main() {
  test('range modes are unavailable before the source length is known', () {
    final form = _form();
    addTearDown(form.dispose);

    expect(form.rangeMode, RangeMode.full);
    expect(form.canSelectRange, isFalse);

    form.rangeMode = RangeMode.sequential;

    expect(form.rangeMode, RangeMode.full, reason: 'refused without a length');
    expect(form.buildConfig()!.rangePlan, isNull);
  });

  test('fetching the length enables ranges and reports the source size',
      () async {
    final form = _form(contentLength: 2048);
    addTearDown(form.dispose);

    await form.fetchSourceLength();

    expect(form.probeStatus, ProbeStatus.ready);
    expect(form.contentLength, 2048);
    expect(form.acceptsRanges, isTrue);
    expect(form.canSelectRange, isTrue);
    expect(form.isFullRange, isTrue);
    // Still in full-response mode, so no Range header is sent.
    expect(form.rangeMode, RangeMode.full);
    expect(form.buildConfig()!.rangePlan, isNull);
  });

  test('fixed mode sends the selected range with every request', () async {
    final form = _form(contentLength: 1000);
    addTearDown(form.dispose);
    await form.fetchSourceLength();

    form.rangeMode = RangeMode.fixed;
    form.rangeFraction = const RangeValues(0.25, 0.75);

    final plan = form.buildConfig()!.rangePlan!;
    expect(plan.isSequential, isFalse);
    expect(plan.windowSize, 500);
    expect(plan.windowFor(0), const ByteRange(250, 749));
    expect(plan.windowFor(9), const ByteRange(250, 749));
  });

  test('sequential mode divides the range between the requests', () async {
    final form = _form(contentLength: 1000, totalRequests: 4);
    addTearDown(form.dispose);
    await form.fetchSourceLength();

    form.rangeMode = RangeMode.sequential;

    final plan = form.buildConfig()!.rangePlan!;
    expect(plan.isSequential, isTrue);
    expect(plan.windowSize, 250);
    expect(plan.windowFor(0), const ByteRange(0, 249));
    expect(plan.windowFor(3), const ByteRange(750, 999));
  });

  test('sequential windows follow the request count', () async {
    final form = _form(contentLength: 1000, totalRequests: 4);
    addTearDown(form.dispose);
    await form.fetchSourceLength();
    form.rangeMode = RangeMode.sequential;

    expect(form.buildRangePlan(4)!.windowSize, 250);
    expect(form.buildRangePlan(10)!.windowSize, 100);

    form.requestsController.text = '10';
    expect(form.buildConfig()!.rangePlan!.windowSize, 100);
  });

  test('sequential windows stay inside the selected sub-range', () async {
    final form = _form(contentLength: 1000, totalRequests: 4);
    addTearDown(form.dispose);
    await form.fetchSourceLength();

    form.rangeMode = RangeMode.sequential;
    form.rangeFraction = const RangeValues(0.5, 1);

    final plan = form.buildConfig()!.rangePlan!;
    expect(plan.start, 500);
    expect(plan.end, 999);
    expect(plan.windowSize, 125);
    expect(plan.windowFor(0), const ByteRange(500, 624));
    expect(plan.windowFor(3), const ByteRange(875, 999));
  });

  test('an empty selection is rejected with an error', () async {
    final form = _form(contentLength: 1000);
    addTearDown(form.dispose);
    await form.fetchSourceLength();

    form.rangeMode = RangeMode.fixed;
    form.rangeFraction = const RangeValues(0.5, 0.5);

    expect(form.isEmptySelection, isTrue);
    expect(form.buildConfig(), isNull);
    expect(form.error, 'The selected range is empty.');
  });

  test('an empty selection is ignored in full-response mode', () async {
    final form = _form(contentLength: 1000);
    addTearDown(form.dispose);
    await form.fetchSourceLength();

    form.rangeFraction = const RangeValues(0.5, 0.5);

    expect(form.buildConfig()!.rangePlan, isNull);
    expect(form.error, isNull);
  });

  test('changing the URL drops the probed length and the range mode', () async {
    final form = _form(contentLength: 1000);
    addTearDown(form.dispose);
    await form.fetchSourceLength();
    form.rangeMode = RangeMode.sequential;
    form.rangeFraction = const RangeValues(0.25, 0.75);

    form.urlController.text = 'https://example.com/other.bin';

    expect(form.contentLength, isNull);
    expect(form.canSelectRange, isFalse);
    expect(form.probeStatus, ProbeStatus.idle);
    expect(form.rangeMode, RangeMode.full);
    expect(form.rangeFraction, const RangeValues(0, 1));
    expect(form.buildConfig()!.rangePlan, isNull);
  });

  test('a failed probe is reported and leaves ranges disabled', () async {
    final form = _form(failWith: StateError('offline'));
    addTearDown(form.dispose);

    await form.fetchSourceLength();

    expect(form.probeStatus, ProbeStatus.failed);
    expect(form.probeError, contains('offline'));
    expect(form.canSelectRange, isFalse);
    expect(form.rangeMode, RangeMode.full);
  });

  test('a source without a Content-Length is reported', () async {
    final form = _form(contentLength: null, acceptsRanges: false);
    addTearDown(form.dispose);

    await form.fetchSourceLength();

    expect(form.probeStatus, ProbeStatus.ready);
    expect(form.contentLength, isNull);
    expect(form.canSelectRange, isFalse);
    expect(form.probeError, contains('Content-Length'));
  });

  test('a stale probe does not overwrite a newer one', () async {
    var pending = 0;
    final form = BenchmarkForm(
      url: 'https://example.com/file.bin',
      probe: (uri) async {
        final size = ++pending;
        // The first call resolves last.
        await Future<void>.delayed(Duration(milliseconds: 40 ~/ size));
        return SourceInfo(contentLength: size * 1000, acceptsRanges: true);
      },
    );
    addTearDown(form.dispose);

    final first = form.fetchSourceLength();
    final second = form.fetchSourceLength();
    await Future.wait([first, second]);

    expect(form.contentLength, 2000);
  });
}
