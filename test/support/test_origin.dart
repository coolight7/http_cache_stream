import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// A configurable local origin HTTP server for end-to-end tests.
///
/// Serves a fixed in-memory [payload] over loopback, honoring `Range` requests
/// (RFC 7233, single ranges) and exposing knobs to simulate the header
/// combinations and failure modes the cache must handle. Behavior is controlled
/// by mutable public fields so individual tests can tweak a single aspect.
class TestOrigin {
  TestOrigin._(this._server, this.payload);

  final HttpServer _server;

  /// The bytes this origin serves for a `200`/`206` response.
  ///
  /// Mutable so lifecycle tests can simulate changed content at the same URL.
  Uint8List payload;

  // ---- Behavior knobs (mutate per-test) ----

  /// When false, `Range` requests are ignored and the full `200` body is sent.
  bool supportRanges = true;

  /// Value for the `Content-Type` header. Null omits the header.
  String? contentType = 'audio/mpeg';

  /// Value for the `ETag` header. Null omits it. Mutable to simulate a source
  /// change between requests.
  String? etag = '"v1"';

  /// Value for the `Last-Modified` header. Null omits it.
  DateTime? lastModified = DateTime.utc(2024, 1, 1, 0, 0, 0);

  /// Value for the `Cache-Control` header. Null omits it.
  String? cacheControl;

  /// When set, every response uses this status code and an empty body (used to
  /// simulate `404`/`500`/`416`).
  int? forcedStatusCode;

  /// When set, a `200` response declares this `Content-Length` instead of the
  /// real payload length (used to simulate a lying server).
  int? lyingContentLength;

  /// When set, the server writes only this many bytes of the body and then
  /// destroys the socket, simulating a mid-stream connection drop. Applies once
  /// then resets to null so a retry can succeed.
  int? dropAfterBytes;

  /// When true, omits Content-Length and sends the response with chunked
  /// transfer encoding, leaving the source length unknown until completion.
  bool chunkedTransferEncoding = false;

  /// When set, the response flushes its body and waits for this gate before
  /// closing. This allows tests to dispose a download before a chunked response
  /// sends its clean end-of-stream signal.
  Completer<void>? responseCloseGate;

  /// When set with [responseBodyGateAfterBytes], the response sends that many
  /// body bytes, flushes them, and waits before sending the remainder. This
  /// makes it possible to stop a download at a deterministic partial position.
  Completer<void>? responseBodyGate;

  /// Number of bytes to send before waiting on [responseBodyGate]. Ignored when
  /// it is outside the requested body's bounds.
  int? responseBodyGateAfterBytes;

  // ---- Observability ----

  int requestCount = 0;
  String? lastMethod;
  String? lastRangeHeader;
  final List<String?> rangeHeaders = [];

  // Reported as `localhost` (not the bound `127.0.0.1`) so the source host
  // differs from the cache server's loopback host; otherwise the package treats
  // the source URL as an already-encoded cache URL. `localhost` still resolves
  // to loopback where the origin is listening.
  Uri get baseUri => Uri(scheme: 'http', host: 'localhost', port: _server.port);

  /// A source URL on this origin for the given [path] (e.g. `/media/file.mp3`).
  Uri url(String path) => baseUri.replace(path: path);

  static Future<TestOrigin> start(Uint8List payload) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final origin = TestOrigin._(server, payload);
    origin._listen();
    return origin;
  }

  void _listen() {
    _server.listen((request) {
      _handle(request).catchError((_) {/* client closed; ignore */});
    });
  }

  Future<void> _handle(HttpRequest request) async {
    requestCount++;
    lastMethod = request.method;
    final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
    lastRangeHeader = rangeHeader;
    rangeHeaders.add(rangeHeader);

    final response = request.response;

    if (forcedStatusCode != null) {
      response.statusCode = forcedStatusCode!;
      await response.close();
      return;
    }

    _setCommonHeaders(response);

    // Resolve the requested byte range.
    // Keep one request internally consistent if a test swaps [payload] while a
    // previous response is paused at [responseBodyGate].
    final responsePayload = payload;
    final total = responsePayload.length;
    int start = 0;
    int endEx = total; // exclusive
    final isRange = supportRanges && rangeHeader != null;

    if (isRange) {
      final parsed = _parseRange(rangeHeader, total);
      if (parsed == null) {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$total');
        await response.close();
        return;
      }
      start = parsed[0];
      endEx = parsed[1];
      response.statusCode = HttpStatus.partialContent;
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-${endEx - 1}/$total',
      );
    } else {
      response.statusCode = HttpStatus.ok;
    }

    final bodyLength = endEx - start;
    if (chunkedTransferEncoding) {
      response.headers.chunkedTransferEncoding = true;
    } else {
      response.headers.contentLength = lyingContentLength ?? bodyLength;
    }

    if (request.method == 'HEAD') {
      await response.close();
      return;
    }

    final body = Uint8List.sublistView(responsePayload, start, endEx);

    final drop = dropAfterBytes;
    if (drop != null && drop < body.length) {
      dropAfterBytes = null; // one-shot
      final socket = await response.detachSocket(writeHeaders: true);
      socket.add(Uint8List.sublistView(body, 0, drop));
      await socket.flush();
      socket.destroy();
      return;
    }

    final bodyGate = responseBodyGate;
    final bodyGateAfterBytes = responseBodyGateAfterBytes;
    if (bodyGate != null &&
        bodyGateAfterBytes != null &&
        bodyGateAfterBytes > 0 &&
        bodyGateAfterBytes < body.length) {
      response.add(Uint8List.sublistView(body, 0, bodyGateAfterBytes));
      await response.flush();
      await bodyGate.future;
      response.add(Uint8List.sublistView(body, bodyGateAfterBytes));
    } else {
      response.add(body);
    }
    if (responseCloseGate case final gate?) {
      await response.flush();
      await gate.future;
    }
    await response.close();
  }

  void _setCommonHeaders(HttpResponse response) {
    response.headers.clear();
    if (supportRanges) {
      response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    }
    if (contentType != null) {
      response.headers.set(HttpHeaders.contentTypeHeader, contentType!);
    }
    if (etag != null) {
      response.headers.set(HttpHeaders.etagHeader, etag!);
    }
    if (lastModified != null) {
      response.headers
          .set(HttpHeaders.lastModifiedHeader, HttpDate.format(lastModified!));
    }
    if (cacheControl != null) {
      response.headers.set(HttpHeaders.cacheControlHeader, cacheControl!);
    }
  }

  /// Parses a single `bytes=start-end` range header into `[start, endExclusive]`,
  /// or null if unsatisfiable. Supports open-ended `bytes=start-`.
  List<int>? _parseRange(String header, int total) {
    const prefix = 'bytes=';
    if (!header.startsWith(prefix)) return null;
    final value = header.substring(prefix.length).trim();
    final parts = value.split('-');
    if (parts.length != 2) return null;
    final start = int.tryParse(parts[0]);
    if (start == null || start < 0 || start >= total) return null;
    int endInclusive;
    if (parts[1].isEmpty) {
      endInclusive = total - 1;
    } else {
      final parsed = int.tryParse(parts[1]);
      if (parsed == null) return null;
      endInclusive = parsed >= total ? total - 1 : parsed;
    }
    if (endInclusive < start) return null;
    return [start, endInclusive + 1];
  }

  Future<void> close() => _server.close(force: true);
}
