use strict;
use Test::More;
use lib 't/lib';

package Mock::Pages;
use base qw(Sledge::TestPages);
use vars qw($TMPL_PATH $COOKIE_PATH $COOKIE_SECURE $COOKIE_HTTPONLY $COOKIE_SAMESITE $COOKIE_DOMAIN);
$TMPL_PATH   = 't/template';
$COOKIE_PATH = '/';

sub dispatch_foo { }

package main;

sub cookie_for {
    my $p = Mock::Pages->new;
    $p->dispatch('foo');
    my($cookie) = $p->output =~ /^Set-Cookie: (.*)$/m;
    return $cookie;
}

{
    my $cookie = cookie_for();
    like $cookie, qr/HttpOnly/, 'HttpOnly by default';
    like $cookie, qr/SameSite=Lax/, 'SameSite=Lax by default';
    unlike $cookie, qr/secure/i, 'no Secure over http';
}

{
    local $ENV{HTTPS} = 'on';
    like cookie_for(), qr/secure/, 'Secure over https';
}

{
    local $Mock::Pages::COOKIE_SECURE   = 1;
    local $Mock::Pages::COOKIE_HTTPONLY = 0;
    local $Mock::Pages::COOKIE_SAMESITE = 'Strict';
    local $Mock::Pages::COOKIE_DOMAIN   = 'example.com';
    my $cookie = cookie_for();
    like $cookie, qr/secure/, 'COOKIE_SECURE forces Secure';
    unlike $cookie, qr/HttpOnly/, 'COOKIE_HTTPONLY=0';
    like $cookie, qr/SameSite=Strict/, 'COOKIE_SAMESITE';
    like $cookie, qr/domain=example\.com/, 'COOKIE_DOMAIN';
}

{
    local $ENV{HTTPS} = 'on';
    local $Mock::Pages::COOKIE_SECURE = 0;
    unlike cookie_for(), qr/secure/, 'COOKIE_SECURE=0 disables Secure';
}

done_testing;
