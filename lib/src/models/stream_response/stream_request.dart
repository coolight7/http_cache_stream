import 'dart:async';

import 'package:http_cache_stream/http_cache_stream.dart';

class StreamRequest {
  final IntRange range;
  final Completer<StreamResponse> responseCompleter;
  const StreamRequest._(this.range, this.responseCompleter);

  factory StreamRequest.construct(IntRange range) {
    final completer = Completer<StreamResponse>();
    return StreamRequest._(range, completer);
  }

  void complete(StreamResponse response) {
    assert(!isComplete, 'Response already completed');
    if (isComplete) {
      return;
    }
    responseCompleter.complete(response);
  }

  void completeError(Object error) {
    assert(!isComplete, 'Response already completed');
    if (isComplete) {
      return;
    }
    responseCompleter.completeError(error);
  }

  Future<StreamResponse> get response => responseCompleter.future;
  int get start => range.start;
  int? get end => range.end;
  bool get isComplete => responseCompleter.isCompleted;
}
