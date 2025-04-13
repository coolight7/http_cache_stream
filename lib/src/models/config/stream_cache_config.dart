import 'package:http_cache_stream/http_cache_stream.dart';
import 'package:util_xx/Httpxx.dart';

///Cache configuration for a single [HttpCacheStream]. Values set here override the global values set in [GlobalCacheConfig].
///
///When [useGlobalHeaders] is true, headers will be combined with the global headers, overriding any duplicates.
class StreamCacheConfig implements CacheConfiguration {
  StreamCacheConfig(this._global);
  final GlobalCacheConfig _global;
  final _local = LocalCacheConfig();

  ///When true, custom request and response headers set in [HttpCacheManager] are used.
  ///If headers are set for this [HttpCacheStream], they are combined with the global headers, overriding any duplicates.
  bool useGlobalHeaders = true;

  @override
  HttpHeaderxx get requestHeaders => _local.requestHeaders;
  @override
  HttpHeaderxx get responseHeaders => _local.responseHeaders;

  @override
  bool get copyCachedResponseHeaders {
    return _useGlobalCopyCacheHeaders
        ? _global.copyCachedResponseHeaders
        : _local.copyCachedResponseHeaders;
  }

  @override
  bool get validateOutdatedCache {
    return _useGlobalValidateOutdatedCache
        ? _global.validateOutdatedCache
        : _local.validateOutdatedCache;
  }

  @override
  int? get rangeRequestSplitThreshold {
    return _useGlobalRangeRequestSplitThreshold
        ? _global.rangeRequestSplitThreshold
        : _local.rangeRequestSplitThreshold;
  }

  @override
  int get maxBufferSize {
    return _useGlobalBufferSize ? _global.maxBufferSize : _local.maxBufferSize;
  }

  @override
  int get minChunkSize {
    return _useGlobalMinChunkSize ? _global.minChunkSize : _local.minChunkSize;
  }

  @override
  set requestHeaders(HttpHeaderxx requestHeaders) {
    _local.requestHeaders = requestHeaders;
  }

  @override
  set responseHeaders(HttpHeaderxx responseHeaders) {
    _local.responseHeaders = responseHeaders;
  }

  @override
  set copyCachedResponseHeaders(bool value) {
    _useGlobalCopyCacheHeaders = false;
    _local.copyCachedResponseHeaders = value;
  }

  @override
  set validateOutdatedCache(bool value) {
    _useGlobalValidateOutdatedCache = false;
    _local.validateOutdatedCache = value;
  }

  @override
  set rangeRequestSplitThreshold(int? value) {
    _useGlobalRangeRequestSplitThreshold = false;
    _local.rangeRequestSplitThreshold = value;
  }

  @override
  set maxBufferSize(int value) {
    _useGlobalBufferSize = false;
    _local.maxBufferSize = value;
  }

  @override
  set minChunkSize(int value) {
    _useGlobalMinChunkSize = false;
    _local.minChunkSize = value;
  }

  ///Returns an immutable map of all custom request headers.
  HttpHeaderAnyxx combinedRequestHeaders() {
    return _combineHeaders(_global.requestHeaders, _local.requestHeaders);
  }

  ///Returns an immutable map of all custom response headers.
  HttpHeaderAnyxx combinedResponseHeaders() {
    return _combineHeaders(_global.responseHeaders, _local.responseHeaders);
  }

  HttpHeaderAnyxx _combineHeaders(
    HttpHeaderxx global,
    HttpHeaderxx local,
  ) {
    final useGlobal = global.isNotEmpty && useGlobalHeaders;
    final useLocal = local.isNotEmpty;
    if (!useGlobal && !useLocal) return const {};
    return Map.unmodifiable({if (useGlobal) ...global, if (useLocal) ...local});
  }

  bool _useGlobalCopyCacheHeaders = true;
  bool _useGlobalRangeRequestSplitThreshold = true;
  bool _useGlobalValidateOutdatedCache = true;
  bool _useGlobalBufferSize = true;
  bool _useGlobalMinChunkSize = true;
}
