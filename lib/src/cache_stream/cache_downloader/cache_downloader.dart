import 'dart:async';
import 'dart:io';

import 'package:http_cache_stream/http_cache_stream.dart';
import 'package:http_cache_stream/src/cache_stream/cache_downloader/buffered_io_sink.dart';
import 'package:http_cache_stream/src/etc/exceptions.dart';
import 'package:http_cache_stream/src/models/config/stream_cache_config.dart';
import 'package:http_cache_stream/src/models/stream_response/stream_request.dart';

import 'downloader.dart';

class CacheDownloader {
  final CacheMetadata _initMetadata;
  final Downloader _downloader;
  final BufferedIOSink _sink;
  final _streamController = StreamController<List<int>>.broadcast(sync: true);
  CacheDownloader._(this._initMetadata, this._downloader, this._sink)
    : _nextBufferPosition =
          _downloader.position + _downloader.cacheConfig.maxBufferSize,
      _sourceLength = _initMetadata.sourceLength;

  factory CacheDownloader.construct(
    CacheMetadata cacheMetadata,
    StreamCacheConfig cacheConfig,
  ) {
    final startPosition = _startPosition(cacheMetadata);
    final downloader = Downloader(
      cacheMetadata.sourceUrl,
      IntRange(startPosition),
      cacheConfig,
    );
    final sink = BufferedIOSink(
      cacheMetadata.partialCacheFile,
      start: startPosition,
    );
    return CacheDownloader._(cacheMetadata, downloader, sink);
  }

  Future<void> download({
    required final void Function(Object e) onError,
    required final void Function(CachedResponseHeaders headers) onHeaders,
    required final void Function(int position) onPosition,
    required final Future<void> Function() onComplete,
    required final void Function(int? percent) onProgress,
  }) async {
    if (_updateProgress(downloadPosition)) {
      final initProgress = _progressPercent;
      onProgress(initProgress);
      if (initProgress != null && initProgress > 20) {
        onPosition(
          downloadPosition,
        ); //If progress is already > 20%, fulfill queued requests before starting download
      }
    }
    return _downloader
        .download(
          onError: (error) {
            ///TODO: Decide if non-fatal errors should be added to [streamController] to inform subscribers
            assert(
              error is! InvalidCacheException,
              'InvalidCacheException should be handled in the future',
            );
            onError(error);
          },
          onResponse: (response) {
            final cacheHttpHeaders = CachedResponseHeaders.fromHttpResponse(
              response,
            );
            if (_downloader.downloadRange.start > 0 &&
                _initMetadata.headers?.validate(cacheHttpHeaders) == false) {
              throw CacheSourceChangedException(sourceUrl);
            }
            _sourceLength = cacheHttpHeaders.sourceLength;
            _acceptRangeRequests =
                _sourceLength != null && cacheHttpHeaders.acceptsRangeRequests;
            onHeaders(cacheHttpHeaders);
          },
          onData: (data) {
            assert(
              data.isNotEmpty,
              'CacheDownloader: onData: Data should not be empty',
            );
            _sink.add(data);
            _streamController.add(data);
            final position = _downloader.position;
            onPosition(position);
            if (_updateProgress(position)) {
              onProgress(_progressPercent);
            }
            if (position > _nextBufferPosition) {
              _buffer();
            }
          },
        )
        .catchError(onError, test: (e) => e is! InvalidCacheException)
        .then((_) async {
          await _flush();
          final bufferedCacheLength = _sink.file.statSync().size;
          final sourceLength =
              _sourceLength ??=
                  (_downloader.isDone ? _downloader.position : null);
          if (bufferedCacheLength == sourceLength) {
            await onComplete();
          } else if (bufferedCacheLength != downloadPosition) {
            throw InvalidCacheLengthException(
              sourceUrl,
              bufferedCacheLength,
              downloadPosition,
            );
          }
        })
        .whenComplete(() {
          if (!_downloader.isDone && _streamController.hasListener) {
            _streamController.addError(DownloadStoppedException(sourceUrl));
          }
          _sink.close().ignore();
          _streamController.close().ignore();
        });
  }

  Future<void> cancel() {
    _downloader.close();
    return _streamController.done; // Wait for the stream to be closed
  }

  void _buffer() {
    if (_sink.isFlushing) {
      _downloader
          .pause(); //Pause upstream if we are receiving more data than we can write
      _flush().whenComplete(() {
        _downloader.resume();
      });
    } else {
      _flush().ignore(); //Flush the sink
    }
  }

  Future<void> _flush() {
    _nextBufferPosition = downloadPosition + _cacheConfig.maxBufferSize;
    return _sink.flush();
  }

  void processRequests(List<StreamRequest> requests) async {
    try {
      _downloader.pause();
      await _flush();
      if (isClosed) {
        throw DownloadStoppedException(sourceUrl);
      }
      assert(partialCacheFile.statSync().size == downloadPosition);

      for (final request in requests) {
        final response = StreamResponse.fromCacheStream(
          request.range,
          partialCacheFile,
          _streamController.stream,
          downloadPosition,
          _sourceLength,
        );
        request.complete(response);
      }
    } catch (e) {
      for (final request in requests) {
        request.completeError(e);
      }
    } finally {
      _downloader.resume();
    }
  }

  bool _updateProgress(int position) {
    int? progressPercent;
    final sourceLength = _sourceLength;
    if (sourceLength != null && sourceLength > 0) {
      progressPercent = ((position / sourceLength) * 100).floor();
    }
    if (_progressPercent == progressPercent) return false;
    _progressPercent = progressPercent;
    return true;
  }

  bool? _acceptRangeRequests;
  int? _progressPercent;
  int? _sourceLength;
  int _nextBufferPosition;
  int get downloadPosition => _downloader.position;
  Uri get sourceUrl => _downloader.sourceUrl;
  bool get isClosed => _downloader.isClosed;
  File get partialCacheFile => _sink.file;
  bool get acceptRangeRequests => _acceptRangeRequests == true;
  StreamCacheConfig get _cacheConfig => _downloader.cacheConfig;
}

int _startPosition(CacheMetadata cacheMetadata) {
  final partialCacheFile = cacheMetadata.partialCacheFile;
  final partialCacheStat = partialCacheFile.statSync();
  final partialCacheSize = partialCacheStat.size;
  if (partialCacheStat.type != FileSystemEntityType.file) {
    partialCacheFile.createSync(recursive: true); //Create the file
  } else if (partialCacheSize == 0 ||
      cacheMetadata.headers?.acceptsRangeRequests == true) {
    return partialCacheSize; //Return the size of the partial cache
  }
  return 0;
}
