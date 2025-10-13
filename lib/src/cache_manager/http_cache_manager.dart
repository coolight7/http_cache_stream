import 'dart:async';
import 'dart:io';

import 'package:http_cache_stream/src/cache_server/local_cache_server.dart';
import 'package:http_cache_stream/src/cache_stream/cache_downloader/custom_http_client.dart';
import 'package:http_cache_stream/src/etc/extensions.dart';
import 'package:http_cache_stream/src/models/metadata/cache_files.dart';

import '../../http_cache_stream.dart';
import '../etc/const.dart';

class HttpCacheManager {
  final LocalCacheServer _server;
  final GlobalCacheConfig config;
  final Map<String, HttpCacheStream> _streams = {};
  final List<HttpCacheServer> _cacheServers = [];

  HttpCacheManager._(this._server, this.config) {
    _server.start((request) {
      return getExistingStream(request.uri);
    });
  }

  ///Create a [HttpCacheStream] instance for the given URL. If an instance already exists, the existing instance will be returned.
  ///Use [file] to specify the output file to save the downloaded content to. If not provided, a file will be created in the cache directory (recommended).
  HttpCacheStream createStream(
    final Uri sourceUrl, {
    final File? file,
    final StreamCacheConfig? config,
  }) {
    assert(!isDisposed,
        'HttpCacheManager is disposed. Cannot create new streams.');
    final existingStream = getExistingStream(sourceUrl);
    if (existingStream != null) {
      //Retain the stream to prevent it from being disposed
      existingStream.retain();
      return existingStream;
    }
    final cacheStream = HttpCacheStream(
      sourceUrl: sourceUrl,
      cacheUrl: _server.getCacheUrl(sourceUrl),
      files: file != null
          ? CacheFiles.fromFile(file)
          : _defaultCacheFiles(sourceUrl),
      config: config ?? createStreamConfig(),
    );
    final key = sourceUrl.requestKey;
    //Remove when stream is disposed
    cacheStream.future.whenComplete(
      () => _streams.remove(key),
    );
    _streams[key] = cacheStream; //Add to the stream map
    return cacheStream;
  }

  ///Creates a [HttpCacheServer] instance for a source Uri. This server will redirect requests to the given source and create [HttpCacheStream] instances for each request.
  ///[autoDisposeDelay] is the delay before a stream is disposed after all requests are done.
  ///Optionally, you can provide a [StreamCacheConfig] to be used for the streams created by this server.
  ///This feature is experimental.
  Future<HttpCacheServer> createServer(
    final Uri source, {
    final Duration autoDisposeDelay = const Duration(seconds: 15),
    final StreamCacheConfig? config,
  }) async {
    final cacheServer = HttpCacheServer(
      Uri(
        scheme: source.scheme,
        host: source.host,
        port: source.port,
      ),
      await LocalCacheServer.init(),
      autoDisposeDelay,
      config ?? createStreamConfig(),
      createStream,
    );
    _cacheServers.add(cacheServer);
    cacheServer.future.whenComplete(() => _cacheServers.remove(cacheServer));
    return cacheServer;
  }

  /// Pre-caches the URL and returns the cache file. If the cache file already exists, it will be returned immediately.
  /// If the download completes before the stream is used, the stream will automatically be disposed.
  FutureOr<File> preCacheUrl(final Uri sourceUrl, {final File? file}) {
    final completeCacheFile = file ?? _defaultCacheFiles(sourceUrl).complete;
    if (completeCacheFile.existsSync()) {
      return completeCacheFile;
    }
    final cacheStream = createStream(sourceUrl, file: file);
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
      CustomHttpClientxx.onLog
          ?.call('HttpCacheManager: Deleting cache file: ${file.path}');
      await file.delete();
    }
  }

  Stream<File> inactiveCacheFiles() async* {
    if (!cacheDir.existsSync()) return;
    final Set<String> activeFilePaths = {};
    for (final stream in allStreams) {
      activeFilePaths.addAll(stream.metadata.cacheFiles.paths);
    }
    await for (final entry
        in cacheDir.list(recursive: true, followLinks: false)) {
      if (entry is File && !activeFilePaths.contains(entry.path)) {
        yield entry;
      }
    }
  }

  ///Get a list of [CacheMetadata].
  ///
  ///Specify [active] to filter between metadata for active and inactive [HttpCacheStream] instances. If null, all [CacheMetadata] will be returned.
  Future<List<CacheMetadata>> cacheMetadataList({final bool? active}) async {
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
  CacheMetadata? getCacheMetadata(final Uri sourceUrl) {
    return getExistingStream(sourceUrl)?.metadata ??
        CacheMetadata.fromCacheFiles(_defaultCacheFiles(sourceUrl));
  }

  ///Gets [CacheFiles] for the given URL. Does not check if any cache files exists.
  CacheFiles getCacheFiles(final Uri sourceUrl) {
    return getExistingStream(sourceUrl)?.metadata.cacheFiles ??
        _defaultCacheFiles(sourceUrl);
  }

  /// Returns the existing [HttpCacheStream] for the given URL, or null if it doesn't exist.
  /// The input [url] can either be [sourceUrl] or [cacheUrl].
  HttpCacheStream? getExistingStream(final Uri url) {
    return _streams[url.requestKey];
  }

  ///Returns the existing [HttpCacheServer] for the given source URL, or null if it doesn't exist.
  HttpCacheServer? getExistingServer(final Uri source) {
    for (final cacheServer in _cacheServers) {
      final serverSource = cacheServer.source;
      if (serverSource.host == source.host &&
          serverSource.port == source.port &&
          serverSource.scheme == source.scheme) {
        return cacheServer;
      }
    }
    return null;
  }

  CacheFiles _defaultCacheFiles(Uri sourceUrl) {
    return CacheFiles.fromUrl(config.cacheDirectory, sourceUrl);
  }

  ///Create a [StreamCacheConfig] that inherits the current [GlobalCacheConfig]. This config is used to create [HttpCacheStream] instances.
  StreamCacheConfig createStreamConfig() => StreamCacheConfig.construct(this);

  ///Disposes the current [HttpCacheManager] and all resources.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    HttpCacheManager._instance = null;
    HttpCacheManager._initCompleter = null;
    for (final stream in _streams.values) {
      stream.dispose(force: true).ignore();
    }
    for (final httpCacheServer in _cacheServers) {
      httpCacheServer.dispose().ignore();
    }
    _streams.clear();
    _cacheServers.clear();
    config.httpClient.close(force: true);
    return _server.close();
  }

  Directory get cacheDir => config.cacheDirectory;
  Iterable<HttpCacheStream> get allStreams => _streams.values;
  bool _disposed = false;
  bool get isDisposed => _disposed;

  ///Initializes [HttpCacheManager]. If already initialized, returns the existing instance.
  ///[cacheDir] is the directory where the cache files will be stored. If null, the default cache directory will be used (see [GlobalCacheConfig.defaultCacheDirectory]).
  ///[httpClient] is the custom http client to use. If null, a default http client will be used.
  ///You can also provide [GlobalCacheConfig] for the initial configuration.
  static Future<HttpCacheManager> init({
    final Directory? cacheDir,
  }) async {
    if (_instance != null) {
      return instance;
    }
    if (_initCompleter != null) {
      return _initCompleter!.future;
    }
    _initCompleter = Completer<HttpCacheManager>();
    try {
      final config = GlobalCacheConfig(
        cacheDirectory:
            cacheDir ?? await GlobalCacheConfig.defaultCacheDirectory(),
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
  static HttpCacheManager? get instanceOrNull => _instance;
}
