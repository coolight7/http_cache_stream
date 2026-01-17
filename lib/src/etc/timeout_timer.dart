import 'dart:async';

/// A timeout timer optimized for repeated resets.
class TimeoutTimer {
  final Duration duration;
  TimeoutTimer(this.duration);
  final _sw = Stopwatch();
  Timer? _timer;

  void start(final void Function() onTimeout) {
    _timer?.cancel();
    _sw.reset();
    _sw.start();
    _timer = Timer.periodic(duration ~/ 5, (t) {
      if (_sw.elapsed >= duration) {
        cancel();
        onTimeout();
      }
    });
  }

  void reset() {
    _sw.reset();
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
    _sw.stop();
  }

  bool get isActive => _timer?.isActive ?? false;
}
