import 'dart:async';

import 'package:http_cache_stream/http_cache_stream.dart';
import 'package:http_cache_stream/src/etc/http_util.dart';

class LiveDownloadStream extends Stream<List<int>> {
  final Uri downloadUri;
  final IntRange range;
  final StreamCacheConfig config;
  LiveDownloadStream(this.downloadUri, this.range, this.config);

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    final downloader = _LiveDownloadStream(
      downloadUri,
      range,
      config,
      cancelOnError: cancelOnError ?? true,
    );
    return downloader.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }
}

class _LiveDownloadStream {
  final Uri downloadUri;
  final IntRange range;
  final StreamCacheConfig cacheConfig;
  final bool? cancelOnError;
  final _controller = StreamController<List<int>>(sync: true);
  _LiveDownloadStream(
    this.downloadUri,
    this.range,
    this.cacheConfig, {
    this.cancelOnError,
  }) {
    _controller.onListen = () {
      _controller.onListen = null;
      _start();
    };
    _controller.onCancel = () {
      _controller.onCancel = null;
      _close();
    };
  }

  void _start() async {
    try {
      final response = await HttpUtil.get(
        cacheConfig.httpClient,
        downloadUri,
        range,
        cacheConfig.combinedRequestHeaders(),
      );
      if (_controller.isClosed) {
        HttpUtil.cancelStreamedResponse(response);
        return;
      }
      await _controller.addStream(response.stream,
          cancelOnError: cancelOnError);
    } catch (e) {
      if (!_controller.isClosed && _controller.hasListener) {
        _controller.addError(e);
      }
    } finally {
      _close();
    }
  }

  void _close() {
    if (_controller.isClosed) return;
    _controller.onListen = null;
    _controller.onCancel = null;
    _controller.close().ignore();
  }

  Stream<List<int>> get stream => _controller.stream;
}
