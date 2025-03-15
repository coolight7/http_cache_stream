import 'dart:async';

/// A stream that combines data from the partial cache file and the cache download stream.
/// It first streams data from the partial cache file, and once the file is done, it switches to the download stream.
/// Upon initalization, immediately starts buffering data from the download stream.
class CombinedCacheStream extends Stream<List<int>> {
  final Stream<List<int>> fileStream;
  final Stream<List<int>> dataStream;
  final _controller = StreamController<List<int>>(sync: true);
  late final StreamSubscription<List<int>> _dataSubscription;
  StreamSubscription<List<int>>? _fileSubscription;
  CombinedCacheStream({
    required this.fileStream,
    required this.dataStream,
  }) {
    _bufferLiveData();
    _init();
  }

  void _bufferLiveData() {
    _dataSubscription = dataStream.listen(
      _controller.add,
      onDone: _close,
      onError: _controller.addError,
      cancelOnError: false, //Allow subscriber to cancel stream on error
    );
    _dataSubscription.pause(); //Pause data stream, buffering data
  }

  void _init() {
    _controller.onListen = () {
      _controller.onListen = null;
      _start();
    };
    _controller.onCancel = () {
      _controller.onCancel = null;
      _close();
    };
    _controller.onPause = _currentSubscription.pause;
    _controller.onResume = _currentSubscription.resume;
  }

  void _start() {
    try {
      _fileSubscription = fileStream.listen(
        _controller.add,
        onDone: _streamLiveData, //Start streaming live data once file stream is done
        onError: _controller.addError,
      );
    } catch (e) {
      _close(e); //File stream can throw error upon listen, handle it
    }
  }

  void _streamLiveData() {
    _fileSubscription = null;
    _dataSubscription.resume(); //Resume data stream, emitting buffered data
  }

  void _close([Object? error]) {
    if (_controller.isClosed) return;
    _controller.onListen = null;
    _controller.onCancel = null;

    _dataSubscription.cancel().ignore();

    final fileSubscription = _fileSubscription;
    if (fileSubscription != null) {
      _fileSubscription = null;
      fileSubscription.cancel().ignore();
    }
    if (error != null && _controller.hasListener) {
      _controller.addError(error);
    }
    _controller.close().ignore();
  }

  void cancel() => _close('Stream cancelled');

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return _controller.stream.listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }

  StreamSubscription<List<int>> get _currentSubscription => _fileSubscription ?? _dataSubscription;
}
