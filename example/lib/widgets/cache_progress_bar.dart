import 'package:flutter/material.dart';
import 'package:http_cache_stream/http_cache_stream.dart';

class CacheProgressBar extends StatelessWidget {
  final HttpCacheStream httpCacheStream;
  const CacheProgressBar(this.httpCacheStream, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: StreamBuilder<double?>(
        stream: httpCacheStream.progressStream,
        initialData: httpCacheStream.progress, //Obtain the initial progress
        builder: (context, snapshot) {
          final progress = snapshot.data ?? httpCacheStream.progress;
          final error = snapshot.error;

          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(value: progress),
              if (progress != null) _ProgressTextPercentage(progress),
              if (error != null) _ErrorText(error),
            ],
          );
        },
      ),
    );
  }
}

class _ProgressTextPercentage extends StatelessWidget {
  final double progress;
  const _ProgressTextPercentage(this.progress);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 5),
      child: Text('${(progress * 100).floor()}%'),
    );
  }
}

class _ErrorText extends StatelessWidget {
  final Object error;
  const _ErrorText(this.error);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 5),
      child: Text(error.toString(), style: const TextStyle(color: Colors.red)),
    );
  }
}
