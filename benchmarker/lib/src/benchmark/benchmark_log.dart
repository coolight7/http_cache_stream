import '../util/formatting.dart';

enum LogLevel { info, success, warning, error }

/// A single line in the log/status view.
class LogEntry {
  LogEntry(this.message, {this.level = LogLevel.info}) : time = DateTime.now();

  final DateTime time;
  final String message;
  final LogLevel level;

  String get prefix {
    switch (level) {
      case LogLevel.info:
        return '';
      case LogLevel.success:
        return 'OK   ';
      case LogLevel.warning:
        return 'WARN ';
      case LogLevel.error:
        return 'ERROR ';
    }
  }

  @override
  String toString() => '[${formatClockTime(time)}] $prefix$message';
}
