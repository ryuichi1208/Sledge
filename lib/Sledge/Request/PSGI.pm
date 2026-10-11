package Sledge::Request::PSGI;
#
# PSGI version of Sledge::Request::CGI.
# Buffers output instead of printing to STDOUT, and finalize() returns the PSGI response.
#

use strict;
use base qw(Sledge::Request::CGI);
__PACKAGE__->mk_accessors(qw(env body header_sent));

use CGI::PSGI;

sub new {
    my($class, $env) = @_;
    my $self = $class->SUPER::new(CGI::PSGI->new($env));
    $self->env($env);
    $self->body([]);
    return $self;
}

sub header_in {
    my($self, $key) = @_;
    $key = uc $key;
    $key =~ tr/-/_/;
    return $self->env->{CONTENT_TYPE}   if $key eq 'CONTENT_TYPE';
    return $self->env->{CONTENT_LENGTH} if $key eq 'CONTENT_LENGTH';
    return $self->env->{"HTTP_$key"};
}

sub method {
    my $self = shift;
    return $self->env->{REQUEST_METHOD} || 'GET';
}

sub uri {
    my $self = shift;
    my $uri = $self->env->{REQUEST_URI};
    $uri =~ s/\?.*$// if defined $uri;
    return $uri;
}

sub args {
    my $self = shift;
    return $self->env->{QUERY_STRING};
}

sub send_http_header {
    my $self = shift;
    $self->header_sent(1);
}

sub print {
    my $self = shift;
    push @{$self->body}, @_;
}

sub finalize {
    my $self = shift;
    my %header = %{$self->header_hash};
    my $status = delete $header{Status} || 200;
    $status =~ s/^(\d{3}).*/$1/;

    my @headers;
    for my $key (sort keys %header) {
	push @headers, map { ($key => $_) }
	    ref $header{$key} eq 'ARRAY' ? @{$header{$key}} : $header{$key};
    }
    return [ $status, \@headers, $self->body ];
}

1;
__END__

=head1 NAME

Sledge::Request::PSGI - PSGI request/response wrapper for Sledge

=head1 SEE ALSO

L<Sledge::Pages::PSGI>

=cut
