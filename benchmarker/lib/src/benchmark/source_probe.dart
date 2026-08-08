import 'dart:io';

import 'package:http/http.dart' as http;

/// What a probe learned about the source URL.
class SourceInfo {
  const SourceInfo({required this.contentLength, required this.acceptsRanges});

  /// Total size of the source in bytes, or null if the server did not report
  /// one.
  final int? contentLength;

  /// Whether the server advertised (or demonstrated) support for byte ranges.
  final bool acceptsRanges;
}

/// Fetches the size of [url] so partial-response ranges can be expressed in
/// bytes before any benchmark request is issued.
///
/// Tries a `HEAD` first and falls back to a one-byte range request, which also
/// reveals whether the server honors `Range` at all.
Future<SourceInfo> probeSource(
  Uri url, {
  http.Client? client,
  Duration timeout = const Duration(seconds: 20),
}) async {
  final httpClient = client ?? http.Client();
  try {
    try {
      final response = await httpClient.head(url).timeout(timeout);
      if (_isSuccess(response.statusCode) &&
          (response.contentLength ?? 0) > 0) {
        return SourceInfo(
          contentLength: response.contentLength,
          acceptsRanges: _advertisesRanges(response.headers),
        );
      }
    } on Exception {
      // Not every server implements HEAD; fall through to the range request.
    }

    final request = http.Request('GET', url)
      ..headers[HttpHeaders.rangeHeader] = 'bytes=0-0';
    final response = await httpClient.send(request).timeout(timeout);
    await response.stream.drain<void>();

    if (!_isSuccess(response.statusCode)) {
      throw HttpException(
        'Source returned HTTP ${response.statusCode}.',
        uri: url,
      );
    }

    final total = _totalFromContentRange(
      response.headers[HttpHeaders.contentRangeHeader],
    );
    if (total != null) {
      return SourceInfo(contentLength: total, acceptsRanges: true);
    }

    // The range was ignored: the response is the whole entity.
    return SourceInfo(
      contentLength: response.contentLength,
      acceptsRanges: _advertisesRanges(response.headers),
    );
  } finally {
    if (client == null) httpClient.close();
  }
}

bool _isSuccess(int statusCode) => statusCode >= 200 && statusCode < 300;

bool _advertisesRanges(Map<String, String> headers) =>
    headers[HttpHeaders.acceptRangesHeader]?.toLowerCase().contains('bytes') ??
    false;

/// Parses the total size out of a `Content-Range: bytes 0-0/1234` header.
/// Returns null for an unknown (`*`) or malformed total.
int? _totalFromContentRange(String? contentRange) {
  if (contentRange == null) return null;
  final slash = contentRange.lastIndexOf('/');
  if (slash < 0) return null;
  return int.tryParse(contentRange.substring(slash + 1).trim());
}
