# Sledge

Sledge is an open source web application framework for Perl.
For the original documentation, see `README`, `INSTALL` and `lib/Sledge/Doc/`.

This document explains how to run Sledge in containers (Ubuntu 26.04 + Perl 5.44) and on Kubernetes.

## Runtime environment

| Component | Version |
|---|---|
| Base image | `ubuntu:26.04` |
| Perl | 5.44.0 (built from source into `/opt/perl`) |
| Application server | Starlet (PSGI) |

Ubuntu 26.04 ships Perl 5.40, so the `Dockerfile` builds the latest stable release instead.
To use another version, pass the `PERL_VERSION` and `PERL_SHA256` build args.

## Development environment

```sh
docker compose build
docker compose up -d                      # sample app at http://localhost:5000, plus MySQL / PostgreSQL / Valkey / Jaeger
docker compose run --rm dev prove -lr t   # tests (including the MySQL / PostgreSQL / Valkey tests)
docker compose run --rm dev bash          # shell
```

The `app` service runs `plackup -R`, so changes under `lib/` and `eg/psgi/` are reloaded automatically.
Sessions are stored in Valkey, and traces can be viewed in the Jaeger UI (http://localhost:16686).

## Production image

```sh
docker build -t sledge .
docker run --rm -p 5000:5000 sledge
```

- Runs as a non-root user (UID 10001).
- `SLEDGE_PSGI` selects the PSGI file to run (defaults to the sample app).
- `SLEDGE_WORKERS` sets the number of workers, and `SLEDGE_MAX_REQS_PER_CHILD` sets how many requests a worker serves before it is replaced.
- Logs, including access logs, are written to stderr as JSON.

## Running on PSGI

mod_perl 1.x does not work with current Perl, so `Sledge::Pages::PSGI` was added.
An existing application can run as a PSGI application by changing its base class from
`Sledge::Pages::Compat` (or `Sledge::Pages::CGI`) to `Sledge::Pages::PSGI`.

```perl
package MyApp::Pages;
use base qw(Sledge::Pages::PSGI);
```

```perl
# app.psgi
use Plack::Builder;
use MyApp::Pages::Root;

builder {
    mount '/healthz' => sub { [200, ['Content-Type' => 'text/plain'], ["ok\n"]] };
    mount '/'        => MyApp::Pages::Root->to_app;   # /foo => dispatch_foo
};
```

`to_app` uses `PATH_INFO` as the page name and calls `dispatch_XXX`.
Paths without a matching method return 404.
A complete working example is in `eg/psgi/`.

### Sample app environment variables

| Variable | Description |
|---|---|
| `SLEDGE_SESSION_STORE` | `redis` / `dbi` / `cookie` / `none` / `auto` (default; uses the first one that is configured, in that order) |
| `SLEDGE_REDIS_SERVER` / `SLEDGE_REDIS_PASSWORD` | Redis / Valkey session store (`host:port`) |
| `SLEDGE_DSN` / `SLEDGE_DB_USER` / `SLEDGE_DB_PASSWORD` | MySQL / PostgreSQL session store |
| `SLEDGE_SESSION_SECRET` | Key for encrypted cookie sessions (at least 32 characters; comma-separate multiple keys to rotate them) |
| `SLEDGE_SESSION_TTL` | Session lifetime in seconds (default 86400). Used by the Redis and encrypted cookie stores |
| `SLEDGE_TMPL_PATH` | Template directory |
| `SLEDGE_COOKIE_NAME` / `SLEDGE_COOKIE_DOMAIN` | Session cookie |
| `SLEDGE_COOKIE_SECURE` / `SLEDGE_COOKIE_HTTPONLY` / `SLEDGE_COOKIE_SAMESITE` | Cookie attributes (defaults: `Secure` over https, `HttpOnly`, `SameSite=Lax`) |
| `SLEDGE_BEHIND_PROXY` | When `1`, trust `X-Forwarded-*` headers |
| `SLEDGE_LOG_LEVEL` / `SLEDGE_LOG_FORMAT` | Log level (default `info`) and format, `json` (default) or `text` |
| `OTEL_*` | Standard OpenTelemetry environment variables (see below) |

Appending `_FILE` to any variable reads the value from that file (for example `SLEDGE_DB_PASSWORD_FILE=/run/secrets/db-password`).

When connecting to MySQL 8.4 or later, add `mysql_ssl=1` to the DSN
(`caching_sha2_password` authentication requires TLS).
Make the `a_session` column `MEDIUMBLOB` (see `eg/docker/mysql-init/01-sessions.sql`).

## Cloud-native features

### Configuration: `Sledge::Config::Env`

Reads configuration from environment variables (ConfigMaps / Secrets).

```perl
package MyApp::Config;
use base qw(Sledge::Config::Env Class::Singleton);
__PACKAGE__->env_prefix('MYAPP_');
__PACKAGE__->defaults({ TMPL_PATH => '/app/tmpl', COOKIE_PATH => '/' });
__PACKAGE__->required([qw(SESSION_SECRET)]);   # fails at startup if missing
sub _new_instance { shift->new }
```

- `MYAPP_FOO` becomes `$config->foo`.
- `MYAPP_FOO_FILE` reads the value from a file.
- If `DSN` / `DB_USER` / `DB_PASSWORD` are set, `DATASOURCE` is built from them.

### Sessions

| Class | Storage | Notes |
|---|---|---|
| `Sledge::Session::Redis` | Redis / Valkey | Expired by TTL. Concurrent access to the same session is serialized with a lock |
| `Sledge::SessionManager::EncryptedCookie` | Cookie (AES-256-GCM) | No server-side store needed. Limited to about 4KB |
| `Sledge::Session::MySQL` / `Pg` / `SQLite` | RDBMS | Unchanged |

Changes that apply to every store:

- Session IDs are generated from the operating system's cryptographically secure random source. They used to be derived from the time and `rand()`, which made them guessable.
- Session data is stored as JSON. Storable is unsafe to load when the data has been tampered with, and its format is not guaranteed to be compatible across Perl versions.
  - Existing Storable sessions can still be read. Set `$Sledge::Session::AllowLegacyStorable = 0` once the migration is complete.
  - Applications that store objects or code references in the session should set `$Sledge::Session::Serializer = 'Storable'`.
- Cookies get `HttpOnly` and `SameSite=Lax` by default, plus `Secure` over https.
- The DBI connection cache is kept per process, so child processes of a prefork server never share their parent's connection.

### Logging: `Sledge::Logger`

Writes one JSON object per line to stderr.

```perl
$self->logger->info('order created', { order_id => $id });
# {"level":"info","msg":"order created","order_id":42,"request_id":"...","span_id":"...","time":"2026-10-11T05:26:07.647Z","trace_id":"..."}
```

| Middleware | Purpose |
|---|---|
| `Sledge::Middleware::RequestId` | Propagates or generates `X-Request-Id` and adds it to logs and the response headers |
| `Sledge::Middleware::AccessLog` | Writes access logs as JSON. 5xx responses are logged at `error` level |

Exceptions not handled by the application are logged as JSON by `Sledge::Pages::PSGI`, which then returns a 500 without exposing details
(when `PLACK_ENV=development`, they are passed on to Plack::Middleware::StackTrace instead).

### Tracing: OpenTelemetry

```perl
# app.psgi
use Sledge::Tracing;
Sledge::Tracing->setup(instrumentations => [ 'DBI' ]);

builder {
    enable '+Sledge::Middleware::RequestId';
    enable '+Sledge::Middleware::OpenTelemetry', skip => qr{^/healthz$};   # enable outside (before) AccessLog
    enable '+Sledge::Middleware::AccessLog';
    ...
};
```

Recorded spans:

```
GET /index                       (SERVER; continues the incoming traceparent)
|- Sledge session load
|  `- SET / SELECT GET_LOCK ...  (Redis commands, DBI)
|- Sledge dispatch_index
|  `- (add your own spans with Sledge::Tracing->in_span)
|- Sledge render
`- Sledge session save
```

Configure tracing with the standard OpenTelemetry environment variables
(`OTEL_SERVICE_NAME`, `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_TRACES_SAMPLER`, `OTEL_SDK_DISABLED`, and so on).

The Perl SDK's BatchSpanProcessor exports spans from an IO::Async event loop.
A prefork server such as Starlet never runs that loop, so spans would never be exported.
Sledge uses `Sledge::Tracing::SpanProcessor` instead, which exports synchronously after the response has been sent to the client.

| Variable | Default | Description |
|---|---|---|
| `OTEL_BSP_SCHEDULE_DELAY` | 0 | Export interval in milliseconds. 0 exports after every response. With a longer interval, spans stay in an idle worker until it receives its next request (Starlet tends to hand connections to the same worker) |
| `OTEL_BSP_MAX_EXPORT_BATCH_SIZE` | 512 | Export immediately once this many spans are queued |
| `OTEL_BSP_MAX_QUEUE_SIZE` | 2048 | Per-worker queue limit. The oldest spans are dropped when it is exceeded |
| `OTEL_BSP_EXPORT_TIMEOUT` | 1000 | Export timeout in milliseconds |
| `SLEDGE_OTEL_FAILURE_BACKOFF` | 30 | After a failed export, stop exporting for this many seconds (so a collector outage does not stall workers) |

When a worker exits (SIGTERM or `max-reqs-per-child`), it exports its remaining spans first.

## Kubernetes

```sh
kubectl create secret generic sledge-db --from-literal=SLEDGE_REDIS_SERVER=valkey:6379
kubectl apply -k k8s/base
```

Before applying, change `images` in `k8s/base/kustomization.yaml` to the image you pushed.
See the comments in the same file for how to create the Secret for each session store and where to point the OpenTelemetry Collector.

The manifests:

- Use `/healthz` for the startup, readiness and liveness probes.
- Enable `readOnlyRootFilesystem` and mount an emptyDir only at `/tmp` (for file uploads).
- Wait 5 seconds in `preStop` before SIGTERM is sent. Starlet finishes in-flight requests before exiting.
  `preStop.sleep` requires Kubernetes 1.30 or later.
- Add `k8s.pod.name` / `k8s.namespace.name` to traces.
- Require sessions to live in Redis / Valkey, an RDBMS, or an encrypted cookie when running multiple pods.
  Do not use `Sledge::Session::File`, because files are not shared between pods.

### Running locally with kind

`k8s/local` is an overlay that also runs Valkey and Jaeger in the same namespace.

```sh
kind create cluster --name sledge
docker build -t sledge:local .
kind load docker-image sledge:local --name sledge
kubectl apply -k k8s/local

kubectl -n sledge port-forward svc/sledge 8080:80        # http://localhost:8080
kubectl -n sledge port-forward svc/jaeger 16686:16686    # http://localhost:16686
```

After rebuilding the image, run `kind load` again and then `kubectl -n sledge rollout restart deploy/sledge`.

## Changes for current Perl

- Replaced `Digest::SHA1` with the core `Digest::SHA`, and `UNIVERSAL::require` with plain `require`.
- Removed the dependency on `Encode::compat` (for Perl 5.6).
- `Class::Trigger` 0.14 and later no longer validate hook names in subclasses, so `register_hook` now validates them.
- Fixed `Sledge::Charset::UTF8` double-encoding byte-string output as UTF-8.
- `Sledge::Request::Upload::link` now copies the file when a hard link fails because the target is on another filesystem.
- Fixed `Makefile.PL` failing on Perl 5.26 and later, where `@INC` no longer contains `.`.
- `Sledge::Pages::Apache` (mod_perl 1.x) cannot be used with current Perl.
