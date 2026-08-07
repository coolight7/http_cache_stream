import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http_cache_stream/http_cache_stream.dart';

import '../support/harness.dart';
import '../support/payload.dart';

// pauseAfter == disposeAfter takes the immediate-dispose branch in release(),
// so teardown is fast and independent of readTimeout.
const _fastLifecycle = StreamLifecycleConfig(
  pauseAfter: Duration(milliseconds: 150),
  disposeAfter: Duration(milliseconds: 150),
);

/// Starts [stream]'s download, waits until the origin has delivered its gated
/// first half, then disposes it while preserving the partial cache.
Future<double> _abortAtHalf(HttpCacheStream stream) async {
  final reachedHalf = Completer<double>();
  final subscription = stream.cacheStateStream.listen((state) {
    final progress = state.progress;
    if (progress != null && progress >= 0.5 && !reachedHalf.isCompleted) {
      reachedHalf.complete(progress);
    }
  });

  stream.download().ignore();
  final progress = await reachedHalf.future.timeout(const Duration(seconds: 5));
  await stream.dispose();
  await subscription.cancel();
  return progress;
}

void main() {
  late CacheTestHarness h;

  setUp(() async {
    h = CacheTestHarness();
    await h.setUp(
      payload: Payload.generate(128 * 1024),
      configBuilder: (cacheDir) => GlobalCacheConfig(
        cacheDirectory: cacheDir,
        lifecycleConfig: _fastLifecycle,
      ),
    );
  });

  tearDown(() => h.tearDown());

  test('getCacheUrl lazily creates a stream that auto-disposes when idle',
      () async {
    final source = h.origin.url('/a.mp3');
    final cacheUrl = h.manager.getCacheUrl(source);

    // No stream exists until the first request reaches the server.
    expect(h.manager.getExistingStream(source), isNull);

    await h.fetch(cacheUrl);
    expect(h.manager.getExistingStream(source), isNotNull);

    // After release + the (tiny) lifecycle window, the stream is disposed and
    // removed from the manager.
    await Future.delayed(const Duration(milliseconds: 500));
    expect(h.manager.getExistingStream(source), isNull);
  });

  test('retaining again before disposal keeps the stream alive', () async {
    final source = h.origin.url('/b.mp3');
    final cacheUrl = h.manager.getCacheUrl(source);

    await h.fetch(cacheUrl);
    // Re-acquire (retain) before the lifecycle timer fires; this cancels it.
    final stream = h.manager.createStream(source);
    expect(stream.isDisposed, isFalse);

    await Future.delayed(const Duration(milliseconds: 400));
    expect(stream.isDisposed, isFalse,
        reason: 'a retained stream must survive past disposeAfter');

    await stream.dispose();
  });

  test('dispose(force: true) tears the stream down immediately', () async {
    final source = h.origin.url('/c.mp3');
    final stream = h.manager.createStream(source);

    await stream.dispose(force: true);
    expect(stream.isDisposed, isTrue);
    expect(h.manager.getExistingStream(source), isNull);
  });

  test('preCacheUrl downloads the file then disposes the stream', () async {
    final source = h.origin.url('/d.mp3');
    final file = await h.manager.preCacheUrl(source);

    expect(file.existsSync(), isTrue);
    expect(Payload.hash(await file.readAsBytes()), h.payloadHash);
    expect(h.manager.getExistingStream(source), isNull,
        reason: 'preCacheUrl disposes its stream when done');
  });

  test('getCacheUrl is stable for the same source', () {
    final source = h.origin.url('/e.mp3');
    expect(h.manager.getCacheUrl(source), h.manager.getCacheUrl(source));
  });

  test('resumes a partial download after the stream is recreated', () async {
    final source = h.origin.url('/resume.mp3');
    final half = h.origin.payload.length ~/ 2;
    final bodyGate = Completer<void>();
    h.origin
      ..responseBodyGate = bodyGate
      ..responseBodyGateAfterBytes = half;

    final interrupted = h.manager.createStream(source);
    final interruptedProgress = await _abortAtHalf(interrupted);
    expect(interruptedProgress, 0.5);

    // The first request is now abandoned; do not gate the resumed range.
    h.origin
      ..responseBodyGate = null
      ..responseBodyGateAfterBytes = null;
    bodyGate.complete();

    final resumed = h.manager.createStream(source);
    await resumed.validateCache(); // Wait for persisted metadata and state.
    expect(resumed.progress, interruptedProgress);
    expect(resumed.cachePosition, half);

    final file = await resumed.download();
    expect(Payload.hash(await file.readAsBytes()), h.payloadHash);
    expect(h.origin.rangeHeaders, contains('bytes=$half-'));

    await resumed.dispose();
  });

  test('resets a partial cache when the source changes before resuming',
      () async {
    final source = h.origin.url('/changed-resume.mp3');
    final half = h.origin.payload.length ~/ 2;
    final bodyGate = Completer<void>();
    h.origin
      ..responseBodyGate = bodyGate
      ..responseBodyGateAfterBytes = half;

    final interrupted = h.manager.createStream(source);
    final cacheFilePath = interrupted.cacheFile.path;
    final originalPayloadHash = h.payloadHash;
    await _abortAtHalf(interrupted);

    h.origin
      ..responseBodyGate = null
      ..responseBodyGateAfterBytes = null
      ..payload = Payload.generate(h.origin.payload.length, seed: 0xCAFE)
      ..etag = '"v2"';
    final changedPayloadHash = h.payloadHash;
    expect(changedPayloadHash, isNot(originalPayloadHash));
    bodyGate.complete();

    final resumed = h.manager.createStream(source);
    await resumed.validateCache(); // Wait for persisted metadata and state.
    expect(resumed.cacheFile.path, cacheFilePath);
    expect(resumed.cachePosition, half);

    final cacheErrors = <Object>[];
    final subscription = resumed.cacheStateStream.listen(
      (_) {},
      onError: cacheErrors.add,
    );
    final rangesBeforeResume = h.origin.rangeHeaders.length;
    final file = await resumed.download();
    await subscription.cancel();
    final resumedRanges = h.origin.rangeHeaders.sublist(rangesBeforeResume);

    expect(cacheErrors, contains(isA<CacheSourceChangedException>()));
    expect(resumedRanges, contains('bytes=$half-'),
        reason: 'the stale partial cache must first be detected on resume');
    expect(resumedRanges, contains(null),
        reason: 'the invalid partial cache must be reset before a full retry');
    expect(Payload.hash(await file.readAsBytes()), changedPayloadHash);

    await resumed.dispose();
  });

  test('deleteCache removes cached files once no streams are active', () async {
    final source = h.origin.url('/f.mp3');
    final files = h.manager.getCacheFiles(source);

    final stream = h.manager.createStream(source);
    await stream.download();
    await stream.dispose();
    expect(files.complete.existsSync(), isTrue);

    await h.manager.deleteCache();
    expect(files.complete.existsSync(), isFalse);
  });
}
