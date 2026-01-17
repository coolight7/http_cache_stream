import 'dart:io';

import '../etc/timeout_timer.dart';

class SocketHandler {
  final Socket _socket;
  SocketHandler(this._socket);

  Future<void> writeResponse(
    final Stream<List<int>> response,
    final Duration timeout,
  ) async {
    final timeoutTimer = TimeoutTimer(timeout)..start(destroy);
    try {
      await _socket.addStream(response.map((data) {
        timeoutTimer.reset();
        return data;
      }));
      if (_closed) return;
      timeoutTimer.reset();
      await _socket.flush();
      if (_closed) return;
      await _socket.close();
    } catch (e) {
      //Intentionally ignored.
    } finally {
      timeoutTimer.cancel();
      destroy(); //Not calling [destroy], even following socket.close, results in resource leaks
    }
  }

  void destroy() {
    if (_closed) return;
    _closed = true;
    _socket.destroy();
  }

  bool _closed = false;
  bool get isClosed => _closed;
}
