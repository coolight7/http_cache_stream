import 'dart:async';
import 'dart:io';

import 'package:http_cache_stream/http_cache_stream.dart';
import 'package:http_cache_stream/src/cache_stream/cache_downloader/buffered_io_sink.dart';
import 'package:http_cache_stream/src/etc/exceptions.dart';
import 'package:http_cache_stream/src/models/stream_response/stream_request.dart';

import 'downloader.dart';

class CacheDownloader {
  final CacheMetadata _initMetadata;
  final Downloader _downloader;
  final BufferedIOSink _sink;
  final _streamController = StreamController<List<int>>.broadcast(sync: true);
  final _completer = Completer<void>();
  CacheDownloader._(this._initMetadata, this._downloader, this._sink)
      : _nextBufferPosition =
            _downloader.position + _downloader.streamConfig.maxBufferSize,
        _sourceLength = _initMetadata.sourceLength;

  factory CacheDownloader.construct(
    final CacheMetadata cacheMetadata,
    final StreamCacheConfig cacheConfig,
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
  }) {
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
          onHeaders: (cacheHttpHeaders) {
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
              if (_sink.isFlushing) {
                _downloader
                    .pause(); //Pause upstream if we are receiving more data than we can write
                _flushBuffer().whenComplete(() =>
                    _downloader.resume()); //Resume upstream after flushing
              } else {
                _flushBuffer().ignore(); //Flush the sink
              }
            }
          },
        )
        .catchError(onError, test: (e) => e is! InvalidCacheException)
        .then((_) async {
          await _sink.close(
              flushBuffer:
                  true); //Flushes all buffered data and closes the sink
          final bufferedCacheLength = _sink.file.statSync().size;
          final sourceLength = _sourceLength ??=
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
        .whenComplete(
          () {
            if (!_completer.isCompleted) {
              _completer.complete();
            }
            if (!_sink.isClosed) {
              ///The sink is not closed on invalid cache exception, so we need to close it here
              _sink.close(flushBuffer: false).ignore();
            }
            if (!_downloader.isDone && _streamController.hasListener) {
              _streamController.addError(DownloadStoppedException(sourceUrl));
            }
            _streamController.close().ignore();
          },
        );
  }

  /// Cancels the download and closes the stream. An error must be provided to indicate the reason for cancellation.
  Future<void> cancel(final Object error) {
    _downloader.close(error);
    return _completer.future;
  }

  Future<void> _flushBuffer() {
    _nextBufferPosition = downloadPosition + _cacheConfig.maxBufferSize;
    return _sink.flush();
  }

  void processRequest(final StreamRequest request) {
    _processingRequests.add(request);
    if (!_isProcessingRequests) {
      _processRequests();
    }
  }

  void _processRequests() async {
    if (_isProcessingRequests) return;
    _isProcessingRequests = true;
    try {
      _downloader.pause();
      await _flushBuffer();
      if (_downloader.isClosed) {
        throw DownloadStoppedException(sourceUrl);
      }
      assert(partialCacheFile.statSync().size == downloadPosition,
          'CacheDownloader: processRequests: partialCacheFileSize (${partialCacheFile.statSync().size}) != downloadPosition ($downloadPosition)');

      _processingRequests.removeWhere((request) {
        if (!request.isComplete) {
          final response = StreamResponse.fromCacheStream(
            request.range,
            partialCacheFile,
            _streamController.stream,
            downloadPosition,
            _sourceLength,
          );
          request.complete(response);
        }
        return true;
      });
    } catch (e) {
      _processingRequests.removeWhere((request) {
        request.completeError(e);
        return true;
      });
    } finally {
      _isProcessingRequests = false;
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

  bool _isProcessingRequests = false;
  final List<StreamRequest> _processingRequests = [];
  bool? _acceptRangeRequests;
  int? _progressPercent;
  int? _sourceLength;
  int _nextBufferPosition;
  int get downloadPosition => _downloader.position;
  Uri get sourceUrl => _downloader.sourceUrl;
  bool get isActive => _downloader.isActive;
  File get partialCacheFile => _sink.file;
  bool get acceptRangeRequests => _acceptRangeRequests == true;
  StreamCacheConfig get _cacheConfig => _downloader.streamConfig;
}

int _startPosition(final CacheMetadata cacheMetadata) {
  final partialCacheFile = cacheMetadata.cacheFiles.partial;
  final partialCacheStat = partialCacheFile.statSync();
  final partialCacheSize = partialCacheStat.size;
  if (partialCacheStat.type != FileSystemEntityType.file) {
    partialCacheFile.createSync(recursive: true); //Create the file
  } else if (partialCacheSize > 0 &&
      cacheMetadata.headers?.canResumeDownload() == true) {
    return partialCacheSize; //Return the size of the partial cache
  }
  return 0;
}
