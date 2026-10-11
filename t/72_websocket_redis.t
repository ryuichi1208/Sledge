use strict;
use warnings;
use Test::More;

BEGIN {
    plan skip_all => 'set SLEDGE_TEST_REDIS_SERVER to run Redis tests'
	unless $ENV{SLEDGE_TEST_REDIS_SERVER};
    eval { require Mojolicious; require Mojo::Redis; 1 }
	or plan skip_all => 'Mojolicious and Mojo::Redis are required';
}

use Mojo::IOLoop;
use Redis::Fast;
use Test::Mojo;
use Sledge::Logger;
use Sledge::Session;
use Sledge::Session::Redis;

open my $null, '>', '/dev/null' or die;
Sledge::Logger->default(Sledge::Logger->new(fh => $null));

package Test::WSR::Config;
our %C = (cookie_name => 'sid', redis_server => $ENV{SLEDGE_TEST_REDIS_SERVER});
sub new { bless {}, shift }
sub AUTOLOAD { our $AUTOLOAD; (my $k = $AUTOLOAD) =~ s/.*:://; exists $C{$k} ? $C{$k} : die "no such key: $k" }
sub DESTROY { }

package Test::WSR::App;
use Mojo::Base 'Sledge::WebSocket', -signatures;
sub sledge_config ($self) { Test::WSR::Config->new }
sub on_open ($self, $conn) {
    my $room = $conn->session->{room};
    $conn->join($room)->then(sub { $conn->send({ type => 'ready', instance => $self->instance_id }) });
}
sub on_message ($self, $conn, $data) {
    $self->broadcast($conn->session->{room} => { from => $conn->session->{name}, text => $data->{text} });
}

package main;

# Two instances of the server, standing in for two pods
my $pod1 = Test::WSR::App->new(instance_id => 'pod-1');
my $pod2 = Test::WSR::App->new(instance_id => 'pod-2');
is $pod1->session_store, 'redis', 'session store detected from REDIS_SERVER';

# Sessions written the way Sledge::Session::Redis stores them
my $redis = Redis::Fast->new(server => $ENV{SLEDGE_TEST_REDIS_SERVER});
my $room = "room-$$";
my %sid;
for my $name (qw(alice bob)) {
    $sid{$name} = Sledge::Session->_gen_session_id;
    $redis->set($Sledge::Session::Redis::KeyPrefix . $sid{$name},
		Sledge::Session->_serialize({ name => $name, room => $room }), 'EX', 60);
}

my $t1 = Test::Mojo->new($pod1);
my $t2 = Test::Mojo->new($pod2);

$t1->websocket_ok('/ws' => { Cookie => "sid=$sid{alice}" })
    ->message_ok->json_message_is('/type' => 'ready')->json_message_is('/instance' => 'pod-1');
$t2->websocket_ok('/ws' => { Cookie => "sid=$sid{bob}" })
    ->message_ok->json_message_is('/type' => 'ready')->json_message_is('/instance' => 'pod-2');

$t1->send_ok({ json => { text => 'hello from pod-1' } });
$t1->message_ok->json_message_is('/text' => 'hello from pod-1', 'sender gets it through pub/sub');
$t2->message_ok('message crosses instances')->json_message_is('/from' => 'alice');

$t2->send_ok({ json => { text => 'reply from pod-2' } });
$t2->message_ok->json_message_is('/text' => 'reply from pod-2');
$t1->message_ok->json_message_is('/from' => 'bob', 'reply crosses back');

$t1->websocket_ok('/ws' => { Cookie => 'sid=' . ('0' x 32) })->finished_ok(4401, 'unknown session closes with 4401');
$t1->websocket_ok('/ws' => { Cookie => 'sid=../../etc' })->finished_ok(4401, 'malformed session id closes with 4401');

# Leaving the last member unsubscribes the channel
$t2->finish_ok;
Mojo::IOLoop->one_tick until !%{$pod2->connections};
ok !$pod2->rooms->{$room}, 'empty room is removed';
my $channels;
$pod1->pubsub->channels_p("sledge:ws:$room")->then(sub { $channels = shift })->wait;
is_deeply $channels, [ "sledge:ws:$room" ], 'only pod-1 is still subscribed';

$redis->del(map { $Sledge::Session::Redis::KeyPrefix . $_ } values %sid);
done_testing;
