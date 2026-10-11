use strict;
use Test::More;
use lib 't/lib';

BEGIN {
    eval { require Plack::Test; require CGI::PSGI; 1 }
	or plan skip_all => 'Plack and CGI::PSGI are required';
}

use HTTP::Request::Common;
use Plack::Test;

package Mock::PSGI::Pages;
use base qw(Sledge::Pages::PSGI);
use Sledge::Authorizer::Null;
use Sledge::Charset::Default;
use Sledge::SessionManager::Cookie;
use Sledge::Template::TT;

use vars qw($TMPL_PATH);
$TMPL_PATH = 't/template';

sub create_authorizer { Sledge::Authorizer::Null->new(shift) }
sub create_manager    { Sledge::SessionManager::Cookie->new(shift) }
sub create_charset    { Sledge::Charset::Default->new(shift) }
sub create_config     { Sledge::TestConfig->new(shift) }
sub create_session    { my $self = shift; Sledge::TestSession->new($self, @_) }

sub dispatch_psgi {
    my $self = shift;
}

sub post_dispatch_psgi {
    my $self = shift;
    $self->session->param(posted => scalar $self->r->param('name'));
}

sub dispatch_redirect {
    my $self = shift;
    $self->redirect('/psgi');
}

package main;

# Use the TestConfig / TestSession defined by Sledge::TestPages
require Sledge::TestPages;

my $app = Mock::PSGI::Pages->to_app(default_page => 'psgi');

test_psgi $app, sub {
    my $cb = shift;

    my $res = $cb->(GET '/psgi?name=miyagawa');
    is $res->code, 200, 'GET /psgi';
    is $res->content_type, 'text/html', 'content type';
    like $res->header('Set-Cookie'), qr/^sledge_sid=\w+/, 'session cookie';
    is $res->header('Content-Length'), length($res->content), 'content length';
    like $res->content, qr/miyagawa/, 'template output with param';

    my($sid) = $res->header('Set-Cookie') =~ /sledge_sid=(\w+)/;
    $res = $cb->(GET '/psgi', Cookie => "sledge_sid=$sid");
    ok !$res->header('Set-Cookie'), 'existing session reused';

    $res = $cb->(GET '/');
    is $res->code, 200, 'default page';

    $res = $cb->(POST '/psgi', [ name => 'bar' ]);
    is $res->code, 200, 'POST /psgi';
    like $res->content, qr/bar/;

    $res = $cb->(GET '/redirect');
    is $res->code, 302, 'redirect status';
    is $res->header('Location'), 'http://localhost/psgi', 'absolute redirect URL';

    $res = $cb->(GET '/nonexistent');
    is $res->code, 404, 'unknown page is 404';

    $res = $cb->(GET '/../etc/passwd');
    is $res->code, 404, 'path traversal is 404';
};

done_testing;
