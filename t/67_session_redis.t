use strict;
use Test::More;

BEGIN {
    plan skip_all => 'set SLEDGE_TEST_REDIS_SERVER to run Redis tests'
	unless $ENV{SLEDGE_TEST_REDIS_SERVER};
}

use Sledge::Session::Redis;

package Mock::Pages;
sub create_config { bless {}, 'Mock::Config' }
sub current_url { 'http://localhost/' }

package Mock::Config;
sub redis_server { $ENV{SLEDGE_TEST_REDIS_SERVER} }
sub redis_password { $ENV{SLEDGE_TEST_REDIS_PASSWORD} }
sub session_ttl { 60 }

package main;

my $page = bless {}, 'Mock::Pages';
local $Sledge::Session::Redis::KeyPrefix = "sledge:test:$$:";

my $sid;
{
    my $session = Sledge::Session::Redis->new($page);
    ok $session->is_fresh, 'new session';
    $sid = $session->session_id;
    $session->param(foo => 'bar');
}

my $redis = Sledge::Session::Redis->_connect_database($page);
my $key = "sledge:test:$$:$sid";
like $redis->get($key), qr/"foo":"bar"/, 'stored as JSON';
my $ttl = $redis->ttl($key);
ok $ttl > 0 && $ttl <= 60, "TTL is set ($ttl)";
ok !$redis->exists("$key:lock"), 'lock released';

{
    my $session = Sledge::Session::Redis->new($page, $sid);
    ok !$session->is_fresh;
    is $session->param('foo'), 'bar', 'restored';
    ok $redis->exists("$key:lock"), 'lock held while session alive';

    # opening the same session from another request times out waiting for the lock
    local $Sledge::Session::Redis::LockWait = 0.2;
    eval { Sledge::Session::Redis->new($page, $sid) };
    like "$@", qr/timed out waiting for session lock/, 'concurrent access is serialized';

    $session->param(foo => 'baz');
}
is +Sledge::Session::Redis->new($page, $sid)->param('foo'), 'baz', 'updated';

eval { Sledge::Session::Redis->new($page, 'f' x 32) };
isa_ok $@, 'Sledge::Exception::SessionIdNotFound', 'unknown sid';
ok !$redis->exists("sledge:test:$$:" . ('f' x 32) . ':lock'), 'lock released on not found';

{
    my $session = Sledge::Session::Redis->new($page, $sid);
    $session->expire;
}
ok !$redis->exists($key), 'expire deletes key';
ok !$redis->exists("$key:lock"), 'lock released after expire';

done_testing;
