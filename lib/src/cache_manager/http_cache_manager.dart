import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http_cache_stream/src/cache_server/local_cache_server.dart';
import 'package:http_cache_stream/src/etc/extensions.dart';
import 'package:http_cache_stream/src/models/metadata/cache_files.dart';

import '../../http_cache_stream.dart';
import '../etc/const.dart';

class HttpCacheManager {
  final LocalCacheServer _server;
  final GlobalCacheConfig config;
  final Map<String, HttpCacheStream> _streams = {};
  final List<HttpCacheServer> _httpCacheServers = [];
  HttpCacheManager._(this._server, this.config) {
    _server.start((request) => getExistingStream(request.uri));
  }

  ///Create a [HttpCacheStream] instance for the given URL. If an instance already exists, the existing instance will be returned.
  ///Use [cacheFile] to specify the output file to save the downloaded content to. If not provided, a file will be created in the cache directory (recommended).
  HttpCacheStream createStream(Uri sourceUrl, {File? cacheFile, StreamCacheConfig? config}) {
    assert(!isDisposed, 'HttpCacheManager is disposed. Cannot create new streams.');
    final existingStream = getExistingStream(sourceUrl);
    if (existingStream != null) {
      existingStream.retain(); //Retain the stream to prevent it from being disposed
      return existingStream;
    }
    final cacheStream = HttpCacheStream(
      sourceUrl: sourceUrl,
      cacheUrl: _server.getCacheUrl(sourceUrl),
      files: cacheFile != null ? CacheFiles.fromFile(cacheFile) : _defaultCacheFiles(sourceUrl),
      config: config ?? createStreamConfig(),
    );
    final key = sourceUrl.requestKey;
    cacheStream.future.whenComplete(
      () => _streams.remove(key),
    ); //Remove when stream is disposed
    _streams[key] = cacheStream; //Add to the stream map
    return cacheStream;
  }

  ///Creates a [HttpCacheServer] instance for a source Uri. This server will redirect requests to the given source and create [HttpCacheStream] instances for each request.
  ///[autoDisposeDelay] is the delay before a stream is disposed after all requests are done.
  ///Optionally, you can provide a [StreamCacheConfig] to be used for the streams created by this server.
  ///This feature is experimental.
  Future<HttpCacheServer> createServer(
    Uri source, {
    final Duration autoDisposeDelay = const Duration(seconds: 15),
    StreamCacheConfig? config,
  }) async {
    final cacheServer = HttpCacheServer(
      Uri(
        scheme: source.scheme,
        host: source.host,
        port: source.port,
      ),
      await LocalCacheServer.init(),
      autoDisposeDelay,
      (sourceUrl) => createStream(sourceUrl, config: config),
    );
    _httpCacheServers.add(cacheServer);
    cacheServer.future.whenComplete(() => _httpCacheServers.remove(cacheServer));
    return cacheServer;
  }

  /// Pre-caches the URL and returns the cache file. If the cache file already exists, it will be returned immediately.
  /// If the download completes before the stream is used, the stream will automatically be disposed.
  Future<File> preCacheUrl(Uri sourceUrl, {File? cacheFile}) {
    final completeCacheFile = cacheFile ?? _defaultCacheFiles(sourceUrl).complete;
    if (completeCacheFile.existsSync()) {
      return Future.value(completeCacheFile);
    }
    final cacheStream = createStream(sourceUrl, cacheFile: cacheFile);
    return cacheStream.download().whenComplete(() => cacheStream.dispose());
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
      if (kDebugMode) {
        print('HttpCacheManager: Deleting cache file: ${file.path}');
      }
      await file.delete();
    }
  }

  Stream<File> inactiveCacheFiles() async* {
    if (!cacheDir.existsSync()) return;
    final Set<String> activeFilePaths = {};
    for (final stream in allStreams) {
      activeFilePaths.addAll(stream.metadata.cacheFiles.paths);
    }
    await for (final entry in cacheDir.list(recursive: true, followLinks: false)) {
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
    return getExistingStream(sourceUrl)?.metadata ?? CacheMetadata.fromCacheFiles(_defaultCacheFiles(sourceUrl));
  }

  ///Gets [CacheFiles] for the given URL. Does not check if any cache files exists.
  CacheFiles getCacheFiles(Uri sourceUrl) {
    return getExistingStream(sourceUrl)?.metadata.cacheFiles ?? _defaultCacheFiles(sourceUrl);
  }

  /// Returns the existing [HttpCacheStream] for the given URL, or null if it doesn't exist.
  /// The input [url] can either be [sourceUrl] or [cacheUrl].
  HttpCacheStream? getExistingStream(Uri url) {
    return _streams[url.requestKey];
  }

  CacheFiles _defaultCacheFiles(Uri sourceUrl) {
    return CacheFiles.fromUrl(config.cacheDirectory, sourceUrl);
  }

  ///Create a [StreamCacheConfig] that inherits the current [GlobalCacheConfig]. This config is used to create [HttpCacheStream] instances.
  StreamCacheConfig createStreamConfig() => StreamCacheConfig(config);

  ///Disposes the current [HttpCacheManager] and all [HttpCacheStream] instances
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    HttpCacheManager._instance = null;
    HttpCacheManager._initCompleter = null;
    for (final stream in _streams.values) {
      stream.dispose(force: true);
    }
    for (final httpCacheServer in _httpCacheServers) {
      httpCacheServer.dispose();
    }
    _streams.clear();
    _httpCacheServers.clear();
    await _server.close();
    if (config.customHttpClient == null) {
      config.httpClient.close(); // Close the default http client
    }
  }

  Directory get cacheDir => config.cacheDirectory;
  Iterable<HttpCacheStream> get allStreams => _streams.values;
  bool _disposed = false;
  bool get isDisposed => _disposed;

  ///Initializes [HttpCacheManager]. If already initialized, returns the existing instance.
  ///[cacheDir] is the directory where the cache files will be stored. If null, the default cache directory will be used (see [GlobalCacheConfig.defaultCacheDirectory]).
  ///[customHttpClient] is the custom http client to use. If null, a default http client will be used.
  ///You can also provide [GlobalCacheConfig] for the initial configuration.
  static Future<HttpCacheManager> init({
    Directory? cacheDir,
    http.Client? customHttpClient,
    GlobalCacheConfig? config,
  }) async {
    assert(config == null || (cacheDir == null && customHttpClient == null),
        'Cannot set cacheDir or httpClient when config is provided. Set them in the config instead.');
    if (_instance != null) {
      return instance;
    }
    if (_initCompleter != null) {
      return _initCompleter!.future;
    }
    _initCompleter = Completer<HttpCacheManager>();
    try {
      config ??= GlobalCacheConfig(
        cacheDirectory: cacheDir ?? await GlobalCacheConfig.defaultCacheDirectory(),
        customHttpClient: customHttpClient,
      );
      final httpCacheServer = await LocalCacheServer.init();
      final httpCacheManager = HttpCacheManager._(httpCacheServer, config);
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
