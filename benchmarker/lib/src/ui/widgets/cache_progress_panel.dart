import 'package:flutter/material.dart';
import 'package:http_cache_stream/http_cache_stream.dart';

import '../../util/formatting.dart';
import 'section_card.dart';

/// Download progress of the cache stream under test.
///
/// Only shown for runs that go through the cache server; direct runs bypass
/// http_cache_stream entirely and have no cache state.
class CacheProgressPanel extends StatelessWidget {
  const CacheProgressPanel({
    super.key,
    required this.cacheState,
    required this.cacheUrl,
  });

  final CacheState? cacheState;
  final Uri? cacheUrl;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = cacheState;
    final sourceLength = state?.sourceLength;
    final position = state?.position ?? 0;
    final progress = state?.progress;

    final String detail;
    if (state == null) {
      detail = 'Waiting for the cache stream…';
    } else if (sourceLength == null) {
      detail = '${formatBytes(position)} cached · source length unknown';
    } else {
      detail = '${formatBytes(position)} / ${formatBytes(sourceLength)} '
          '($position / $sourceLength bytes)';
    }

    return SectionCard(
      title: 'Cache progress',
      subtitle: cacheUrl?.toString(),
      trailing: state?.isComplete == true
          ? Chip(
              avatar: const Icon(Icons.check, size: 16),
              label: const Text('Complete'),
              visualDensity: VisualDensity.compact,
              side: BorderSide(color: theme.colorScheme.outlineVariant),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 8,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Text(detail, style: theme.textTheme.bodySmall),
              ),
              Text(
                progress == null ? '—' : formatPercent(progress),
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
