import 'dart:async';

extension StreamControllerExtensions<T> on StreamController<T> {
  /// Because these callbacks can still be called after a controller is closed, this can help prevent accidental calls.
  void clearCallbacks() {
    onCancel = null;
    onListen = null;
    onPause = null;
    onResume = null;
  }
}
