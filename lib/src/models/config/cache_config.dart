import 'dart:io';

import 'package:util_xx/Httpxx.dart';

abstract interface class CacheConfiguration {
  ///Custom headers to be sent when downloading cache.
  HttpHeaderxx get requestHeaders;

  ///Custom headers to add to every cached HTTP response.
  HttpHeaderxx get responseHeaders;
  set requestHeaders(HttpHeaderxx requestHeaders);
  set responseHeaders(HttpHeaderxx responseHeaders);

  ///When true, copies [CachedResponseHeaders] to [responseHeaders].
  ///
  ///Default is false.
  bool get copyCachedResponseHeaders;
  set copyCachedResponseHeaders(bool value);

  ///When true, validates the cache against the server when the cache is outdated.
  ///
  ///Default is false.
  bool get validateOutdatedCache;
  set validateOutdatedCache(bool value);

  /// The minimum number of bytes that must exist between the current download position
  /// and a range request's start position before creating a separate download stream.
  /// Set to null to disable separate range downloads.
  ///
  /// Default is null.
  int? get rangeRequestSplitThreshold;
  set rangeRequestSplitThreshold(int? value);

  ///The maximum amount of data to buffer in memory before writing to disk during a download.
  ///Once this limit is reached, the cache stream will flush the buffer to disk. However, the download will continue to buffer more data. The download stream will only be paused if it is receiving more data than it can write to disk. As a result, the theoretical maximum memory usage of a cache download is double this value.
  ///Default value is 25MB.
  int get maxBufferSize;
  set maxBufferSize(int value);

  /// The preferred minimum size of chunks emitted from the cache download stream.
  /// Network data is buffered until reaching this size before being emitted downstream.
  /// Larger values improve I/O efficiency at the cost of increased memory usage.
  /// Default value is 64KB.
  int get minChunkSize;
  set minChunkSize(int value);
}

sealed class CacheConfig implements CacheConfiguration {
  @override
  HttpHeaderxx requestHeaders = Httpxx_c.createHeader();
  @override
  HttpHeaderxx responseHeaders = Httpxx_c.createHeader();
  @override
  bool copyCachedResponseHeaders = false;
  @override
  bool validateOutdatedCache = false;
  @override
  int? get rangeRequestSplitThreshold => _rangeRequestSplitThreshold;
  @override
  set rangeRequestSplitThreshold(int? value) {
    if (value != null) {
      value = RangeError.checkNotNegative(value, 'RangeRequestSplitThreshold');
    }
    _rangeRequestSplitThreshold = value;
  }

  @override
  int get maxBufferSize => _maxBufferSize;
  @override
  set maxBufferSize(int value) {
    const minValue = 1024 * 1024 * 1; // 1MB
    if (value < minValue) {
      throw RangeError.range(value, minValue, null, 'maxBufferSize');
    }
    _maxBufferSize = value;
  }

  @override
  int get minChunkSize => _minChunkSize;

  @override
  set minChunkSize(int value) {
    _minChunkSize = RangeError.checkNotNegative(value, 'minChunkSize');
  }

  int? _rangeRequestSplitThreshold;
  int _maxBufferSize = 1024 * 1024 * 25;
  int _minChunkSize = 1024 * 64; // 64KB
}

class GlobalCacheConfig extends CacheConfig {
  ///The directory where the cache is stored. This can only be set during initialization.
  /// The cache directory must be writable and accessible by the application.
  /// Defaults to 'http_cache_stream' in the application's temporary directory.
  final Directory cacheDirectory;
  GlobalCacheConfig(this.cacheDirectory);
}

class LocalCacheConfig extends CacheConfig {
  LocalCacheConfig();
}
