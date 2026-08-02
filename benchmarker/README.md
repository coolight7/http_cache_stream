# http_cache_stream benchmarker

A standalone Flutter app that benchmarks HTTP responses served by
`http_cache_stream`'s local cache server, and compares them against requests
that bypass the package entirely.

It depends on the package by path (`http_cache_stream: {path: ../}`), so it
always benchmarks the working copy of the repository.

Supported platforms: Android, iOS, Linux, macOS, Windows. Web is unsupported —
the benchmark relies on `dart:io` and `dart:isolate`.

```bash
cd benchmarker
flutter run -d <device>
```

## What it measures

Requests are issued by a pool of **long-lived worker isolates**. Each isolate
builds exactly one `http.Client` when it starts and reuses it for every request,
so connection pools stay warm both within and between runs. The pool is only
respawned when the concurrency or the client implementation changes.

### Inputs

| Input | Meaning |
| --- | --- |
| Source URL | The remote URL under test. |
| Concurrency | Number of worker isolates. |
| Total requests | Requests issued in total, divided evenly between the workers (the remainder goes to the lowest-numbered workers). |

### Run types

| Type | Behavior |
| --- | --- |
| **Pre-cached** | The file is fully downloaded first, then every benchmarked request is served from the completed cache file. |
| **Non-cached** | The cache files are deleted first, so the requests race the cache download. |
| **Direct** | `http_cache_stream` is bypassed; workers request the source URL. |

### HTTP client

The client each worker uses is chosen from a registry of
[`HttpClientBuilder`](lib/src/benchmark/http_client_builder.dart)s — top-level
functions sent to the isolate at spawn time. Add an entry to
`kHttpClientOptions` to benchmark another implementation (for example
`cupertino_http` or `cronet_http`); nothing else needs to change.

### Output

Per run, aggregated from the results streamed back by the workers and refreshed
roughly four times a second:

- Average, p50/p90/p99, min and max for **time to response headers**, **time to
  first byte**, and **time to completion**.
- **Requests per second**, **bytes per second**, total bytes, average response
  size, and elapsed wall-clock time.
- Outcome breakdown: verified, unverified (no `Content-Length`), byte
  mismatches, HTTP errors, and failures.

Every response's received byte count is checked against its `Content-Length`; a
mismatch is reported as a problem rather than a success.

For cache-server runs, the page also shows live download progress
(`x / y bytes`, percentage) taken from `HttpCacheStream.cacheStateStream`, and
errors emitted by that stream are written to the log panel along with the run's
status lines.

## Layout

```
lib/
  main.dart                              app entry; initializes HttpCacheManager
  src/benchmark/
    benchmark_config.dart                inputs, run types, request distribution
    benchmark_controller.dart            run orchestration and aggregation
    benchmark_stats.dart                 timing/percentile accumulation
    benchmark_worker.dart                worker isolate entry point
    http_client_builder.dart             selectable http client implementations
    worker_pool.dart                     long-lived isolate pool
    worker_protocol.dart                 messages exchanged with the workers
  src/ui/                                page and panels
```

## Tests

```bash
cd benchmarker
flutter test
```

The suite covers request distribution and statistics, drives real worker
isolates against a local origin server, and runs all three benchmark types
end-to-end through a real `HttpCacheManager`.

> When testing against a **loopback** origin, address it as `localhost` rather
> than `127.0.0.1`: `http_cache_stream` rejects source URLs whose host matches
> the cache server's own host.
