import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http_cache_stream/http_cache_stream.dart';
import 'package:http_cache_stream/src/cache_stream/cache_downloader/buffered_io_sink.dart';
import 'package:http_cache_stream/src/cache_stream/response_streams/partial_cache_file_stream.dart';
import 'package:http_cache_stream/src/models/stream_response/stream_response_range.dart';

import '../support/payload.dart';

void main() {
  late Directory directory;
  late CacheFiles cacheFiles;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('hcs_partial_stream_');
    cacheFiles = CacheFiles.fromFile(File('${directory.path}/cache.bin'));
  });

  tearDown(() async {
    if (directory.existsSync()) await directory.delete(recursive: true);
  });

  test('waits for future positions and enforces the requested range', () async {
    final payload = Payload.generate(200 * 1024);
    final sink = BufferedIOSink(cacheFiles.partial, 0);
    sink.add(Uint8List.sublistView(payload, 0, 50 * 1024));
    await sink.flush();

    final stream = PartialCacheFileStream(
      StreamRange.validate(10 * 1024, 150 * 1024, payload.length),
      cacheFiles,
      sink.feed,
    );
    final resultFuture = stream.expand((bytes) => bytes).toList();

    await Future<void>.delayed(Duration.zero);
    sink.add(Uint8List.sublistView(payload, 50 * 1024));
    await sink.flush();

    final result = await resultFuture;
    expect(
      Payload.hash(result),
      Payload.hash(payload.sublist(10 * 1024, 150 * 1024)),
    );
    await sink.close();
  });

  test('supports independent repeated listeners', () async {
    final payload = Payload.generate(128 * 1024);
    final sink = BufferedIOSink(cacheFiles.partial, 0);
    sink.add(payload);
    await sink.close();

    final stream = PartialCacheFileStream(
      StreamRange.validate(0, payload.length, payload.length),
      cacheFiles,
      sink.feed,
    );

    final results = await Future.wait([
      stream.expand((bytes) => bytes).toList(),
      stream.expand((bytes) => bytes).toList(),
    ]);
    expect(Payload.hash(results[0]), Payload.hash(payload));
    expect(Payload.hash(results[1]), Payload.hash(payload));
  });

  test('an open-ended stream completes at the final feed position', () async {
    final payload = Payload.generate(80 * 1024);
    final sink = BufferedIOSink(cacheFiles.partial, 0);
    final stream = PartialCacheFileStream(
      StreamRange.validate(4 * 1024, null, null),
      cacheFiles,
      sink.feed,
    );
    final resultFuture = stream.expand((bytes) => bytes).toList();

    sink.add(payload);
    await sink.close();
    final result = await resultFuture;

    expect(Payload.hash(result), Payload.hash(payload.sublist(4 * 1024)));
  });

  test('opens the completed file after partial-file promotion', () async {
    final payload = Payload.generate(64 * 1024);
    final sink = BufferedIOSink(cacheFiles.partial, 0);
    sink.add(payload);
    await sink.close();
    await cacheFiles.partial.rename(cacheFiles.complete.path);

    final stream = PartialCacheFileStream(
      StreamRange.validate(0, payload.length, payload.length),
      cacheFiles,
      sink.feed,
    );
    final result = await stream.expand((bytes) => bytes).toList();

    expect(Payload.hash(result), Payload.hash(payload));
  });

  test('fromPartialFile creates lazy streams on demand', () async {
    final payload = Payload.generate(96 * 1024);
    final sink = BufferedIOSink(cacheFiles.partial, 0);
    final headers = CachedResponseHeaders.fromBaseResponse(
      http.Response(
        '',
        HttpStatus.ok,
        headers: {HttpHeaders.contentLengthHeader: '${payload.length}'},
      ),
    );
    final response = StreamResponse.fromPartialFile(
      const IntRange(8 * 1024, 80 * 1024),
      cacheFiles,
      headers,
      sink.feed,
    );

    final firstStream = response.stream;
    final secondStream = response.stream;
    expect(identical(firstStream, secondStream), isFalse);
    expect(response.source, ResponseSource.partialCacheFile);
    response.cancel();

    sink.add(payload);
    await sink.flush();
    final result = await firstStream.expand((bytes) => bytes).toList();
    expect(
      Payload.hash(result),
      Payload.hash(payload.sublist(8 * 1024, 80 * 1024)),
    );
    await sink.close();
  });
}
