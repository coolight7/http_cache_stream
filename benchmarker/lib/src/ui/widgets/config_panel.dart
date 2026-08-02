import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../benchmark/benchmark_config.dart';
import '../../benchmark/http_client_builder.dart';
import '../benchmark_form.dart';
import 'section_card.dart';

/// The benchmark inputs: source URL, concurrency, total requests, run type and
/// http client implementation.
///
/// All state lives in [form], which the page owns, so the inputs survive this
/// widget being disposed and rebuilt.
class ConfigPanel extends StatelessWidget {
  const ConfigPanel({
    super.key,
    required this.form,
    required this.isBusy,
    required this.canCancel,
    required this.onRun,
    required this.onCancel,
  });

  final BenchmarkForm form;
  final bool isBusy;
  final bool canCancel;
  final ValueChanged<BenchmarkConfig> onRun;
  final VoidCallback onCancel;

  void _run() {
    final config = form.buildConfig();
    if (config != null) onRun(config);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SectionCard(
      title: 'Configuration',
      subtitle: 'Requests are divided evenly between worker isolates.',
      child: ListenableBuilder(
        listenable: form,
        builder: (context, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: form.urlController,
              enabled: !isBusy,
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
                    controller: form.concurrencyController,
                    enabled: !isBusy,
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
                    controller: form.requestsController,
                    enabled: !isBusy,
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
                  selected: {form.type},
                  onSelectionChanged: isBusy
                      ? null
                      : (selection) => form.type = selection.first,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              form.type.description,
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
                  value: form.clientOption,
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
                  onChanged: isBusy
                      ? null
                      : (option) => form.clientOption =
                          option ?? kHttpClientOptions.first,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              form.clientOption.description,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (form.error case final error?) ...[
              const SizedBox(height: 12),
              Text(
                error,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: isBusy ? null : _run,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Run benchmark'),
                  ),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: canCancel ? onCancel : null,
                  icon: const Icon(Icons.stop),
                  label: const Text('Cancel'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
