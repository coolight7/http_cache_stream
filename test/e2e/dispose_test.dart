import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http_cache_stream/http_cache_stream.dart';

import '../support/harness.dart';

void main() {
  late CacheTestHarness h;

  // Uses the default lifecycle config (disposeAfter = 5 min). A regression in the
  // dispose()/release() race would block until the test framework timeout rather
  // than completing in milliseconds.
  setUp(() async {
    h = CacheTestHarness();
    await h.setUp(
      configBuilder: (cacheDir) => GlobalCacheConfig(
        cacheDirectory: cacheDir,
        savePartialCache: false,
      ),
    );
  });

  tearDown(() => h.tearDown());

  test('dispose() completes promptly when a holder releases afterward',
      () async {
    final stream = h.manager.createStream(h.origin.url('/a.mp3')); // count 1
    stream.retain(); // simulate an in-flight request holding it: count 2

    final disposing =
        stream.dispose(); // count 1: still retained, completes later
    expect(stream.isDisposed, isFalse);

    stream.release(); // count 0: must honor the pending dispose now

    await disposing.timeout(const Duration(seconds: 5));
    expect(stream.isDisposed, isTrue);
  });

  test('a retain after dispose resurrects the stream', () async {
    final stream = h.manager.createStream(h.origin.url('/b.mp3')); // count 1
    stream.retain(); // count 2

    stream.dispose(); // count 1: pending dispose
    stream.retain(); // count 2: a new holder clears the pending dispose

    stream.release(); // count 1
    stream.release(); // count 0: lifecycle, not disposed
    expect(stream.isDisposed, isFalse);

    await stream.dispose(force: true);
    expect(stream.isDisposed, isTrue);
  });

  test('dispose deletes an incomplete cache with unknown source length',
      () async {
    final responseCloseGate = Completer<void>();
    addTearDown(() {
      if (!responseCloseGate.isCompleted) responseCloseGate.complete();
    });
    h.origin.chunkedTransferEncoding = true;
    h.origin.responseCloseGate = responseCloseGate;

    final stream = h.manager.createStream(h.origin.url('/chunked.mp3'));
    stream.download().ignore();

    // Wait until the chunked body is committed while the origin deliberately
    // withholds the final chunk, keeping the download incomplete with no known
    // source length.
    for (var i = 0;
        i < 100 &&
            (!stream.files.partial.existsSync() ||
                stream.files.partial.lengthSync() == 0);
        i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    expect(stream.headers?.sourceLength, isNull);
    expect(stream.files.partial.existsSync(), isTrue);
    expect(stream.files.partial.lengthSync(), greaterThan(0));

    await stream.dispose(force: true);
    responseCloseGate.complete();

    expect(stream.files.partial.existsSync(), isFalse);
    expect(stream.files.metadata.existsSync(), isFalse);
  });
}
