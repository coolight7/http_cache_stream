extension FutureExtensions<T> on Future<T> {
  /// Executes [action] when the future is completed, regardless of whether it completed with a value or an error.
  /// Similar to [whenComplete], but does not propagate errors from the original future, nor return a value.
  void onComplete(final void Function() action) async {
    try {
      await this;
    } catch (_) {
    } finally {
      action();
    }
  }
}
