import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// Builds the [http.Client] used by a single worker isolate.
///
/// Each worker isolate builds exactly one client when it starts and reuses it
/// for every request it issues, so connection pooling and keep-alive behavior
/// belongs to the client returned here.
///
/// A builder must be a top-level or static function: it is sent across a
/// [SendPort] when the worker isolate is spawned.
typedef HttpClientBuilder = http.Client Function();

/// A selectable [HttpClientBuilder], shown in the benchmark configuration UI.
///
/// Add an entry here to benchmark another client implementation (for example
/// `cupertino_http` or `cronet_http`); nothing else needs to change.
class HttpClientOption {
  const HttpClientOption({
    required this.id,
    required this.label,
    required this.description,
    required this.builder,
  });

  /// Stable identifier, used to detect when the worker pool must be respawned.
  final String id;
  final String label;
  final String description;
  final HttpClientBuilder builder;

  @override
  String toString() => label;
}

/// The default `package:http` client. On the Dart VM this is an [IOClient]
/// wrapping a stock [HttpClient].
http.Client buildDefaultClient() => http.Client();

/// A `dart:io` client with a raised per-host connection limit. Useful when a
/// single isolate is expected to hold more than one socket open at a time.
http.Client buildPooledIoClient() {
  final httpClient = HttpClient()
    ..maxConnectionsPerHost = 64
    ..idleTimeout = const Duration(seconds: 30);
  return IOClient(httpClient);
}

/// A `dart:io` client that opens a fresh connection per request, which isolates
/// connection setup cost from the rest of the response timings.
http.Client buildNoKeepAliveClient() => _NoKeepAliveClient(HttpClient());

/// A `dart:io` client that does not transparently decompress responses, so the
/// byte counts reported by the benchmark match the bytes on the wire.
http.Client buildRawIoClient() {
  final httpClient = HttpClient()..autoUncompress = false;
  return IOClient(httpClient);
}

/// All client implementations selectable from the UI.
const List<HttpClientOption> kHttpClientOptions = [
  HttpClientOption(
    id: 'default',
    label: 'package:http (default)',
    description: 'Stock http.Client, keep-alive enabled.',
    builder: buildDefaultClient,
  ),
  HttpClientOption(
    id: 'io-pooled',
    label: 'dart:io (pooled)',
    description: 'IOClient, 64 connections per host, 30s idle timeout.',
    builder: buildPooledIoClient,
  ),
  HttpClientOption(
    id: 'io-no-keep-alive',
    label: 'dart:io (no keep-alive)',
    description: 'IOClient, a new connection for every request.',
    builder: buildNoKeepAliveClient,
  ),
  HttpClientOption(
    id: 'io-raw',
    label: 'dart:io (no auto-uncompress)',
    description: 'IOClient, compressed responses are counted as received.',
    builder: buildRawIoClient,
  ),
];

HttpClientOption clientOptionById(String id) {
  return kHttpClientOptions.firstWhere(
    (option) => option.id == id,
    orElse: () => kHttpClientOptions.first,
  );
}

/// Forces `Connection: close` on every request sent through the delegate.
class _NoKeepAliveClient extends http.BaseClient {
  _NoKeepAliveClient(HttpClient httpClient) : _inner = IOClient(httpClient);

  final IOClient _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.persistentConnection = false;
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}
