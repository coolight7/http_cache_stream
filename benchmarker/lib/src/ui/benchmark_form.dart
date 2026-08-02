import 'package:flutter/widgets.dart';

import '../benchmark/benchmark_config.dart';
import '../benchmark/http_client_builder.dart';

/// Holds the benchmark inputs.
///
/// The form state lives on the page rather than inside [ConfigPanel] so it
/// survives the panel being disposed and rebuilt — which happens whenever the
/// panel scrolls out of the lazily-built list, or the layout switches between
/// its narrow and wide arrangements.
class BenchmarkForm extends ChangeNotifier {
  BenchmarkForm({
    String url = defaultUrl,
    int concurrency = 4,
    int totalRequests = 40,
    BenchmarkType type = BenchmarkType.preCached,
    HttpClientOption? clientOption,
  })  : urlController = TextEditingController(text: url),
        concurrencyController =
            TextEditingController(text: concurrency.toString()),
        requestsController =
            TextEditingController(text: totalRequests.toString()),
        _type = type,
        _clientOption = clientOption ?? kHttpClientOptions.first;

  static const String defaultUrl =
      'https://download.samplelib.com/mp3/sample-15s.mp3';

  final TextEditingController urlController;
  final TextEditingController concurrencyController;
  final TextEditingController requestsController;

  BenchmarkType _type;
  HttpClientOption _clientOption;
  String? _error;

  BenchmarkType get type => _type;

  set type(BenchmarkType value) {
    if (_type == value) return;
    _type = value;
    notifyListeners();
  }

  HttpClientOption get clientOption => _clientOption;

  set clientOption(HttpClientOption value) {
    if (_clientOption == value) return;
    _clientOption = value;
    notifyListeners();
  }

  /// Validation message from the last [buildConfig] attempt, if it failed.
  String? get error => _error;

  /// Validates the current inputs and returns a runnable [BenchmarkConfig],
  /// or null after recording [error].
  BenchmarkConfig? buildConfig() {
    final url = urlController.text.trim();
    final concurrency = int.tryParse(concurrencyController.text.trim());
    final totalRequests = int.tryParse(requestsController.text.trim());

    final error = BenchmarkConfig.validate(
      url: url,
      concurrency: concurrency,
      totalRequests: totalRequests,
    );
    if (error != _error) {
      _error = error;
      notifyListeners();
    }
    if (error != null) return null;

    return BenchmarkConfig(
      sourceUrl: Uri.parse(url),
      concurrency: concurrency!,
      totalRequests: totalRequests!,
      type: _type,
      clientOption: _clientOption,
    );
  }

  @override
  void dispose() {
    urlController.dispose();
    concurrencyController.dispose();
    requestsController.dispose();
    super.dispose();
  }
}
