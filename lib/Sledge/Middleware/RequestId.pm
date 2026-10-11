package Sledge::Middleware::RequestId;
#
# Determines the request ID, stores it in $env and the Sledge::Logger context,
# and returns it in a response header. An ID set upstream (Ingress etc.) is kept.
#
#   enable '+Sledge::Middleware::RequestId';
#

use strict;
use base qw(Plack::Middleware);
use Plack::Util;
use Plack::Util::Accessor qw(header);

use Crypt::URandom ();
use Sledge::Logger;

sub prepare_app {
    my $self = shift;
    $self->header('X-Request-Id') unless $self->header;
}

sub call {
    my($self, $env) = @_;

    (my $env_key = 'HTTP_' . uc $self->header) =~ tr/-/_/;
    my $id = $env->{$env_key};
    # Restrict the format of external values so they cannot pollute the logs
    $id = unpack 'H*', Crypt::URandom::urandom(16)
	unless defined $id && $id =~ /\A[A-Za-z0-9._:-]{1,128}\z/;
    $env->{'sledge.request_id'} = $id;

    local $Sledge::Logger::Context{request_id} = $id;
    my $res = $self->app->($env);
    return $self->response_cb($res, sub {
	Plack::Util::header_set(shift->[1], $self->header, $id);
    });
}

1;
