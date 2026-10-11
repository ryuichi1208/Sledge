package Sledge::Middleware::AccessLog;
#
# Writes access logs as JSON through Sledge::Logger.
#
#   enable '+Sledge::Middleware::AccessLog', skip => qr{^/healthz$};
#

use strict;
use base qw(Plack::Middleware);
use Plack::Util;
use Plack::Util::Accessor qw(logger skip);
use Time::HiRes ();

use Sledge::Logger;

sub prepare_app {
    my $self = shift;
    $self->logger(Sledge::Logger->default) unless $self->logger;
}

sub call {
    my($self, $env) = @_;
    my $start = [ Time::HiRes::gettimeofday() ];
    my $request_id = $env->{'sledge.request_id'};

    my $res = $self->app->($env);
    return $res if $self->skip && ($env->{PATH_INFO} || '') =~ $self->skip;

    return $self->response_cb($res, sub {
	my $res = shift;
	my $size = 0;
	my $log = sub {
	    local $Sledge::Logger::Context{request_id} = $request_id if defined $request_id;
	    $self->_log($env, $res->[0], $size, $start);
	};
	if (ref $res->[2] eq 'ARRAY') {
	    $size += length for grep defined, @{$res->[2]};
	    $log->();
	    return;
	}
	# For streaming / filehandle bodies, log once the body has been sent
	return sub {
	    my $chunk = shift;
	    if (defined $chunk) {
		$size += length $chunk;
	    } else {
		$log->();
	    }
	    return $chunk;
	};
    });
}

sub _log {
    my($self, $env, $status, $size, $start) = @_;
    my $level = $status >= 500 ? 'error' : 'info';
    $self->logger->log($level => 'request', {
	type        => 'access',
	method      => $env->{REQUEST_METHOD},
	path        => $env->{PATH_INFO},
	query       => $env->{QUERY_STRING},
	status      => $status + 0,
	bytes       => $size,
	duration_ms => sprintf('%.3f', Time::HiRes::tv_interval($start) * 1000) + 0,
	remote_addr => $env->{REMOTE_ADDR},
	user_agent  => $env->{HTTP_USER_AGENT},
	referer     => $env->{HTTP_REFERER},
	protocol    => $env->{SERVER_PROTOCOL},
    });
}

1;
