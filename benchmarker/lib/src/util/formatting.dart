/// Formatting helpers shared by the log and the statistics views.
library;

const List<String> _byteUnits = ['B', 'KB', 'MB', 'GB', 'TB'];

/// Formats a byte count using binary units, e.g. `1.44 MB`.
String formatBytes(num bytes, {int fractionDigits = 2}) {
  if (bytes.isNaN || bytes.isInfinite) return '—';
  var value = bytes.toDouble();
  var unit = 0;
  while (value.abs() >= 1024 && unit < _byteUnits.length - 1) {
    value /= 1024;
    unit++;
  }
  final digits = unit == 0 ? 0 : fractionDigits;
  return '${value.toStringAsFixed(digits)} ${_byteUnits[unit]}';
}

/// Formats a throughput in bytes per second, e.g. `12.30 MB/s`.
String formatBytesPerSecond(num bytesPerSecond) =>
    '${formatBytes(bytesPerSecond)}/s';

/// Formats a duration with a resolution that suits its magnitude.
String formatDuration(Duration duration) {
  final micros = duration.inMicroseconds;
  if (micros < 1000) return '$micros µs';
  if (micros < Duration.microsecondsPerSecond) {
    return '${(micros / 1000).toStringAsFixed(2)} ms';
  }
  if (micros < Duration.microsecondsPerMinute) {
    return '${(micros / Duration.microsecondsPerSecond).toStringAsFixed(2)} s';
  }
  final minutes = duration.inMinutes;
  final seconds = duration.inSeconds % 60;
  return '${minutes}m ${seconds}s';
}

/// Formats a rate with two decimals, e.g. `123.45 req/s`.
String formatRate(double value, String unit) =>
    '${value.toStringAsFixed(2)} $unit';

/// Formats a 0-1 fraction as a percentage, e.g. `42.1%`.
String formatPercent(double fraction, {int fractionDigits = 1}) =>
    '${(fraction * 100).toStringAsFixed(fractionDigits)}%';

/// Formats a wall-clock time as `HH:mm:ss.SSS`.
String formatClockTime(DateTime time) {
  String pad(int value, [int width = 2]) =>
      value.toString().padLeft(width, '0');
  return '${pad(time.hour)}:${pad(time.minute)}:${pad(time.second)}'
      '.${pad(time.millisecond, 3)}';
}
