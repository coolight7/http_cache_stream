import 'dart:async';

import 'package:http_cache_stream/http_cache_stream.dart';
import 'package:http_cache_stream/src/models/config/stream_cache_config.dart';

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
  final StreamCacheConfig config;
  final bool? cancelOnError;
  final _controller = StreamController<List<int>>(sync: true);
  final _httpClient = CustomHttpClientxx();

  _LiveDownloadStream(
    this.downloadUri,
    this.range,
    this.config, {
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
      final data = (await _httpClient.getUrl(
        downloadUri,
        range,
        config.combinedRequestHeaders(),
      ))
          .data;
      if (null == data) {
        throw Exception("client.Get: resp.data is Null");
      }
      await _controller.addStream(
        data.stream,
        cancelOnError: cancelOnError,
      );
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
    _httpClient.close(force: true);
  }

  Stream<List<int>> get stream => _controller.stream;
}
