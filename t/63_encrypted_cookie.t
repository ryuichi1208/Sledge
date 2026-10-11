use strict;
use Test::More;
use lib 't/lib';

use HTTP::Request::Common;
use Plack::Test;
use Sledge::Logger;

package Mock::Cookie::Pages;
use base qw(Sledge::Pages::PSGI);
use Sledge::Authorizer::Null;
use Sledge::Charset::Default;
use Sledge::SessionManager::EncryptedCookie;
use Sledge::Template::TT;

use vars qw($TMPL_PATH $COOKIE_PATH $SESSION_SECRET $SESSION_TTL);
$TMPL_PATH      = 't/template';
$COOKIE_PATH    = '/';
$SESSION_SECRET = 'a' x 32;

sub create_authorizer { Sledge::Authorizer::Null->new(shift) }
sub create_manager    { Sledge::SessionManager::EncryptedCookie->new(shift) }
sub create_charset    { Sledge::Charset::Default->new(shift) }
sub create_config     { Sledge::TestConfig->new(shift) }

sub dispatch_psgi {
    my $self = shift;
    my $count = ($self->session->param('count') || 0) + 1;
    $self->session->param(count => $count);
    $self->r->header_out('X-Count' => $count);
}

sub dispatch_logout {
    my $self = shift;
    $self->session->expire;
    $self->redirect(q(/psgi));
}

sub dispatch_big {
    my $self = shift;
    $self->session->param(big => 'x' x 5000);
    $self->redirect(q(/psgi));
}

package main;
require Sledge::TestPages;

# Discard the error log of the cases that return 500
open my $null, ">", "/dev/null" or die;
Sledge::Logger->default(Sledge::Logger->new(fh => $null));

my $app = Mock::Cookie::Pages->to_app;

sub cookie_of {
    my $res = shift;
    my($value) = ($res->header('Set-Cookie') || '') =~ /sledge_sid=([^;]*)/;
    return $value;
}

test_psgi $app, sub {
    my $cb = shift;

    my $res = $cb->(GET '/psgi');
    is $res->header('X-Count'), 1, 'first visit';
    my $cookie = cookie_of($res);
    ok $cookie, 'session cookie issued';
    like $res->header('Set-Cookie'), qr/HttpOnly/;
    unlike $cookie, qr/count/, 'payload is not readable';

    $res = $cb->(GET '/psgi', Cookie => "sledge_sid=$cookie");
    is $res->header('X-Count'), 2, 'session restored from cookie';
    $cookie = cookie_of($res);

    $res = $cb->(GET '/psgi', Cookie => "sledge_sid=$cookie");
    is $res->header('X-Count'), 3;
    $cookie = cookie_of($res);

    # tampering
    (my $tampered = $cookie) =~ s/^(.{20})(.)/$1 . ($2 eq 'A' ? 'B' : 'A')/e;
    $res = $cb->(GET '/psgi', Cookie => "sledge_sid=$tampered");
    is $res->header('X-Count'), 1, 'tampered cookie starts new session';

    $res = $cb->(GET '/psgi', Cookie => "sledge_sid=garbage!!");
    is $res->header('X-Count'), 1, 'garbage cookie starts new session';

    # key rotation: old cookies are still readable after a new key is added at the front
    {
	local $Mock::Cookie::Pages::SESSION_SECRET = ('b' x 32) . ',' . ('a' x 32);
	$res = $cb->(GET '/psgi', Cookie => "sledge_sid=$cookie");
	is $res->header('X-Count'), 4, 'old key still decrypts';
	my $rotated = cookie_of($res);

	local $Mock::Cookie::Pages::SESSION_SECRET = 'b' x 32;
	$res = $cb->(GET '/psgi', Cookie => "sledge_sid=$rotated");
	is $res->header('X-Count'), 5, 're-encrypted with new key';
	$res = $cb->(GET '/psgi', Cookie => "sledge_sid=$cookie");
	is $res->header('X-Count'), 1, 'removed key no longer decrypts';
    }

    # expiry
    {
	local $Mock::Cookie::Pages::SESSION_TTL = -1;
	$res = $cb->(GET '/psgi');
	my $expired = cookie_of($res);
	local $Mock::Cookie::Pages::SESSION_TTL = 3600;
	$res = $cb->(GET '/psgi', Cookie => "sledge_sid=$expired");
	is $res->header('X-Count'), 1, 'expired cookie starts new session';
    }

    $res = $cb->(GET '/logout', Cookie => "sledge_sid=$cookie");
    like $res->header('Set-Cookie'), qr/sledge_sid=;.*expires=/, 'expire deletes cookie';

    $res = $cb->(GET q(/logout));
    is $res->code, 302, q(redirect);

    $res = $cb->(GET '/big');
    is $res->code, 500, 'too large session is an error';

    {
	local $Mock::Cookie::Pages::SESSION_SECRET = 'short';
	$res = $cb->(GET '/psgi');
	is $res->code, 500, 'short secret is rejected';
    }
};

done_testing;
