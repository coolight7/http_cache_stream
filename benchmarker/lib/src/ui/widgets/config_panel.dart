import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../benchmark/benchmark_config.dart';
import '../../benchmark/http_client_builder.dart';
import 'section_card.dart';

/// The benchmark inputs: source URL, concurrency, total requests, run type and
/// http client implementation.
class ConfigPanel extends StatefulWidget {
  const ConfigPanel({
    super.key,
    required this.isBusy,
    required this.canCancel,
    required this.onRun,
    required this.onCancel,
  });

  final bool isBusy;
  final bool canCancel;
  final ValueChanged<BenchmarkConfig> onRun;
  final VoidCallback onCancel;

  @override
  State<ConfigPanel> createState() => _ConfigPanelState();
}

class _ConfigPanelState extends State<ConfigPanel> {
  static const String _defaultUrl =
      'https://download.samplelib.com/mp3/sample-15s.mp3';

  final TextEditingController _urlController =
      TextEditingController(text: _defaultUrl);
  final TextEditingController _concurrencyController =
      TextEditingController(text: '4');
  final TextEditingController _requestsController =
      TextEditingController(text: '40');

  BenchmarkType _type = BenchmarkType.preCached;
  HttpClientOption _clientOption = kHttpClientOptions.first;
  String? _error;

  @override
  void dispose() {
    _urlController.dispose();
    _concurrencyController.dispose();
    _requestsController.dispose();
    super.dispose();
  }

  void _run() {
    final url = _urlController.text.trim();
    final concurrency = int.tryParse(_concurrencyController.text.trim());
    final totalRequests = int.tryParse(_requestsController.text.trim());

    final error = BenchmarkConfig.validate(
      url: url,
      concurrency: concurrency,
      totalRequests: totalRequests,
    );
    setState(() => _error = error);
    if (error != null) return;

    widget.onRun(
      BenchmarkConfig(
        sourceUrl: Uri.parse(url),
        concurrency: concurrency!,
        totalRequests: totalRequests!,
        type: _type,
        clientOption: _clientOption,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SectionCard(
      title: 'Configuration',
      subtitle: 'Requests are divided evenly between worker isolates.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _urlController,
            enabled: !widget.isBusy,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Source URL',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _concurrencyController,
                  enabled: !widget.isBusy,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    labelText: 'Concurrency (workers)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _requestsController,
                  enabled: !widget.isBusy,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    labelText: 'Total requests',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SegmentedButton<BenchmarkType>(
                segments: [
                  for (final type in BenchmarkType.values)
                    ButtonSegment<BenchmarkType>(
                      value: type,
                      label: Text(type.label),
                    ),
                ],
                selected: {_type},
                onSelectionChanged: widget.isBusy
                    ? null
                    : (selection) => setState(() => _type = selection.first),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _type.description,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          InputDecorator(
            decoration: const InputDecoration(
              labelText: 'HTTP client (per worker isolate)',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<HttpClientOption>(
                value: _clientOption,
                isExpanded: true,
                isDense: true,
                items: [
                  for (final option in kHttpClientOptions)
                    DropdownMenuItem<HttpClientOption>(
                      value: option,
                      child:
                          Text(option.label, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: widget.isBusy
                    ? null
                    : (option) => setState(
                          () =>
                              _clientOption = option ?? kHttpClientOptions.first,
                        ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _clientOption.description,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error),
            ),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: widget.isBusy ? null : _run,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Run benchmark'),
                ),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: widget.canCancel ? widget.onCancel : null,
                icon: const Icon(Icons.stop),
                label: const Text('Cancel'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
