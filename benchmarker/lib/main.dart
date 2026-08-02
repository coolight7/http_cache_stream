import 'package:flutter/material.dart';
import 'package:http_cache_stream/http_cache_stream.dart';

import 'src/ui/benchmark_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const BenchmarkerApp());
}

class BenchmarkerApp extends StatelessWidget {
  const BenchmarkerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'http_cache_stream benchmarker',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.dark,
      ),
      home: const _CacheManagerBootstrap(child: BenchmarkPage()),
    );
  }
}

/// Initializes [HttpCacheManager] before the benchmark page is shown.
class _CacheManagerBootstrap extends StatefulWidget {
  const _CacheManagerBootstrap({required this.child});

  final Widget child;

  @override
  State<_CacheManagerBootstrap> createState() => _CacheManagerBootstrapState();
}

class _CacheManagerBootstrapState extends State<_CacheManagerBootstrap> {
  late Future<HttpCacheManager> _init = HttpCacheManager.init();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<HttpCacheManager>(
      future: _init,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline, size: 40),
                    const SizedBox(height: 12),
                    Text(
                      'Failed to initialize HttpCacheManager:\n'
                      '${snapshot.error}',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: () =>
                          setState(() => _init = HttpCacheManager.init()),
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            ),
          );
        }
        if (!snapshot.hasData) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        return widget.child;
      },
    );
  }
}
