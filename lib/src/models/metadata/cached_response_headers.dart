import 'dart:io';

import 'package:http_cache_stream/src/cache_stream/cache_downloader/custom_http_client.dart';
import 'package:http_cache_stream/src/models/http_range/http_range_response.dart';
import 'package:mime/mime.dart';

class CachedResponseHeaders {
  final Map<String, List<String>> _headers;
  CachedResponseHeaders(this._headers);

  ///Compares this [CachedResponseHeaders] to the given [next] [CachedResponseHeaders] to determine if the cache is outdated.
  ///CachedResponseHeaders.fromFile() supports validating against a HEAD request by comparing sourceLength and lastModified.
  bool validate(CachedResponseHeaders next) {
    if (sourceLength == null || sourceLength != next.sourceLength) {
      return false; //Valid source length is required
    }
    final previousTag = eTag;
    final nextTag = next.eTag;
    if (previousTag != null && nextTag != null) {
      return previousTag == nextTag;
    }
    final previousLastModified = lastModified;
    final nextLastModified = next.lastModified;
    if (previousLastModified != null && nextLastModified != null) {
      return !nextLastModified.isAfter(previousLastModified);
    }
    return !_headers.entries.any((entry) {
      return entry.key != HttpHeaders.dateHeader && !next.equals(entry.key, entry.value.firstOrNull);
    });
  }

  String? get(String key) {
    return _headers[key]?.firstOrNull;
  }

  ///If the host supports range requests.
  late final bool acceptsRangeRequests = equals(HttpHeaders.acceptRangesHeader, 'bytes');

  bool shouldRevalidate() {
    final expirationDateTime = this.expirationDateTime;
    return expirationDateTime == null || DateTime.now().isAfter(expirationDateTime);
  }

  DateTime? get expirationDateTime {
    final expiresHeaderDateTime = parseHeaderDateTime(HttpHeaders.expiresHeader);
    if (expiresHeaderDateTime != null) {
      return expiresHeaderDateTime;
    }
    final cacheControl = get(HttpHeaders.cacheControlHeader);
    if (cacheControl == null) return null;
    final maxAgeMatch = RegExp(r'max-age=(\d+)').firstMatch(cacheControl);
    if (maxAgeMatch == null) return null;
    final maxAgeSeconds = int.tryParse(maxAgeMatch.group(1)!);
    if (maxAgeSeconds == null || maxAgeSeconds <= 0) return null;
    final responseDate = parseHeaderDateTime(HttpHeaders.dateHeader);
    if (responseDate == null) return null;
    return responseDate.add(Duration(seconds: maxAgeSeconds));
  }

  ContentType? get contentType {
    final contentTypeHeader = get(HttpHeaders.contentTypeHeader);
    return contentTypeHeader == null ? null : ContentType.parse(contentTypeHeader);
  }

  String? get eTag => get(HttpHeaders.etagHeader);

  ///Gets the source length of the response. This is used to determine the total length of the response data.
  late final int? sourceLength = isCompressedOrChunked ? null : contentLength;

  int? get contentLength {
    final headerValue = get(HttpHeaders.contentLengthHeader);
    if (headerValue == null) return null;
    final length = int.tryParse(headerValue) ?? -1;
    return length > 0 ? length : null;
  }

  /// Returns true if the response is compressed or chunked. This means that the content length != source length, and the source length cannot be determined until the download is complete.
  bool get isCompressedOrChunked {
    return equals(HttpHeaders.contentEncodingHeader, 'gzip') || equals(HttpHeaders.transferEncodingHeader, 'chunked');
  }

  DateTime? get lastModified => parseHeaderDateTime(HttpHeaders.lastModifiedHeader);
  DateTime? get responseDate => parseHeaderDateTime(HttpHeaders.dateHeader);

  ///Attempts to parse [DateTime] from the given [httpHeader].
  DateTime? parseHeaderDateTime(String httpHeader) {
    final value = get(httpHeader);
    if (value == null || value.isEmpty) return null;
    try {
      return HttpDate.parse(value); // Try to parse the date (not all servers return a valid date)
    } catch (e) {
      return null;
    }
  }

  bool equals(String httpHeader, String? value) => get(httpHeader) == value;

  ///Sets the source length of the response. This is used once all data from a compressed or chunked response has been received.
  CachedResponseHeaders setSourceLength(int sourceLength) {
    final Map<String, List<String>> headers = {..._headers};
    headers[HttpHeaders.acceptRangesHeader] = ['bytes'];
    headers[HttpHeaders.contentLengthHeader] = [sourceLength.toString()];
    headers.remove(HttpHeaders.contentRangeHeader);
    headers.remove(HttpHeaders.contentEncodingHeader);
    headers.remove(HttpHeaders.transferEncodingHeader);
    return CachedResponseHeaders(headers);
  }

  ///Extracts [CachedResponseHeaders] from a [HttpClientResponse].
  ///Attempts to determine the source length from the response, and sets the content length header accordingly.
  ///If the response is compressed or chunked, the content length header is removed.
  ///If the response is a range response, the content range header is removed, and the source length is set to the range source length.
  factory CachedResponseHeaders.fromHttpResponse(HttpClientResponse response) {
    final Map<String, List<String>> headers = {};
    response.headers.forEach((key, value) {
      headers[key] = value;
    });
    int? sourceLength;
    final responseRange = HttpRangeResponse.parse(response);
    if (response.compressionState == HttpClientResponseCompressionState.decompressed) {
      headers[HttpHeaders.contentEncodingHeader] = ['gzip'];
    } else if (response.headers.chunkedTransferEncoding) {
      headers[HttpHeaders.transferEncodingHeader] = ['chunked'];
    } else if (responseRange != null) {
      sourceLength = responseRange.sourceLength;
    } else if (response.contentLength > 0) {
      sourceLength = response.contentLength;
    }
    if (sourceLength != null) {
      headers[HttpHeaders.contentLengthHeader] = [sourceLength.toString()];
    } else {
      headers.remove(HttpHeaders.contentLengthHeader);
    }
    headers.remove(HttpHeaders.contentRangeHeader);
    if (!headers.containsKey(HttpHeaders.dateHeader)) {
      headers[HttpHeaders.dateHeader] = [HttpDate.format(DateTime.now())];
    }
    return CachedResponseHeaders(headers);
  }

  ///Constructs a [CachedResponseHeaders] object from the given [uri] by sending a HEAD request.
  static Future<CachedResponseHeaders> fromUri(Uri uri, [Map<String, Object>? headers]) async {
    final client = CustomHttpClient();
    try {
      final response = await client.headUrl(uri, headers);
      return CachedResponseHeaders.fromHttpResponse(response);
    } finally {
      client.close();
    }
  }

  ///Simulates a [CachedResponseHeaders] object from the given [file].
  ///Returns null if the file does not exist or is empty.
  static CachedResponseHeaders? fromFile(File file) {
    final fileStat = file.statSync();
    if (fileStat.size <= 0) return null;
    final headers = {
      HttpHeaders.contentLengthHeader: [fileStat.size.toString()],
      HttpHeaders.acceptRangesHeader: ['bytes'],
      HttpHeaders.contentTypeHeader: [lookupMimeType(file.path) ?? 'application/octet-stream'],
      HttpHeaders.lastModifiedHeader: [HttpDate.format(fileStat.modified)],
      HttpHeaders.dateHeader: [HttpDate.format(DateTime.now())],
    };
    return CachedResponseHeaders(headers);
  }

  static CachedResponseHeaders? fromJson(dynamic json) {
    if (json is! Map<String, dynamic>) return null;
    final Map<String, List<String>> headers = {};
    json.forEach((key, value) {
      headers[key] = value is List ? value.cast<String>() : [value.toString()];
    });
    return CachedResponseHeaders(headers);
  }

  Map<String, List<String>> toJson() {
    return _headers;
  }

  void forEach(void Function(String, Object) action) => _headers.forEach(action);

  Map<String, List<String>> get headerMap => {..._headers};
}
