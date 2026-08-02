import 'package:flutter/material.dart' show RangeValues;
import 'package:flutter/widgets.dart';

import '../benchmark/benchmark_config.dart';
import '../benchmark/http_client_builder.dart';
import '../benchmark/source_probe.dart';

/// State of the source content-length probe backing the range slider.
enum ProbeStatus { idle, loading, ready, failed }

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
    this.probe = probeSource,
  })  : urlController = TextEditingController(text: url),
        concurrencyController =
            TextEditingController(text: concurrency.toString()),
        requestsController =
            TextEditingController(text: totalRequests.toString()),
        _type = type,
        _clientOption = clientOption ?? kHttpClientOptions.first {
    urlController.addListener(_onUrlChanged);
  }

  static const String defaultUrl =
      'https://download.samplelib.com/mp3/sample-15s.mp3';

  final TextEditingController urlController;
  final TextEditingController concurrencyController;
  final TextEditingController requestsController;

  /// Injectable for tests; defaults to a real network probe.
  final Future<SourceInfo> Function(Uri url) probe;

  BenchmarkType _type;
  HttpClientOption _clientOption;
  String? _error;

  RangeValues _rangeFraction = const RangeValues(0, 1);
  ProbeStatus _probeStatus = ProbeStatus.idle;
  String? _probeError;
  int? _contentLength;
  bool _acceptsRanges = false;
  String? _probedUrl;
  int _probeToken = 0;

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

  // ---------------------------------------------------------------------------
  // Source probe
  // ---------------------------------------------------------------------------

  ProbeStatus get probeStatus => _probeStatus;

  /// Why the last probe failed, if it did.
  String? get probeError => _probeError;

  /// Source size in bytes, once probed. Null until then.
  int? get contentLength => _contentLength;

  /// Whether the source advertised support for byte ranges.
  bool get acceptsRanges => _acceptsRanges;

  /// Whether a partial range can be selected, which needs a known size.
  bool get canSelectRange => (_contentLength ?? 0) > 0;

  /// Fetches the source's content length so ranges can be chosen in bytes.
  Future<void> fetchSourceLength() async {
    final url = urlController.text.trim();
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      _probeStatus = ProbeStatus.failed;
      _probeError = 'Enter a valid absolute source URL first.';
      notifyListeners();
      return;
    }

    final token = ++_probeToken;
    _probeStatus = ProbeStatus.loading;
    _probeError = null;
    notifyListeners();

    try {
      final info = await probe(uri);
      if (token != _probeToken) return; // Superseded by a newer probe.
      _contentLength = info.contentLength;
      _acceptsRanges = info.acceptsRanges;
      _probedUrl = url;
      _probeStatus = ProbeStatus.ready;
      _probeError = info.contentLength == null
          ? 'The source did not report a Content-Length.'
          : null;
      _rangeFraction = const RangeValues(0, 1);
    } catch (e) {
      if (token != _probeToken) return;
      _contentLength = null;
      _acceptsRanges = false;
      _probeStatus = ProbeStatus.failed;
      _probeError = '$e';
    }
    notifyListeners();
  }

  /// Drops a probed length once the URL no longer matches it, so a stale size
  /// can never be applied to a different source.
  void _onUrlChanged() {
    if (_probedUrl == null || _probedUrl == urlController.text.trim()) return;
    _probedUrl = null;
    _contentLength = null;
    _acceptsRanges = false;
    _probeStatus = ProbeStatus.idle;
    _probeError = null;
    _rangeFraction = const RangeValues(0, 1);
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Range selection
  // ---------------------------------------------------------------------------

  /// Selected portion of the source, as fractions from 0 to 1.
  RangeValues get rangeFraction => _rangeFraction;

  set rangeFraction(RangeValues value) {
    final start = value.start.clamp(0.0, 1.0);
    final end = value.end.clamp(start, 1.0);
    if (start == _rangeFraction.start && end == _rangeFraction.end) return;
    _rangeFraction = RangeValues(start, end);
    notifyListeners();
  }

  /// The byte range requests should ask for, or null for the full response.
  ByteRange? selectedRange() {
    final length = _contentLength;
    if (length == null || length <= 0) return null;
    return ByteRange.fromFractions(
      _rangeFraction.start,
      _rangeFraction.end,
      length,
    );
  }

  /// Whether the selection resolves to zero bytes.
  bool get isEmptySelection {
    final length = _contentLength;
    if (length == null || length <= 0) return false;
    return ByteRange.isEmptySelection(
      _rangeFraction.start,
      _rangeFraction.end,
      length,
    );
  }

  /// Whether the whole source is requested, so no `Range` header is sent.
  bool get isFullRange => !isEmptySelection && selectedRange() == null;

  // ---------------------------------------------------------------------------
  // Config
  // ---------------------------------------------------------------------------

  /// Validates the current inputs and returns a runnable [BenchmarkConfig],
  /// or null after recording [error].
  BenchmarkConfig? buildConfig() {
    final url = urlController.text.trim();
    final concurrency = int.tryParse(concurrencyController.text.trim());
    final totalRequests = int.tryParse(requestsController.text.trim());

    var error = BenchmarkConfig.validate(
      url: url,
      concurrency: concurrency,
      totalRequests: totalRequests,
    );
    final range = error == null ? selectedRange() : null;
    if (error == null && isEmptySelection) {
      error = 'The selected range is empty.';
    }

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
      range: range,
    );
  }

  @override
  void dispose() {
    urlController.removeListener(_onUrlChanged);
    urlController.dispose();
    concurrencyController.dispose();
    requestsController.dispose();
    super.dispose();
  }
}
