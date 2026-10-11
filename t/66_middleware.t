use strict;
use Test::More;
use lib 't/lib';

use Cpanel::JSON::XS;
use File::Temp qw(tempfile);
use HTTP::Request::Common;
use Plack::Builder;
use Plack::Test;
use Sledge::Logger;

package Mock::MW::Pages;
use base qw(Sledge::Pages::PSGI);
use Sledge::Authorizer::Null;
use Sledge::Charset::Default;
use Sledge::SessionManager::Null;
use Sledge::Template::TT;

use vars qw($TMPL_PATH);
$TMPL_PATH = 't/template';

sub create_authorizer { Sledge::Authorizer::Null->new(shift) }
sub create_manager    { Sledge::SessionManager::Null->new(shift) }
sub create_charset    { Sledge::Charset::Default->new(shift) }
sub create_config     { Sledge::TestConfig->new(shift) }

sub dispatch_psgi {
    my $self = shift;
    $self->logger->info('in page', { page => 'psgi' });
}

sub dispatch_die { die "boom\n" }

package main;
require Sledge::TestPages;

my(undef, $file) = tempfile(UNLINK => 1);
open my $fh, ">>", $file or die;  # keep appending at the end even after truncate
Sledge::Logger->default(Sledge::Logger->new(fh => $fh));

sub logs {
    open my $in, '<', $file or die;
    my @rec = map { decode_json($_) } <$in>;
    truncate $file, 0;
    return @rec;
}

my $app = builder {
    enable '+Sledge::Middleware::RequestId';
    enable '+Sledge::Middleware::AccessLog', skip => qr{^/healthz$};
    mount '/healthz' => sub { [ 200, [], [ 'ok' ] ] };
    mount '/' => Mock::MW::Pages->to_app;
};

local $ENV{PLACK_ENV} = 'deployment';

test_psgi $app, sub {
    my $cb = shift;

    my $res = $cb->(GET '/psgi?x=1', 'User-Agent' => 'test-agent');
    my $id = $res->header('X-Request-Id');
    like $id, qr/\A[0-9a-f]{32}\z/, 'request id generated';

    my @rec = logs();
    is @rec, 2, 'app log + access log';
    is $rec[0]{msg}, 'in page';
    is $rec[0]{request_id}, $id, 'app log has request id';
    is $rec[1]{type}, 'access';
    is $rec[1]{request_id}, $id, 'access log has request id';
    is $rec[1]{status}, 200;
    is $rec[1]{method}, 'GET';
    is $rec[1]{path}, '/psgi';
    is $rec[1]{query}, 'x=1';
    is $rec[1]{user_agent}, 'test-agent';
    is $rec[1]{bytes}, length $res->content, 'bytes';
    ok $rec[1]{duration_ms} >= 0, 'duration';

    $res = $cb->(GET '/psgi', 'X-Request-Id' => 'from-ingress-123');
    is $res->header('X-Request-Id'), 'from-ingress-123', 'incoming id propagated';
    is +(logs())[1]{request_id}, 'from-ingress-123';

    $res = $cb->(GET '/psgi', 'X-Request-Id' => "bad id\n{json}");
    like $res->header('X-Request-Id'), qr/\A[0-9a-f]{32}\z/, 'invalid id replaced';
    logs();

    $res = $cb->(GET '/die');
    is $res->code, 500, 'exception is 500';
    is $res->content, "Internal Server Error\n", 'no details leaked';
    @rec = logs();
    is $rec[0]{level}, 'error';
    is $rec[0]{msg}, 'unhandled exception';
    is $rec[0]{error}, "boom\n";
    is $rec[0]{request_id}, $res->header('X-Request-Id');
    is $rec[1]{level}, 'error', '5xx access log is error level';

    $res = $cb->(GET '/healthz');
    is $res->code, 200;
    is scalar(logs()), 0, 'healthz is not logged';
};

{
    local $ENV{PLACK_ENV} = 'development';
    test_psgi $app, sub {
	my $res = shift->(GET '/die');
	is $res->code, 500;
	like $res->content, qr/boom/, 'development rethrows for StackTrace';
	logs();
    };
}

done_testing;
