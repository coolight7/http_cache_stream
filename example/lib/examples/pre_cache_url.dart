import 'package:flutter/material.dart';
import 'package:http_cache_stream/http_cache_stream.dart';
import 'package:http_cache_stream_example/widgets/cache_progress_bar.dart';

class PreCacheUrl extends StatefulWidget {
  final Uri sourceUrl;
  const PreCacheUrl(this.sourceUrl, {super.key});

  @override
  State<PreCacheUrl> createState() => _PreCacheUrlState();
}

class _PreCacheUrlState extends State<PreCacheUrl> {
  late final httpCacheStream = HttpCacheManager.instance.createStream(
    widget.sourceUrl,
  );

  @override
  void initState() {
    super.initState();
    httpCacheStream.download(); //Manually start the download
  }

  @override
  void dispose() {
    super.dispose();
    httpCacheStream
        .dispose(); //Dispose the cacheStream when the player is disposed
  }

  @override
  Widget build(BuildContext context) {
    return CacheProgressBar(httpCacheStream);
  }
}
