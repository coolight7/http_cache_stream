import 'dart:async';
import 'dart:io';

import 'package:http_cache_stream/src/cache_manager/http_cache_server.dart';
import 'package:http_cache_stream/src/models/config/stream_cache_config.dart';
import 'package:http_cache_stream/src/models/metadata/cache_files.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../http_cache_stream.dart';
import '../etc/const.dart';

class HttpCacheManager {
  final HttpCacheServer _server;
  final GlobalCacheConfig config;
  final Map<String, HttpCacheStream> _streams = {};

  HttpCacheManager._(this._server, this.config) {
    _server.start(_streamFromUri);
  }

  ///Create a [HttpCacheStream] instance for the given URL. If an instance already exists, the existing instance will be returned.
  ///
  ///Use [File] to specify the output file to save the downloaded content to. If not provided, a file will be created in the cache directory (recommended).
  HttpCacheStream createStream(Uri sourceUrl, {File? file}) {
    final key = _requestKey(sourceUrl);
    HttpCacheStream? httpCacheStream = _streams[key];
    if (httpCacheStream != null) {
      //Retain the stream to prevent it from being disposed
      httpCacheStream.retain();
    } else {
      final cacheUrl = _server.getCacheUrl(sourceUrl);
      final cacheFiles = file != null
          ? CacheFiles.fromFile(file)
          : _defaultCacheFiles(sourceUrl);
      httpCacheStream = HttpCacheStream(
        sourceUrl,
        cacheUrl,
        cacheFiles,
        StreamCacheConfig(config),
      );
      httpCacheStream.future.whenComplete(
        () {
          _streams.remove(key);
        },
      ); //Remove when stream is disposed
      _streams[key] = httpCacheStream;
    }
    return httpCacheStream;
  }

  ///Deletes cache. Does not modify files used by active [HttpCacheStream] instances.
  Future<void> deleteCache({bool partialOnly = false}) async {
    if (!partialOnly && _streams.isEmpty) {
      if (cacheDir.existsSync()) {
        await cacheDir.delete(recursive: true);
      }
      return;
    }
    await for (final file in inactiveCacheFiles()) {
      if (partialOnly && !CacheFileType.isPartial(file)) {
        if (!CacheFileType.isMetadata(file)) continue;
        final completedCacheFile = File(
          file.path.replaceFirst(CacheFileType.metadata.extension, ''),
        );
        if (completedCacheFile.existsSync()) {
          continue; //Do not delete metadata if the cache file exists
        }
      }
      CustomHttpClientxx.onLog?.call('Deleting cache file: ${file.path}');
      await file.delete();
    }
  }

  Stream<File> inactiveCacheFiles() async* {
    if (!cacheDir.existsSync()) return;
    final Set<String> activeFilePaths = {};
    for (final stream in allStreams) {
      activeFilePaths.addAll(stream.metadata.cacheFiles.paths);
    }
    await for (final entry in cacheDir.list(recursive: true)) {
      if (entry is File && !activeFilePaths.contains(entry.path)) {
        yield entry;
      }
    }
  }

  ///Get a list of [CacheMetadata].
  ///
  ///Specify [active] to filter between metadata for active and inactive [HttpCacheStream] instances. If null, all [CacheMetadata] will be returned.
  Future<List<CacheMetadata>> cacheMetadataList({bool? active}) async {
    final List<CacheMetadata> cacheMetadata = [];
    if (active != false) {
      cacheMetadata.addAll(allStreams.map((stream) => stream.metadata));
    }
    if (active != true) {
      await for (final file in inactiveCacheFiles().where(
        CacheFileType.isMetadata,
      )) {
        final savedMetadata = CacheMetadata.load(file);
        if (savedMetadata != null) {
          cacheMetadata.add(savedMetadata);
        }
      }
    }
    return cacheMetadata;
  }

  ///Get the [CacheMetadata] for the given URL. Returns null if the metadata does not exist.
  CacheMetadata? getCacheMetadata(Uri sourceUrl) {
    return _streamFromUri(sourceUrl)?.metadata ??
        CacheMetadata.load(_defaultCacheFiles(sourceUrl).complete);
  }

  ///Gets [CacheFiles] for the given URL. Does not check if any cache files exists.
  CacheFiles getCacheFiles(Uri sourceUrl) {
    return _streamFromUri(sourceUrl)?.metadata.cacheFiles ??
        _defaultCacheFiles(sourceUrl);
  }

  ///Disposes the current [HttpCacheManager] and all [HttpCacheStream] instances
  Future<void> dispose() async {
    HttpCacheManager._instance = null;
    for (final stream in allStreams) {
      stream.dispose(force: true);
    }
    _streams.clear();
    await _server.close();
  }

  Directory get cacheDir => config.cacheDirectory;
  Iterable<HttpCacheStream> get allStreams => _streams.values;

  HttpCacheStream? _streamFromUri(Uri uri) {
    return _streams[_requestKey(uri)];
  }

  CacheFiles _defaultCacheFiles(final Uri sourceUrl) {
    return CacheFiles.fromUrl(config.cacheDirectory, sourceUrl);
  }

  String _requestKey(Uri uri) {
    return '${uri.path}?${uri.query}';
  }

  static Future<HttpCacheManager> init({Directory? cacheDir}) async {
    if (_instance != null) {
      return instance;
    }
    if (_initCompleter != null) {
      return _initCompleter!.future;
    }
    _initCompleter = Completer<HttpCacheManager>();
    try {
      cacheDir ??= Directory(
        p.join((await getTemporaryDirectory()).path, _kCacheDirName),
      );
      final httpCacheConfig = GlobalCacheConfig(cacheDir);
      final httpCacheServer = await HttpCacheServer.init();
      final httpCacheManager = HttpCacheManager._(
        httpCacheServer,
        httpCacheConfig,
      );
      _instance = httpCacheManager;
      _initCompleter!.complete(httpCacheManager);
      return httpCacheManager;
    } catch (e) {
      _initCompleter!.completeError(e);
      rethrow;
    } finally {
      _initCompleter = null;
    }
  }

  static HttpCacheManager get instance {
    if (_instance == null) {
      throw StateError(
        'HttpCacheManager not initialized. Call HttpCacheManager.init() first.',
      );
    }
    return _instance!;
  }

  static Completer<HttpCacheManager>? _initCompleter;
  static HttpCacheManager? _instance;
  static bool get isInitialized => _instance != null;
}

const _kCacheDirName = 'http_cache_stream';
