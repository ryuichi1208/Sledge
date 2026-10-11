# Sample of running Sledge on PSGI
#
#   plackup -I lib -I eg/psgi/lib eg/psgi/app.psgi
#
use strict;
use File::Basename ();
use File::Spec;
use lib File::Spec->catdir(File::Basename::dirname(__FILE__), 'lib');

use Plack::Builder;
use Sledge::Logger;
use Sledge::Tracing;
use MyApp::Pages::Root;

# Turn warn() into JSON too, so the log pipeline picks it up
Sledge::Logger->capture_warnings;

# OpenTelemetry (configured with the standard variables such as OTEL_EXPORTER_OTLP_ENDPOINT)
Sledge::Tracing->setup(instrumentations => [ 'DBI' ])
    if $ENV{OTEL_EXPORTER_OTLP_ENDPOINT} || $ENV{OTEL_TRACES_EXPORTER};

# Detect missing configuration at startup
MyApp::Config->instance;

my $health = sub { [ 200, [ 'Content-Type' => 'text/plain' ], [ "ok\n" ] ] };

builder {
    # Trust X-Forwarded-* behind an Ingress / load balancer
    enable_if { $ENV{SLEDGE_BEHIND_PROXY} } 'ReverseProxy';
    # Show exceptions in the browser during development (in production they are logged as JSON and a 500 is returned)
    enable_if { ($ENV{PLACK_ENV} || '') eq 'development' } 'StackTrace';
    enable '+Sledge::Middleware::RequestId';
    enable '+Sledge::Middleware::OpenTelemetry', skip => qr{^/healthz$};
    # Write access logs to stderr as JSON
    enable '+Sledge::Middleware::AccessLog', skip => qr{^/healthz$};

    # For Kubernetes liveness / readiness probes
    mount '/healthz' => $health;

    mount '/' => MyApp::Pages::Root->to_app;
};
