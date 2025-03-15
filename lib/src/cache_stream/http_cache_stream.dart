import 'dart:async';
import 'dart:io';

import 'package:http_cache_stream/src/cache_stream/cache_downloader/cache_downloader.dart';
import 'package:http_cache_stream/src/cache_stream/cache_downloader/downloader.dart';
import 'package:http_cache_stream/src/models/config/stream_cache_config.dart';
import 'package:http_cache_stream/src/models/metadata/cache_files.dart';
import 'package:http_cache_stream/src/models/metadata/cached_response_headers.dart';
import 'package:http_cache_stream/src/models/stream_response/int_range.dart';
import 'package:rxdart/rxdart.dart';

import '../etc/exceptions.dart';
import '../models/metadata/cache_metadata.dart';
import '../models/stream_response/stream_request.dart';
import '../models/stream_response/stream_response.dart';

class HttpCacheStream {
  ///The source Url of the file to be downloaded (e.g., https://example.com/file.mp3)
  final Uri sourceUrl;

  ///The Url of the cached stream (e.g., http://127.0.0.1:8080/file.mp3)
  final Uri cacheUrl;

  final CacheFiles _cacheFiles;

  final StreamCacheConfig config;

  final List<StreamRequest> _queuedRequests = [];
  final _progressSubject = BehaviorSubject<double?>();
  CacheDownloader? _cacheDownloader; //The active cache downloader, if any. This can be used to cancel the download.
  int _retainCount = 1; //The number of times the stream has been retained
  Future<File>? _downloadFuture; //The future for the current download, if any.
  Future<bool>? _validateCacheFuture;
  late CacheMetadata _cacheMetadata = CacheMetadata.construct(
    _cacheFiles,
    sourceUrl,
  );
  HttpCacheStream(
    this.sourceUrl,
    this.cacheUrl,
    this._cacheFiles,
    this.config,
  ) {
    final cachedHeaders = metadata.headers;
    if (cachedHeaders == null || cachedHeaders.sourceLength == null) return;
    if (_updateCacheProgress() == 1.0 && config.validateOutdatedCache && cachedHeaders.shouldRevalidate()) {
      validateCache(force: true, resetInvalid: true).ignore();
    }
  }

  Future<StreamResponse> request([int? start, int? end]) async {
    _checkDisposed();
    if (_validateCacheFuture != null) {
      await _validateCacheFuture!;
    }
    final range = IntRange.construct(start, end, metadata.sourceLength);
    final cacheFileStat = cacheFile.statSync();
    if (cacheFileStat.size > 0) {
      return StreamResponse.fromFile(range, cacheFile, cacheFileStat.size);
    }
    final streamRequest = StreamRequest.construct(range);
    _queuedRequests.add(streamRequest); //Add request to queue
    if (!isDownloading) {
      download().ignore(); //Start download
    }
    return streamRequest.response;
  }

  ///Validates the cache. Returns true if the cache is valid, false if it is not, and null if cache does not exist or is downloading.
  ///Cache is only revalidated if [CachedResponseHeaders.shouldRevalidate()] or [force] is true.
  Future<bool?> validateCache({
    bool force = false,
    bool resetInvalid = false,
  }) async {
    if (_validateCacheFuture != null) {
      return _validateCacheFuture;
    }
    if (!isCached || isDownloading) return null;
    if (!force && metadata.headers?.shouldRevalidate() == false) return true;
    _validateCacheFuture = CachedResponseHeaders.fromUri(
      sourceUrl,
      config.combinedRequestHeaders(),
    ).then((latestHeaders) async {
      final currentHeaders = metadata.headers ?? CachedResponseHeaders.fromFile(cacheFile);
      if (currentHeaders?.validate(latestHeaders) == true) {
        _setCachedResponseHeaders(latestHeaders);
        return true;
      } else {
        if (resetInvalid) await resetCache();
        return false;
      }
    }).whenComplete(() {
      _validateCacheFuture = null;
      _updateCacheProgress();
    });
    return _validateCacheFuture;
  }

  ///Downloads and returns [cacheFile]. If the file already exists, returns immediately. This method can be called multiple times, and the download will only be started once.
  Future<File> download() async {
    if (_downloadFuture != null) {
      return _downloadFuture!;
    }
    _checkDisposed();
    final downloadCompleter = Completer<File>();
    _downloadFuture = downloadCompleter.future;

    bool isComplete() {
      if (downloadCompleter.isCompleted) return true;
      final completed = _updateCacheProgress() == 1.0;
      if (completed) {
        downloadCompleter.complete(cacheFile);
      }
      return completed;
    }

    while (isRetained && !isComplete()) {
      try {
        final downloader = (_cacheDownloader = CacheDownloader.construct(metadata, config));
        await downloader.download(
          onPosition: (position) {
            if (_queuedRequests.isEmpty) return;
            final rangeThreshold = downloader.acceptRangeRequests ? config.rangeRequestSplitThreshold : null;
            List<StreamRequest>? readyCacheRequests;
            _queuedRequests.removeWhere((request) {
              final bytesRemaining = request.start - position;
              if (bytesRemaining <= 0) {
                (readyCacheRequests ??= <StreamRequest>[]).add(request);
                return true;
              } else if (rangeThreshold != null && bytesRemaining > rangeThreshold) {
                request.complete(
                  StreamResponse.fromDownload(
                    sourceUrl,
                    request.range,
                    metadata.sourceLength,
                    config,
                  ),
                );
                return true;
              } else {
                return false;
              }
            });
            if (readyCacheRequests != null) {
              downloader.processRequests(readyCacheRequests!);
            }
          },
          onComplete: () async {
            final cachedHeaders = metadata.headers!;
            if (cachedHeaders.sourceLength != downloader.downloadPosition || !cachedHeaders.acceptsRangeRequests) {
              _setCachedResponseHeaders(
                cachedHeaders.setSourceLength(downloader.downloadPosition),
              );
            }
            await metadata.partialCacheFile.rename(cacheFile.path);
          },
          onProgress: (percentage) {
            //Limit to 99% to prevent 100% progress before write is complete
            final progress = percentage == null ? null : (percentage / 100).clamp(0, .99).toDouble();
            _updateProgressStream(progress);
          },
          onHeaders: (cacheHttpHeaders) {
            _setCachedResponseHeaders(cacheHttpHeaders);
          },
          onError: (e) {
            _addError(e, closeRequests: true);
          },
        );
      } catch (e) {
        if (e is InvalidCacheException) {
          await resetCache();
        }
        if (isRetained) {
          _addError(e, closeRequests: true);
          await Future.delayed(const Duration(seconds: 5));
        }
      } finally {
        _cacheDownloader = null;
      }
    }
    if (!isComplete()) {
      final error = DownloadStoppedException(sourceUrl);
      downloadCompleter.future.ignore(); // Prevent unhandled error during completion
      downloadCompleter.completeError(error);
      _addError(error, closeRequests: true);
    }
    _downloadFuture = null;
    return downloadCompleter.future;
  }

  ///Disposes this [HttpCacheStream]. This method should be called when you are done with the stream.
  ///If [force] is true, the stream will be disposed immediately, regardless of the [retain] count. [retain] is incremented when the stream is obtained using [HttpCacheManager.createStream].
  ///Returns a future once this stream is disposed.
  Future<void> dispose({bool force = false}) async {
    if (isDisposed) return;
    if (!force && _retainCount > 1) {
      _retainCount--;
      return _progressSubject.done;
    }
    _retainCount = 0;
    if (_cacheDownloader != null) {
      await _cacheDownloader!.cancel().catchError(
            (_) {},
          ); //Allow downloader to complete cleanly
      if (isRetained) {
        return _progressSubject.done; //Check if retained while waiting for download to stop
      }
    }
    if (_queuedRequests.isNotEmpty) {
      _addError(CacheStreamDisposedException(sourceUrl), closeRequests: true);
    }
    _progressSubject.close().ignore(); //This implicitly sets [disposed] to true and completes the future
  }

  ///Resets the cache files used by this [HttpCacheStream], interrupting any ongoing download.
  Future<void> resetCache() async {
    if (_cacheDownloader?.isClosed == false) {
      _cacheDownloader!.cancel().ignore();
    }
    _cacheMetadata = _cacheMetadata.copyWith(headers: null);
    _updateProgressStream(null);
    await _cacheFiles.delete();
    if (!isDownloading && _queuedRequests.isNotEmpty) {
      download().ignore(); //Start download
    }
  }

  void _setCachedResponseHeaders(CachedResponseHeaders headers) {
    _validateRequests(_cacheMetadata.sourceLength, headers.sourceLength);
    _cacheMetadata = _cacheMetadata.copyWith(headers: headers)..save();
  }

  ///Validates the requests in the queue. If any requests exceed the new source length, they are removed from the queue and completed with a [RangeError].
  void _validateRequests(int? previousSourceLength, int? nextSourceLength) {
    if (_queuedRequests.isEmpty || nextSourceLength == null || previousSourceLength == nextSourceLength) {
      return;
    }
    _queuedRequests.removeWhere((request) {
      if (request.range.exceeds(nextSourceLength)) {
        request.completeError(
          RangeError.range(request.range.greatest, 0, nextSourceLength),
        );
        return true;
      }
      return false;
    });
  }

  double? _updateCacheProgress() {
    final cacheProgress = metadata.cacheProgress();
    _updateProgressStream(cacheProgress);
    return cacheProgress;
  }

  void _updateProgressStream(double? value) {
    if (value == 1.0) {
      _queuedRequests.removeWhere((request) {
        request.complete(
          StreamResponse.fromFile(
            request.range,
            cacheFile,
            metadata.sourceLength,
          ),
        );
        return true;
      });
    }
    if (_progressSubject.valueOrNull != value && !_progressSubject.isClosed) {
      _progressSubject.add(value);
    }
  }

  void _addError(Object error, {final bool closeRequests = true}) {
    if (closeRequests) {
      _queuedRequests.removeWhere((request) {
        request.completeError(error);
        return true;
      });
    }
    if (isRetained && !_progressSubject.isClosed) {
      _progressSubject.addError(error);
    }
  }

  void _checkDisposed() {
    if (isDisposed) {
      throw CacheStreamDisposedException(sourceUrl);
    }
  }

  ///Returns a stream of download progress 0-1, rounded to 2 decimal places, and any errors that occur.
  ///Returns null if the source length is unknown. Returns 1.0 only if the cache file exists.
  Stream<double?> get progressStream => _progressSubject.stream;

  ///Returns true if the cache file exists.
  bool get isCached => cacheFile.statSync().size > 0;

  ///If this [HttpCacheStream] has been disposed. A disposed stream cannot be used.
  bool get isDisposed => _progressSubject.isClosed;

  ///If this [HttpCacheStream] is actively downloading data to cache file
  bool get isDownloading => _downloadFuture != null;

  ///If this [HttpCacheStream] is retained. A retained stream will not be disposed until the [dispose] method is called the same number of times as [retain] was called.
  bool get isRetained => _retainCount > 0;

  ///The current download progress 0-1, rounded to 2 decimal places. Returns null if the source length is unknown. Returns 1.0 only if the cache file exists.
  double? get progress => _progressSubject.valueOrNull;

  ///Returns the last emitted error, or null if error events haven't yet been emitted.
  Object? get lastErrorOrNull => _progressSubject.errorOrNull;

  ///The current [CacheMetadata] for this [HttpCacheStream].
  CacheMetadata get metadata => _cacheMetadata;

  ///The output cache file for this [HttpCacheStream]. This is the file that will be used to save the downloaded content.
  File get cacheFile => _cacheFiles.complete;

  ///Retains this [HttpCacheStream] instance. This method is automatically called when the stream is obtained using [HttpCacheManager.createStream].
  ///The stream will not be disposed until the [dispose] method is called the same number of times as this method.
  void retain() {
    _checkDisposed();
    _retainCount = _retainCount <= 0 ? 1 : _retainCount + 1;
  }

  ///Returns a future that completes when this [HttpCacheStream] is disposed.
  Future get future => _progressSubject.done;

  @override
  String toString() => 'HttpCacheStream{sourceUrl: $sourceUrl, cacheUrl: $cacheUrl, cacheFile: $cacheFile}';
}
