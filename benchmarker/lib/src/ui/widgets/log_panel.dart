import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../benchmark/benchmark_log.dart';
import 'section_card.dart';

/// A read-only text field showing status lines and errors.
class LogPanel extends StatefulWidget {
  const LogPanel({super.key, required this.logs, required this.onClear});

  final List<LogEntry> logs;
  final VoidCallback onClear;

  @override
  State<LogPanel> createState() => _LogPanelState();
}

class _LogPanelState extends State<LogPanel> {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  int _renderedCount = -1;

  @override
  void initState() {
    super.initState();
    _syncText();
  }

  @override
  void didUpdateWidget(covariant LogPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncText();
  }

  void _syncText() {
    if (_renderedCount == widget.logs.length) return;
    _renderedCount = widget.logs.length;
    _textController.text = widget.logs.map((entry) => '$entry').join('\n');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SectionCard(
      title: 'Log',
      subtitle: '${widget.logs.length} entries',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Copy log',
            icon: const Icon(Icons.copy_all_outlined),
            onPressed: widget.logs.isEmpty
                ? null
                : () {
                    Clipboard.setData(
                      ClipboardData(text: _textController.text),
                    );
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Log copied.')),
                    );
                  },
          ),
          IconButton(
            tooltip: 'Clear log',
            icon: const Icon(Icons.delete_outline),
            onPressed: widget.logs.isEmpty ? null : widget.onClear,
          ),
        ],
      ),
      child: SizedBox(
        height: 260,
        child: TextField(
          controller: _textController,
          scrollController: _scrollController,
          readOnly: true,
          expands: true,
          maxLines: null,
          minLines: null,
          textAlignVertical: TextAlignVertical.top,
          style: theme.textTheme.bodySmall?.copyWith(
            fontFamily: 'monospace',
            height: 1.4,
          ),
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            isDense: true,
            contentPadding: EdgeInsets.all(12),
            hintText: 'Status and error output appears here.',
          ),
        ),
      ),
    );
  }
}
