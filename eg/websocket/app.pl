#!/usr/bin/env perl
# Sample WebSocket server that runs next to the sample Sledge app (eg/psgi).
#
#   perl -I lib eg/websocket/app.pl          # listens on SLEDGE_WS_PORT (default 5001)
#
# Route /ws to this server and everything else to the Sledge app (see
# eg/docker/nginx.conf). Both must share the session store (SLEDGE_REDIS_SERVER
# or SLEDGE_SESSION_SECRET) and the cookie name.
use strict;
use warnings;
use File::Basename ();
use File::Spec;
use lib map { File::Spec->catdir(File::Basename::dirname(__FILE__), @$_) } [ 'lib' ], [ '..', 'psgi', 'lib' ];

use Sledge::Logger;
use Sledge::Tracing;
use MyChat;

Sledge::Logger->capture_warnings;
Sledge::Tracing->setup if $ENV{OTEL_EXPORTER_OTLP_ENDPOINT} || $ENV{OTEL_TRACES_EXPORTER};

MyChat->new->run_server;
