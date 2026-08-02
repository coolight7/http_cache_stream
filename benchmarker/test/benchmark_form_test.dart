import 'package:benchmarker/src/benchmark/source_probe.dart';
import 'package:benchmarker/src/ui/benchmark_form.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

BenchmarkForm _form({
  int? contentLength = 1000,
  bool acceptsRanges = true,
  Object? failWith,
}) {
  return BenchmarkForm(
    url: 'https://example.com/file.bin',
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
  test('a range cannot be selected before the source length is known', () {
    final form = _form();
    addTearDown(form.dispose);

    expect(form.canSelectRange, isFalse);
    expect(form.selectedRange(), isNull);
    expect(form.buildConfig()!.range, isNull);
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
    // The whole source is selected, so no Range header is sent.
    expect(form.isFullRange, isTrue);
    expect(form.buildConfig()!.range, isNull);
  });

  test('a partial selection becomes the config range', () async {
    final form = _form(contentLength: 1000);
    addTearDown(form.dispose);
    await form.fetchSourceLength();

    form.rangeFraction = const RangeValues(0.25, 0.75);

    final range = form.buildConfig()!.range!;
    expect(range.start, 250);
    expect(range.end, 749);
    expect(range.length, 500);
    expect(range.header, 'bytes=250-749');
  });

  test('an empty selection is rejected with an error', () async {
    final form = _form(contentLength: 1000);
    addTearDown(form.dispose);
    await form.fetchSourceLength();

    form.rangeFraction = const RangeValues(0.5, 0.5);

    expect(form.isEmptySelection, isTrue);
    expect(form.buildConfig(), isNull);
    expect(form.error, 'The selected range is empty.');
  });

  test('changing the URL drops the probed length', () async {
    final form = _form(contentLength: 1000);
    addTearDown(form.dispose);
    await form.fetchSourceLength();
    form.rangeFraction = const RangeValues(0.25, 0.75);

    form.urlController.text = 'https://example.com/other.bin';

    expect(form.contentLength, isNull);
    expect(form.canSelectRange, isFalse);
    expect(form.probeStatus, ProbeStatus.idle);
    expect(form.rangeFraction, const RangeValues(0, 1));
    expect(form.buildConfig()!.range, isNull);
  });

  test('a failed probe is reported and leaves ranges disabled', () async {
    final form = _form(failWith: StateError('offline'));
    addTearDown(form.dispose);

    await form.fetchSourceLength();

    expect(form.probeStatus, ProbeStatus.failed);
    expect(form.probeError, contains('offline'));
    expect(form.canSelectRange, isFalse);
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
