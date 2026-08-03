import 'dart:async';
import 'dart:io';
import 'dart:math';

import '../../models/cache_files/cache_files.dart';
import '../../models/stream_response/stream_response_range.dart';
import '../cache_downloader/buffered_io_sink.dart';

/// Streams committed bytes from a partial cache file while it is being saved.
///
/// Every listener owns its file handle and read position. When it catches up to
/// the committed position exposed by [feed], it waits for more data while
/// retaining the same file handle.
class PartialCacheFileStream extends Stream<List<int>> {
  static const int _readSize = 64 * 1024;

  final StreamRange range;
  final CacheFiles cacheFiles;
  final PartialCacheFeed feed;
  const PartialCacheFileStream(this.range, this.cacheFiles, this.feed);

  Stream<List<int>> _read() async* {
    int readPosition = range.start;
    final int? requestedEnd = range.absoluteEnd;
    if (requestedEnd != null && readPosition >= requestedEnd) return;

    while (readPosition >= feed.position) {
      if (requestedEnd == null && feed.isClosed) return;
      await feed.waitForPosition(readPosition + 1);
    }

    final RandomAccessFile raf = await _openActiveCacheFile();
    try {
      await raf.setPosition(readPosition);

      while (requestedEnd == null || readPosition < requestedEnd) {
        final int committedEnd = min(feed.position, requestedEnd ?? feed.position);
        final int availableBytes = committedEnd - readPosition;
        if (availableBytes <= 0) {
          if (requestedEnd == null && feed.isClosed) return;
          await feed.waitForPosition(readPosition + 1);
          continue;
        }

        final List<int> bytes = await raf.read(min(_readSize, availableBytes));
        if (bytes.isEmpty) {
          throw FileSystemException(
            'Partial cache file ended before its committed position',
            raf.path,
          );
        }

        readPosition += bytes.length;
        yield bytes;
      }
    } finally {
      await raf.close();
    }
  }

  Future<RandomAccessFile> _openActiveCacheFile() async {
    try {
      return await cacheFiles.activeCacheFile().open();
    } catch (_) {
      // The partial file may have been renamed after activeCacheFile() selected
      // it. Resolve the active path again and retry once.
      return cacheFiles.activeCacheFile().open();
    }
  }

  @override
  StreamSubscription<List<int>> listen(
    final void Function(List<int> event)? onData, {
    final Function? onError,
    final void Function()? onDone,
    final bool? cancelOnError,
  }) {
    return _read().listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }
}
