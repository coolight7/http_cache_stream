import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http_cache_stream/src/cache_stream/cache_downloader/custom_http_client.dart';
import 'package:http_cache_stream/src/models/http_range/http_range_response.dart';
import 'package:util_xx/util_xx.dart';

import '../../etc/mime_types.dart';
import '../exceptions/http_exceptions.dart';
import 'cache_files.dart';

@immutable
class CachedResponseHeaders {
  final HttpFullHeaderxx _headers;
  CachedResponseHeaders._(
    this._headers, {
    int? sourceLength,
  }) : _sourceLength = sourceLength;

  String? get(String key) => _headers[key]?.firstOrNull;
  List<String>? getList(String key) => _headers[key];

  ///If the host supports range requests.
  late final bool acceptsRangeRequests = equals(
    HttpHeaders.acceptRangesHeader,
    'bytes',
  );

  bool canResumeDownload() => acceptsRangeRequests && !isCompressedOrChunked;

  bool shouldRevalidate() {
    final expirationDateTime = cacheExpirationDateTime;
    return expirationDateTime == null ||
        DateTime.now().isAfter(expirationDateTime);
  }

  DateTime? get cacheExpirationDateTime {
    final expiresHeaderDateTime = parseHeaderDateTime(
      HttpHeaders.expiresHeader,
    );
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
    return contentTypeHeader == null
        ? null
        : ContentType.parse(contentTypeHeader);
  }

  String? get eTag => get(HttpHeaders.etagHeader);

  ///Gets the source length of the response. This is used to determine the total length of the response data.
  ///Returns null if the source length is unknown (e.g. for compressed or chunked responses). Otherwise, returns a positive integer.
  int? get sourceLength =>
      _sourceLength ?? (isCompressedOrChunked ? null : contentLength);
  final int? _sourceLength;

  int? get contentLength {
    final contentLengthValue = get(HttpHeaders.contentLengthHeader);
    if (contentLengthValue == null) return null;
    final length = int.tryParse(contentLengthValue) ?? -1;
    return length > 0 ? length : null;
  }

  /// Returns true if the response is compressed or chunked. This means that the content length != source length, and the source length cannot be determined until the download is complete.
  bool get isCompressedOrChunked {
    return equals(HttpHeaders.contentEncodingHeader, 'gzip') ||
        equals(HttpHeaders.transferEncodingHeader, 'chunked');
  }

  DateTime? get lastModified =>
      parseHeaderDateTime(HttpHeaders.lastModifiedHeader);
  DateTime? get responseDate => parseHeaderDateTime(HttpHeaders.dateHeader);

  ///Attempts to parse [DateTime] from the given [httpHeader].
  DateTime? parseHeaderDateTime(String httpHeader) {
    final value = get(httpHeader);
    if (value == null || value.isEmpty) return null;
    try {
      return HttpDate.parse(
          value); // Try to parse the date (not all servers return a valid date)
    } catch (e) {
      return null;
    }
  }

  bool equals(String httpHeader, String? value) => get(httpHeader) == value;

  ///Sets the source length of the response. This is used once all data from a compressed or chunked response has been received.
  CachedResponseHeaders setSourceLength(final int sourceLength) {
    final headers = Httpxx_c.createFullHeader(data: _headers);
    headers[HttpHeaders.acceptRangesHeader] = ['bytes'];
    headers[HttpHeaders.contentLengthHeader] = [sourceLength.toString()];
    headers.remove(HttpHeaders.contentRangeHeader);
    headers.remove(HttpHeaders.contentEncodingHeader);
    headers.remove(HttpHeaders.transferEncodingHeader);
    return CachedResponseHeaders._(headers, sourceLength: sourceLength);
  }

  /// Filters the headers to only include essential headers for caching.
  CachedResponseHeaders essentialHeaders() {
    final retainedHeaders = Httpxx_c.createFullHeader();

    const List<String> essentialHeaders = [
      HttpHeaders.contentLengthHeader,
      HttpHeaders.acceptRangesHeader,
      HttpHeaders.contentTypeHeader,
      HttpHeaders.lastModifiedHeader,
      HttpHeaders.dateHeader,
      HttpHeaders.expiresHeader,
      HttpHeaders.cacheControlHeader,
      HttpHeaders.etagHeader,
      HttpHeaders.contentEncodingHeader,
      HttpHeaders.transferEncodingHeader,
    ];

    for (final header in essentialHeaders) {
      final value = _headers[header];
      if (value != null) {
        retainedHeaders[header] = value;
      }
    }

    return CachedResponseHeaders._(retainedHeaders);
  }

  ///Extracts [CachedResponseHeaders] from a [BaseResponse].
  ///If the response is a range response, the content range header is removed, and the source length is set to the range source length.
  factory CachedResponseHeaders.fromBaseResponse(
    HttpFullHeaderAnyxx respheaders,
  ) {
    final headers = Httpxx_c.createFullHeader(data: respheaders);

    int? rangeSourceLength;
    if (headers.containsKey(HttpHeaders.contentRangeHeader)) {
      headers[HttpHeaders.acceptRangesHeader] = [
        'bytes'
      ]; // Ensure accept-ranges is set to bytes for range responses. Not all servers do this.

      final HttpRangeResponse? rangeResponse =
          HttpRangeResponse.parseFromHeader(headers);
      if (rangeResponse != null) {
        rangeSourceLength = rangeResponse.sourceLength;
        if (rangeSourceLength != null) {
          headers[HttpHeaders.contentLengthHeader] = [
            rangeSourceLength.toString()
          ];
        } else if (!rangeResponse.isFull) {
          headers.remove(HttpHeaders.contentLengthHeader);
        }
      }
    }

    return CachedResponseHeaders._(headers, sourceLength: rangeSourceLength);
  }

  ///Constructs a [CachedResponseHeaders] object from the given [url] by sending a HEAD request.
  static Future<CachedResponseHeaders> fromUrl(
    final Uri url, {
    required final CustomHttpClientxx httpClient,
    Map<String, String>? requestHeaders,
  }) async {
    final response = await httpClient.headUrl(
      url,
      requestHeaders,
    );
    if (false ==
        Httpxx_c.respIsSuccess(response.statusCode,
            message: response.statusMessage, allow3xx: true)) {
      throw HttpStatusCodeException(
        url,
        HttpStatus.ok,
        response.statusCode ?? -1,
      );
    }
    return CachedResponseHeaders.fromBaseResponse(response.headers.map);
  }

  static CachedResponseHeaders? fromCacheFiles(final CacheFiles cacheFiles) {
    try {
      if (cacheFiles.metadata.existsSync()) {
        final json = jsonDecode(cacheFiles.metadata.readAsStringSync());
        if (json is Map<String, dynamic>) {
          final headersFromJson =
              CachedResponseHeaders.fromJson(json['headers']);
          if (headersFromJson != null) return headersFromJson;
        }
      }
      return CachedResponseHeaders.fromFile(cacheFiles.complete);
    } catch (_) {
      return null;
    }
  }

  ///Simulates a [CachedResponseHeaders] object from the given [file].
  ///Returns null if the file does not exist or is empty.
  static CachedResponseHeaders? fromFile(final File file) {
    final fileStat = file.statSync();
    final fileSize = fileStat.size;
    if (fileStat.type != FileSystemEntityType.file || fileSize <= 0) {
      return null;
    }
    final contentTypeFromPath = MimeTypes.fromPath(file.path);

    final headers = Httpxx_c.createFullHeader(data: {
      HttpHeaders.contentLengthHeader: [fileSize.toString()],
      HttpHeaders.acceptRangesHeader: ['bytes'],
      HttpHeaders.contentTypeHeader: [
        contentTypeFromPath ?? 'application/octet-stream'
      ],
      HttpHeaders.lastModifiedHeader: [HttpDate.format(fileStat.modified)],
      HttpHeaders.dateHeader: [HttpDate.format(DateTime.now())],
    });
    return CachedResponseHeaders._(headers, sourceLength: fileSize);
  }

  static CachedResponseHeaders? fromJson(dynamic json) {
    if (json is! Map<String, dynamic>) return null;
    final headers = Httpxx_c.createFullHeader();
    json.forEach((key, value) {
      if (value is List) {
        headers[key] = [value.join(', ')];
      } else if (value != null) {
        headers[key] = [value.toString()];
      }
    });
    return CachedResponseHeaders._(headers);
  }

  Map<String, List<String>> toJson() {
    return _headers;
  }

  void forEach(void Function(String, List<String>) action) =>
      _headers.forEach(action);

  HttpFullHeaderxx get headerMap => Httpxx_c.createFullHeader(data: _headers);
}
