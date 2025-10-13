import 'dart:io';

import 'package:http_cache_stream/http_cache_stream.dart';
import 'package:http_cache_stream/src/cache_stream/cache_downloader/custom_http_client.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// A singleton configuration class for [HttpCacheManager].
/// This class is used to configure the behavior for all [HttpCacheStream]'s, including the cache directory, HTTP client, request and response headers, and other settings.
/// Hint: You may obtain the default cache directory using the static method `GlobalCacheConfig.defaultCacheDirectory()`.
class GlobalCacheConfig implements CacheConfiguration {
  GlobalCacheConfig({
    required this.cacheDirectory,
    int maxBufferSize = 1024 * 1024 * 25,
    int minChunkSize = 1024,
    int? rangeRequestSplitThreshold,
    Map<String, String>? requestHeaders,
    Map<String, String>? responseHeaders,
    this.copyCachedResponseHeaders = false,
    this.validateOutdatedCache = false,
    this.savePartialCache = true,
    this.saveMetadata = true,
    this.onCacheDone,
  })  : httpClient = CustomHttpClientxx(),
        requestHeaders = requestHeaders ?? {},
        responseHeaders = responseHeaders ?? {},
        _maxBufferSize =
            CacheConfiguration.validateMaxBufferSize(maxBufferSize),
        _minChunkSize = CacheConfiguration.validateMinChunkSize(minChunkSize),
        _rangeRequestSplitThreshold =
            CacheConfiguration.validateRangeRequestSplitThreshold(
                rangeRequestSplitThreshold);

  final Directory cacheDirectory;

  @override
  final CustomHttpClientxx httpClient;

  @override
  Map<String, String> requestHeaders;
  @override
  Map<String, String> responseHeaders;

  @override
  bool copyCachedResponseHeaders;

  @override
  bool validateOutdatedCache;

  @override
  bool savePartialCache;

  @override
  bool saveMetadata;

  int? _rangeRequestSplitThreshold;
  @override
  int? get rangeRequestSplitThreshold => _rangeRequestSplitThreshold;
  @override
  set rangeRequestSplitThreshold(int? value) {
    _rangeRequestSplitThreshold =
        CacheConfiguration.validateRangeRequestSplitThreshold(value);
  }

  int _minChunkSize;
  @override
  int get minChunkSize => _minChunkSize;
  @override
  set minChunkSize(int value) {
    _minChunkSize = CacheConfiguration.validateMinChunkSize(value);
  }

  int _maxBufferSize;
  @override
  int get maxBufferSize => _maxBufferSize;
  @override
  set maxBufferSize(int value) {
    _maxBufferSize = CacheConfiguration.validateMaxBufferSize(value);
  }

  /// Register a callback function to be called when a cache stream download is completed.
  void Function(HttpCacheStream cacheStream, File cacheFile)? onCacheDone;

  /// Returns the default cache directory for the application. Useful when constructing a [GlobalCacheConfig] instance.
  static Future<Directory> defaultCacheDirectory() async {
    final temporaryDirectory = await getTemporaryDirectory();
    return Directory(p.join(temporaryDirectory.path, 'http_cache_stream'));
  }
}
