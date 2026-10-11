package Sledge::Pages::PSGI;
#
# A Pages implementation for running Sledge on PSGI (plackup / Starlet / Starman etc.),
# so it can run as an HTTP server in a container without mod_perl.
#

use strict;
use base qw(Sledge::Pages::Base);

use Sledge::Request::PSGI;
use Sledge::Tracing;

sub create_request {
    my($self, $env) = @_;
    return Sledge::Request::PSGI->new($env);
}

sub current_url {
    my($self, $scheme) = @_;
    $scheme ||= $self->r->env->{'psgi.url_scheme'} || 'http';
    return $self->SUPER::current_url($scheme);
}

# Handles one request and returns a PSGI response
sub handle_psgi {
    my($class, $env, $page) = @_;

    # For existing code that reads %ENV (such as CGI::Cookie->fetch),
    # provide CGI-compatible environment variables for the duration of the request
    local %ENV = (%ENV, _cgi_env($env));

    # Name the server span after the route (page)
    if (my $span = Sledge::Tracing->current_span) {
	$span->set_name("$env->{REQUEST_METHOD} /$page");
	$span->set_attribute('http.route' => "/$page");
    }

    my $res = eval {
	my $self = $class->new($env);
	my $r = $self->r;
	$self->dispatch($page);
	$r->finalize;
    };
    return $res if $res;

    my $error = $@;
    # In development, let Plack::Middleware::StackTrace show the stack trace
    die $error if ($ENV{PLACK_ENV} || '') eq 'development';

    require Sledge::Logger;
    Sledge::Logger->default->error('unhandled exception', {
	error  => "$error",
	class  => $class,
	page   => $page,
	method => $env->{REQUEST_METHOD},
	path   => $env->{PATH_INFO},
    });
    return [ 500, [ 'Content-Type' => 'text/plain' ], [ "Internal Server Error\n" ] ];
}

# Returns a PSGI app that uses the first PATH_INFO segment as the page name and calls dispatch_XXX
#   /        => dispatch_index (can be changed with default_page)
#   /foo     => dispatch_foo
#   /foo.cgi => dispatch_foo
sub to_app {
    my($class, %opt) = @_;
    my $default = $opt{default_page} || 'index';
    return sub {
	my $env = shift;
	my $path = $env->{PATH_INFO} || '/';
	$path =~ s{^/+}{};
	$path =~ s{\.(?:cgi|html?)$}{};
	my $page = length $path ? $path : $default;
	unless ($page =~ /^\w+$/ && $class->can("dispatch_$page")) {
	    return [ 404, [ 'Content-Type' => 'text/plain' ], [ "Not Found\n" ] ];
	}
	return $class->handle_psgi($env, $page);
    };
}

sub _cgi_env {
    my $env = shift;
    my %cgi;
    for my $key (keys %$env) {
	next if $key =~ /^psgix?\./ || ref $env->{$key};
	$cgi{$key} = $env->{$key};
    }
    $cgi{HTTPS} = 'on' if ($env->{'psgi.url_scheme'} || '') eq 'https';
    return %cgi;
}

1;
__END__

=head1 NAME

Sledge::Pages::PSGI - Sledge Pages implementation for PSGI

=head1 SYNOPSIS

  package MyProj::Pages;
  use base qw(Sledge::Pages::PSGI);
  ...

  # app.psgi
  use MyProj::Pages::Root;
  MyProj::Pages::Root->to_app;

=head1 DESCRIPTION

Sledge::Pages::PSGI is a Pages implementation for running a Sledge application
as a PSGI application. C<to_app> returns a PSGI application that uses C<PATH_INFO>
as the page name and calls C<dispatch_XXX>.
To handle an arbitrary page, call C<handle_psgi($env, $page)> directly.

=head1 SEE ALSO

L<Sledge::Pages::Base>, L<Sledge::Request::PSGI>, L<Plack>

=cut
