package Sledge::Middleware::OpenTelemetry;
#
# Creates the HTTP server span, continuing the trace from a traceparent header if present.
# Does nothing unless Sledge::Tracing->setup has been called.
#
#   enable '+Sledge::Middleware::OpenTelemetry', skip => qr{^/healthz$};
#
# Paths matching skip (health checks etc.) get no span.
#
# Enable it outside (before) AccessLog so that access logs also get trace_id.
#

use strict;
use base qw(Plack::Middleware);
use Plack::Util;
use Plack::Util::Accessor qw(skip);

use Sledge::Tracing;

sub call {
    my($self, $env) = @_;
    return $self->app->($env) unless Sledge::Tracing->enabled;
    if ($self->skip && ($env->{PATH_INFO} || '') =~ $self->skip) {
	my $res = $self->app->($env);
	Sledge::Tracing->flush_if_due;
	return $res;
    }

    require OpenTelemetry::Constants;
    my $parent = OpenTelemetry->propagator->extract($env, undef, \&_getter);
    my $span = Sledge::Tracing->tracer->create_span(
	name       => $env->{REQUEST_METHOD},
	kind       => OpenTelemetry::Constants::SPAN_KIND_SERVER(),
	parent     => $parent,
	attributes => _request_attributes($env),
    );
    my $context = OpenTelemetry::Trace->context_with_span($span, $parent);

    my $res = do {
	my $previous = OpenTelemetry::Context->current;
	OpenTelemetry::Context->current = $context;
	my $res = eval { $self->app->($env) };
	my $error = $@;
	OpenTelemetry::Context->current = $previous;
	if ($error) {
	    _set_error($span, $error);
	    $span->end;
	    Sledge::Tracing->flush_if_due;
	    die $error;
	}
	$res;
    };

    return $self->response_cb($res, sub {
	my $res = shift;
	my $status = $res->[0];
	$span->set_attribute('http.response.status_code' => $status + 0);
	_set_error($span, $status) if $status >= 500;

	my $finished;
	my $finish = sub {
	    return if $finished++;
	    $span->end;
	    Sledge::Tracing->flush_if_due;
	};

	# End and export the span after the response is sent (so it does not add latency)
	if ($env->{'psgix.cleanup'}) {
	    push @{$env->{'psgix.cleanup.handlers'}}, $finish;
	    return;
	}
	if (ref $res->[2] eq 'ARRAY') {
	    my @chunks = @{$res->[2]};
	    $res->[2] = Plack::Util::inline_object(
		getline => sub { shift @chunks },
		close   => $finish,
	    );
	    return;
	}
	if (defined $res->[2]) {
	    my $body = $res->[2];
	    $res->[2] = Plack::Util::inline_object(
		getline => sub { $body->getline },
		close   => sub { $body->close; $finish->() },
	    );
	    return;
	}
	return sub {
	    my $chunk = shift;
	    $finish->() unless defined $chunk;
	    return $chunk;
	};
    });
}

sub _getter {
    my($env, $key) = @_;
    (my $name = uc $key) =~ tr/-/_/;
    return $env->{"HTTP_$name"};
}

sub _request_attributes {
    my $env = shift;
    my %attr = (
	'http.request.method'      => $env->{REQUEST_METHOD},
	'url.path'                 => $env->{PATH_INFO} || '/',
	'url.scheme'               => $env->{'psgi.url_scheme'},
	'server.address'           => $env->{HTTP_HOST} || $env->{SERVER_NAME},
	'client.address'           => $env->{REMOTE_ADDR},
	'user_agent.original'      => $env->{HTTP_USER_AGENT},
	'network.protocol.version' => ($env->{SERVER_PROTOCOL} || '') =~ m{HTTP/(\S+)} ? $1 : undef,
    );
    $attr{'url.query'} = $env->{QUERY_STRING} if length($env->{QUERY_STRING} // '');
    delete $attr{$_} for grep { !defined $attr{$_} } keys %attr;
    return \%attr;
}

sub _set_error {
    my($span, $error) = @_;
    require OpenTelemetry::Constants;
    if (ref $error || $error !~ /^\d+$/) {
	$span->record_exception($error);
	my($message) = split /\n/, "$error", 2;
	$span->set_status(OpenTelemetry::Constants::SPAN_STATUS_ERROR(), $message);
    } else {
	$span->set_status(OpenTelemetry::Constants::SPAN_STATUS_ERROR(), "HTTP $error");
    }
}

1;
