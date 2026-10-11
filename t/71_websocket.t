use strict;
use warnings;
use Test::More;

BEGIN {
    eval { require Mojolicious; require Test::Mojo; 1 }
	or plan skip_all => 'Mojolicious is required';
}

use File::Temp qw(tempfile);
use Mojo::IOLoop;
use Sledge::Logger;
use Sledge::SessionManager::EncryptedCookie;

# Keep the test output clean; errors are asserted through the API instead
open my $null, '>', '/dev/null' or die;
Sledge::Logger->default(Sledge::Logger->new(fh => $null));

package Test::WS::Config;
our %C = (
    cookie_name        => 'sid',
    session_secret     => 'x' x 32,
    ws_rate_limit      => 5,
    ws_max_message_size => 1024,
    ws_ping_interval   => 60,
);
sub new { bless {}, shift }
sub AUTOLOAD { our $AUTOLOAD; (my $k = $AUTOLOAD) =~ s/.*:://; exists $C{$k} ? $C{$k} : die "no such key: $k" }
sub DESTROY { }

package Test::WS::App;
use Mojo::Base 'Sledge::WebSocket', -signatures;
sub sledge_config ($self) { Test::WS::Config->new }
sub on_open ($self, $conn) {
    $conn->join('lobby')->then(sub { $conn->send({ type => 'welcome', user => $conn->session->{name} }) });
}
sub on_message ($self, $conn, $data) {
    die "boom\n" if ($data->{text} // '') eq 'die';
    $self->broadcast(lobby => { type => 'message', user => $conn->session->{name}, text => $data->{text} });
}

package main;

my $app = Test::WS::App->new;
my $t = Test::Mojo->new($app);

sub cookie_for {
    my $name = shift;
    my $page = bless { config => Test::WS::Config->new }, 'Sledge::WebSocket::_Page';
    my $value = Sledge::SessionManager::EncryptedCookie->encrypt($page, {
	sid => 'a' x 32, data => { name => $name }, exp => time + 60,
    });
    return "sid=$value";
}

my $port = $t->ua->server->url->port;
my $origin = "http://127.0.0.1:$port";
my %alice = (Cookie => cookie_for('alice'), Origin => $origin);
my %bob   = (Cookie => cookie_for('bob'),   Origin => $origin);

# --- health ---
$t->get_ok('/healthz')->status_is(200)->content_is("ok\n");
$t->get_ok('/readyz')->status_is(200)->json_is('/status', 'ok');

# --- handshake checks ---
my %upgrade = (Upgrade => 'websocket', Connection => 'Upgrade',
	       'Sec-WebSocket-Key' => 'dGhlIHNhbXBsZSBub25jZQ==', 'Sec-WebSocket-Version' => 13);
sub handshake_status {
    my($t, %headers) = @_;
    return $t->ua->get('/ws' => { %upgrade, %headers })->res->code;
}

$t->websocket_ok('/ws' => { Origin => $origin })->finished_ok(4401, 'no session cookie closes with 4401');
$t->websocket_ok('/ws' => { Origin => $origin, Cookie => 'sid=forged' })->finished_ok(4401, 'forged cookie closes with 4401');
is handshake_status($t, %alice, Origin => 'https://evil.example'), 403, 'cross-site origin is rejected';
{
    local $Test::WS::Config::C{ws_allowed_origins} = 'https://app.example';
    my $t2 = Test::Mojo->new(Test::WS::App->new);
    is handshake_status($t2, %alice, Origin => $origin), 403, 'origin not in allowed list';
    $t2->websocket_ok('/ws' => { %alice, Origin => 'https://app.example' }, 'allowed origin')
	->message_ok->json_message_is('/type', 'welcome')->finish_ok;
}
{
    # messages sent before the session is loaded are buffered, not lost
    my $t3 = Test::Mojo->new(Test::WS::App->new);
    $t3->websocket_ok('/ws' => { %alice, Origin => 'http://127.0.0.1:' . $t3->ua->server->url->port })
	->send_ok({ json => { text => 'early' } });
    my @types;
    $t3->message_ok->json_message_is('/type' => 'welcome', 'on_open runs first');
    $t3->message_ok->json_message_is('/text' => 'early', 'early message is delivered after authentication')->finish_ok;
}

# --- messaging ---
my $t_bob = Test::Mojo->new($app);
$t->websocket_ok('/ws' => \%alice)->message_ok->json_message_is('/type' => 'welcome')->json_message_is('/user' => 'alice');
$t_bob->websocket_ok('/ws' => { %bob, Origin => 'http://127.0.0.1:' . $t_bob->ua->server->url->port })
    ->message_ok->json_message_is('/user' => 'bob');
is scalar keys %{$app->connections}, 2, 'two connections';

$t->send_ok({ json => { text => 'hello' } });
$t->message_ok->json_message_is('/text' => 'hello')->json_message_is('/user' => 'alice');
$t_bob->message_ok('broadcast reaches the other client')->json_message_is('/text' => 'hello');

$t->send_ok('not json')->message_ok->json_message_is('/type' => 'error', 'invalid JSON is rejected');
$t->send_ok({ json => { text => 'die' } })->message_ok->json_message_is('/error' => 'internal error', 'handler exception');
$t->send_ok({ json => { text => 'still alive' } })->message_ok->json_message_is('/text' => 'still alive', 'connection survives');
$t_bob->message_ok->json_message_is('/text' => 'still alive', 'failed handler does not broadcast');

$t->send_ok({ json => { text => 'x' x 2000 } })->finished_ok(1009, 'oversized frame closes with 1009');

# --- rate limit ---
$t->websocket_ok('/ws' => \%alice)->message_ok;
$t->send_ok({ json => { text => $_ } }) for 1..7;
$t->message_ok for 1..5;
$t->finished_ok(1008, 'rate limit closes with 1008');
$t_bob->message_ok for 1..5;

# --- graceful shutdown ---
my $done;
$app->shutdown(sub { $done = 1 });
$t_bob->finished_ok(1001, 'clients are closed with 1001 on shutdown');
$t->get_ok('/readyz')->status_is(503)->json_is('/status', 'draining');
is handshake_status($t, %alice), 503, 'new connections are refused while draining';
Mojo::IOLoop->one_tick until $done;
ok $done, 'shutdown completes';
is scalar keys %{$app->connections}, 0, 'no connections left';

done_testing;
