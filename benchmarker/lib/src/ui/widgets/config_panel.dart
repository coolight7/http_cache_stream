import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../benchmark/benchmark_config.dart';
import '../../benchmark/http_client_builder.dart';
import '../../util/formatting.dart';
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
            const SizedBox(height: 8),
            _RangeSelector(form: form, isBusy: isBusy),
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

/// Selects the byte range every request asks for.
///
/// The slider needs the source's size to express a range in bytes, so it stays
/// disabled until the content length has been fetched.
class _RangeSelector extends StatelessWidget {
  const _RangeSelector({required this.form, required this.isBusy});

  final BenchmarkForm form;
  final bool isBusy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final contentLength = form.contentLength;
    final enabled = !isBusy && form.canSelectRange;
    final bounds = contentLength == null
        ? null
        : ByteRange.resolveBounds(
            form.rangeFraction.start,
            form.rangeFraction.end,
            contentLength,
          );

    final String detail;
    if (contentLength == null) {
      detail = 'Fetch the source length to request partial responses.';
    } else if (form.isEmptySelection) {
      detail = 'Empty selection — widen the range.';
    } else if (form.isFullRange) {
      detail = 'Full response · ${formatBytes(contentLength)} '
          '($contentLength bytes), no Range header';
    } else {
      final range = form.selectedRange()!;
      detail = 'Range ${range.header} · ${formatBytes(range.length)} '
          '(${range.length} bytes, '
          '${formatPercent(range.length / contentLength)} of source)';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Requested byte range',
                style: theme.textTheme.labelLarge,
              ),
            ),
            if (form.probeStatus == ProbeStatus.loading)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else
              TextButton.icon(
                onPressed: isBusy ? null : form.fetchSourceLength,
                icon: const Icon(Icons.straighten, size: 18),
                label: Text(
                  contentLength == null ? 'Fetch length' : 'Refresh length',
                ),
              ),
          ],
        ),
        RangeSlider(
          values: form.rangeFraction,
          divisions: 200,
          labels: RangeLabels(
            _thumbLabel(bounds?.start, contentLength, form.rangeFraction.start),
            _thumbLabel(
              bounds?.endExclusive,
              contentLength,
              form.rangeFraction.end,
            ),
          ),
          onChanged: enabled ? (values) => form.rangeFraction = values : null,
        ),
        Text(
          detail,
          style: theme.textTheme.bodySmall?.copyWith(
            color: form.isEmptySelection
                ? theme.colorScheme.error
                : theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (form.probeError case final probeError?)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              probeError,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error),
            ),
          )
        else if (contentLength != null && !form.acceptsRanges)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'The source did not advertise Accept-Ranges; it may answer with '
              'the full body.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.tertiary,
              ),
            ),
          ),
      ],
    );
  }

  static String _thumbLabel(int? offset, int? contentLength, double fraction) {
    if (offset == null || contentLength == null) return formatPercent(fraction);
    return formatBytes(offset);
  }
}
