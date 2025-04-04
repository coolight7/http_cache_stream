import 'dart:io';

import 'package:http/http.dart';
import 'package:http_cache_stream/http_cache_stream.dart';

///Cache configuration for a single [HttpCacheStream]. Values set here override the global values set in [GlobalCacheConfig].
///
///When [useGlobalHeaders] is true, headers will be combined with the global headers, overriding any duplicates.
class StreamCacheConfig implements CacheConfiguration {
  StreamCacheConfig(this._global);
  final GlobalCacheConfig _global;

  ///When true, custom request and response headers set in [HttpCacheManager] are used.
  ///If headers are set for this [HttpCacheStream], they are combined with the global headers, overriding any duplicates.
  bool useGlobalHeaders = true;

  @override
  Map<String, String> requestHeaders = {};
  @override
  Map<String, String> responseHeaders = {};

  @override
  bool get copyCachedResponseHeaders {
    return _copyCachedResponseHeaders ?? _global.copyCachedResponseHeaders;
  }

  @override
  bool get validateOutdatedCache {
    return _validateOutdatedCache ?? _global.validateOutdatedCache;
  }

  @override
  int? get rangeRequestSplitThreshold {
    return _useGlobalRangeRequestSplitThreshold
        ? _global.rangeRequestSplitThreshold
        : _rangeRequestSplitThreshold;
  }

  @override
  int get maxBufferSize {
    return _maxBufferSize ?? _global.maxBufferSize;
  }

  @override
  int get minChunkSize {
    return _minChunkSize ?? _global.minChunkSize;
  }

  @override
  set copyCachedResponseHeaders(bool value) {
    _copyCachedResponseHeaders = value;
  }

  @override
  set validateOutdatedCache(bool value) {
    _validateOutdatedCache = value;
  }

  @override
  set rangeRequestSplitThreshold(int? value) {
    _useGlobalRangeRequestSplitThreshold = false;
    _rangeRequestSplitThreshold =
        CacheConfiguration.validateRangeRequestSplitThreshold(value);
  }

  @override
  set maxBufferSize(int value) {
    _maxBufferSize = CacheConfiguration.validateMaxBufferSize(value);
  }

  @override
  set minChunkSize(int value) {
    _minChunkSize = CacheConfiguration.validateMinChunkSize(value);
  }

  ///Register a callback to be called when this stream's cache is completely downloaded and written to disk.
  void Function(File cacheFile)? onCacheDone;

  ///Returns an immutable map of all custom request headers.
  Map<String, String> combinedRequestHeaders() {
    return _combineHeaders(_global.requestHeaders, requestHeaders);
  }

  ///Returns an immutable map of all custom response headers.
  Map<String, String> combinedResponseHeaders() {
    return _combineHeaders(_global.responseHeaders, responseHeaders);
  }

  ///Internal callback to be called when the cache is completely downloaded and written to disk.
  ///To register a callback, use [onCacheDone].
  void onCacheComplete(HttpCacheStream stream, File cacheFile) {
    onCacheDone?.call(cacheFile);
    _global.onCacheDone?.call(stream, cacheFile);
  }

  Map<String, String> _combineHeaders(
    Map<String, String> global,
    Map<String, String> local,
  ) {
    final useGlobal = global.isNotEmpty && useGlobalHeaders;
    final useLocal = local.isNotEmpty;
    if (!useGlobal && !useLocal) return const {};
    return Map.unmodifiable({if (useGlobal) ...global, if (useLocal) ...local});
  }

  @override
  Client get httpClient => _global.httpClient;

  bool _useGlobalRangeRequestSplitThreshold = true;
  bool? _copyCachedResponseHeaders;
  bool? _validateOutdatedCache;
  int? _maxBufferSize;
  int? _minChunkSize;
  int? _rangeRequestSplitThreshold;
}

// class StreamCacheConfig implements CacheConfiguration {
//   StreamCacheConfig(this._global);
//   final GlobalCacheConfig _global;
//   final _local = LocalCacheConfig();

//   ///When true, custom request and response headers set in [HttpCacheManager] are used.
//   ///If headers are set for this [HttpCacheStream], they are combined with the global headers, overriding any duplicates.
//   bool useGlobalHeaders = true;

//   @override
//   Map<String, Object> get requestHeaders => _local.requestHeaders;
//   @override
//   Map<String, Object> get responseHeaders => _local.responseHeaders;

//   @override
//   bool get copyCachedResponseHeaders {
//     return _useGlobalCopyCacheHeaders
//         ? _global.copyCachedResponseHeaders
//         : _local.copyCachedResponseHeaders;
//   }

//   @override
//   bool get validateOutdatedCache {
//     return _useGlobalValidateOutdatedCache
//         ? _global.validateOutdatedCache
//         : _local.validateOutdatedCache;
//   }

//   @override
//   int? get rangeRequestSplitThreshold {
//     return _useGlobalRangeRequestSplitThreshold
//         ? _global.rangeRequestSplitThreshold
//         : _local.rangeRequestSplitThreshold;
//   }

//   @override
//   int get maxBufferSize {
//     return _useGlobalBufferSize ? _global.maxBufferSize : _local.maxBufferSize;
//   }

//   @override
//   int get minChunkSize {
//     return _useGlobalMinChunkSize ? _global.minChunkSize : _local.minChunkSize;
//   }

//   @override
//   set requestHeaders(Map<String, Object> requestHeaders) {
//     _local.requestHeaders = requestHeaders;
//   }

//   @override
//   set responseHeaders(Map<String, Object> responseHeaders) {
//     _local.responseHeaders = responseHeaders;
//   }

//   @override
//   set copyCachedResponseHeaders(bool value) {
//     _useGlobalCopyCacheHeaders = false;
//     _local.copyCachedResponseHeaders = value;
//   }

//   @override
//   set validateOutdatedCache(bool value) {
//     _useGlobalValidateOutdatedCache = false;
//     _local.validateOutdatedCache = value;
//   }

//   @override
//   set rangeRequestSplitThreshold(int? value) {
//     _useGlobalRangeRequestSplitThreshold = false;
//     _local.rangeRequestSplitThreshold = value;
//   }

//   @override
//   set maxBufferSize(int value) {
//     _useGlobalBufferSize = false;
//     _local.maxBufferSize = value;
//   }

//   @override
//   set minChunkSize(int value) {
//     _useGlobalMinChunkSize = false;
//     _local.minChunkSize = value;
//   }

//   ///Returns an immutable map of all custom request headers.
//   Map<String, Object> combinedRequestHeaders() {
//     return _combineHeaders(_global.requestHeaders, _local.requestHeaders);
//   }

//   ///Returns an immutable map of all custom response headers.
//   Map<String, Object> combinedResponseHeaders() {
//     return _combineHeaders(_global.responseHeaders, _local.responseHeaders);
//   }

//   Map<String, Object> _combineHeaders(
//     Map<String, Object> global,
//     Map<String, Object> local,
//   ) {
//     final useGlobal = global.isNotEmpty && useGlobalHeaders;
//     final useLocal = local.isNotEmpty;
//     if (!useGlobal && !useLocal) return const {};
//     return Map.unmodifiable({if (useGlobal) ...global, if (useLocal) ...local});
//   }

//   bool _useGlobalCopyCacheHeaders = true;
//   bool _useGlobalRangeRequestSplitThreshold = true;
//   bool _useGlobalValidateOutdatedCache = true;
//   bool _useGlobalBufferSize = true;
//   bool _useGlobalMinChunkSize = true;
// }
