package Sledge::WebSocket;
#
# Base class for WebSocket servers that live next to a Sledge application.
#
# Sledge pages run on a prefork server (Starlet), where every connection holds
# a worker, so long-lived WebSocket connections are served by this separate
# event-loop process instead (Mojolicious). It shares the Sledge session,
# logging and tracing, and uses Redis / Valkey pub/sub to deliver messages to
# clients connected to other pods.
#

use Mojo::Base 'Mojolicious', -signatures;

use Crypt::URandom ();
use Mojo::IOLoop;
use Mojo::JSON ();
use Mojo::Promise;
use Mojo::Server::Daemon;
use Mojo::Util ();
use Mojo::WebSocket qw(WS_PING);
use Scalar::Util ();
use Sys::Hostname ();
use Time::HiRes ();

use Sledge::Logger;
use Sledge::Session;
use Sledge::SessionManager::Cookie;
use Sledge::Tracing;
use Sledge::WebSocket::Connection;

# Defaults; each can be overridden by the SLEDGE_WS_* configuration keys
has ws_path          => sub { shift->_conf('ws_path', '/ws') };
has require_session  => sub { shift->_conf('ws_require_session', 1) };
has ping_interval    => sub { shift->_conf('ws_ping_interval', 25) };
has idle_timeout     => sub { shift->_conf('ws_idle_timeout', 60) };
has max_message_size => sub { shift->_conf('ws_max_message_size', 64 * 1024) };
has rate_limit       => sub { shift->_conf('ws_rate_limit', 20) };	# messages per second per connection
has close_timeout    => sub { shift->_conf('ws_close_timeout', 5) };	# seconds to wait for clients on shutdown
has allowed_origins  => sub {
    my $origins = shift->_conf('ws_allowed_origins', '');
    [ grep length, split /[\s,]+/, $origins ];
};

has instance_id => sub { $ENV{POD_NAME} || Sys::Hostname::hostname() . ":$$" };
has connections => sub { {} };	# id => Sledge::WebSocket::Connection
has rooms       => sub { {} };	# room => { id => connection }
has draining    => 0;
has redis       => sub {
    my $self = shift;
    my $server = $self->_conf('redis_server') or return undef;
    require Mojo::Redis;
    my $password = $self->_conf('redis_password');
    my $auth = defined $password && length $password ? ':' . Mojo::Util::url_escape($password) . '@' : '';
    return Mojo::Redis->new("redis://$auth$server");
};
has pubsub => sub {
    my $self = shift;
    my $redis = $self->redis or return undef;
    my $pubsub = $redis->pubsub;
    Scalar::Util::weaken(my $weak = $self);
    $pubsub->on(subscribe => sub ($pubsub, $channel, $ok) {
	my $p = delete $weak->{_subscribing}{$channel} or return;
	$ok ? $p->resolve : $p->reject("cannot subscribe to $channel");
    });
    $pubsub->on(disconnect => sub { $weak->logger->warn('pub/sub disconnected') });
    $pubsub->on(reconnect  => sub { $weak->logger->info('pub/sub reconnected') });
    return $pubsub;
};

my $CHANNEL_PREFIX = 'sledge:ws:';

# --- methods applications override -------------------------------------

# Returns the Sledge configuration object (e.g. MyApp::Config->instance)
sub sledge_config ($self) { die ref($self) . " must implement sledge_config\n" }

sub on_open    ($self, $conn) { }
sub on_message ($self, $conn, $data) { }
sub on_close   ($self, $conn, $code, $reason) { }

# --- public API --------------------------------------------------------

# Send $data to every client in $room, on every pod
sub broadcast ($self, $room, $data) {
    if (my $pubsub = $self->pubsub) {
	$pubsub->notify($CHANNEL_PREFIX . $room, Mojo::JSON::encode_json({
	    room => $room, data => $data, from => $self->instance_id,
	}));
    } else {
	$self->_deliver($room, $data);
    }
    return $self;
}

sub logger { Sledge::Logger->default }

# Start an HTTP server and run until SIGTERM / SIGINT, then shut down gracefully
sub run_server ($self, %opt) {
    my $port = $opt{port} || $ENV{SLEDGE_WS_PORT} || 5001;
    die "invalid port '$port' (SLEDGE_WS_PORT must be a number)\n" unless $port =~ /\A\d+\z/;
    my $daemon = Mojo::Server::Daemon->new(
	app    => $self,
	# "*" would also try IPv6, which fails on IPv4-only clusters; SLEDGE_WS_LISTEN overrides
	listen => [ $opt{listen} || $ENV{SLEDGE_WS_LISTEN} || "http://0.0.0.0:$port" ],
	silent => 1,
    );
    $daemon->start;
    $self->{_daemon} = $daemon;
    $self->logger->info('websocket server started', { port => $port + 0, instance => $self->instance_id });

    for my $sig (qw(TERM INT)) {
	$SIG{$sig} = sub {
	    Mojo::IOLoop->next_tick(sub { $self->shutdown(sub { Mojo::IOLoop->stop }) });
	};
    }
    Mojo::IOLoop->start unless Mojo::IOLoop->is_running;
    return $self;
}

# Stop accepting connections, close every client with 1001 (going away) so it
# reconnects to another pod, then call $done once they are gone or after close_timeout.
sub shutdown ($self, $done = sub { }) {
    return if $self->draining;
    $self->draining(1);
    $self->{_daemon}->stop if $self->{_daemon};
    my @conns = values %{$self->connections};
    $self->logger->info('websocket server shutting down', { connections => scalar @conns });
    $_->close(1001, 'server shutting down') for @conns;

    my $deadline = Time::HiRes::time() + $self->close_timeout;
    my $id; $id = Mojo::IOLoop->recurring(0.1 => sub {
	return if %{$self->connections} && Time::HiRes::time() < $deadline;
	Mojo::IOLoop->remove($id);
	Sledge::Tracing->shutdown;
	$done->();
    });
}

# --- Mojolicious setup -------------------------------------------------

sub startup ($self) {
    $self->_bridge_log;
    $self->secrets([ unpack 'H*', Crypt::URandom::urandom(16) ]);	# no signed cookies are used

    my $r = $self->routes;
    $r->get('/healthz' => sub ($c) { $c->render(text => "ok\n") });
    $r->get('/readyz' => sub ($c) {
	my $app = $c->app;
	$c->render(
	    status => $app->draining ? 503 : 200,
	    json   => {
		status      => $app->draining ? 'draining' : 'ok',
		connections => scalar keys %{$app->connections},
	    },
	);
    });

    my $ws = $r->under($self->ws_path => sub ($c) { $c->app->_authorize($c) });
    $ws->websocket('/' => sub ($c) { $c->app->_open($c) });

    Mojo::IOLoop->recurring($self->ping_interval => sub { $self->_ping_all });
}

# Checks that can be done synchronously, before the handshake is accepted.
# (Mojolicious sends the 101 response without waiting for asynchronous work,
# so the session is looked up after the handshake instead; see _open.)
sub _authorize ($self, $c) {
    if ($self->draining) {
	$c->render(text => "Service Unavailable\n", status => 503);
	return undef;
    }
    unless ($self->_origin_allowed($c)) {
	$self->logger->warn('websocket origin rejected', {
	    origin => $c->req->headers->origin, host => $c->req->headers->host,
	});
	$c->render(text => "Forbidden\n", status => 403);
	return undef;
    }
    return 1;
}

# Close codes sent when the session lookup fails. Browsers cannot see the HTTP
# status of a failed handshake, but they can see these codes.
use constant {
    CLOSE_UNAUTHORIZED => 4401,
    CLOSE_UNAVAILABLE  => 1011,
};
my $MAX_PENDING = 16;	# messages buffered while the session is being looked up

sub _open ($self, $c) {
    my $headers = $c->req->headers;
    my $request_id = $headers->header('X-Request-Id');
    $request_id = unpack 'H*', Crypt::URandom::urandom(16)
	unless defined $request_id && $request_id =~ /\A[A-Za-z0-9._:-]{1,128}\z/;

    my $conn = Sledge::WebSocket::Connection->new(
	app         => $self,
	controller  => $c,
	id          => unpack('H*', Crypt::URandom::urandom(8)),
	request_id  => $request_id,
	remote_addr => $headers->header('X-Forwarded-For') || $c->tx->remote_address,
    );
    Scalar::Util::weaken($conn->{app});
    $self->connections->{$conn->id} = $conn;

    $c->inactivity_timeout($self->idle_timeout);
    $c->tx->max_websocket_size($self->max_message_size);

    # Handlers must be registered before this action returns
    my($ready, @pending, @window);
    my $handle = sub ($text) {
	my $data = eval { Mojo::JSON::decode_json($text) };
	return $conn->send({ type => 'error', error => 'messages must be JSON objects' })
	    unless ref $data;
	$self->_traced('WS message', $conn, sub { $self->on_message($conn, $data) });
    };
    $c->on(message => sub ($c, $text) {
	my $now = Time::HiRes::time();
	@window = grep { $_ > $now - 1 } @window, $now;
	if (@window > $self->rate_limit) {
	    $self->logger->warn('websocket rate limit exceeded', $conn->log_fields);
	    return $conn->close(1008, 'rate limit exceeded');
	}
	return $handle->($text) if $ready;
	return $conn->close(1008, 'too many messages before authentication')
	    if @pending >= $MAX_PENDING;
	push @pending, $text;
    });
    $c->on(finish => sub ($c, $code, $reason) {
	$self->_leave($conn, $_) for keys %{$conn->rooms};
	delete $self->connections->{$conn->id};
	$self->logger->info('websocket closed', {
	    %{$conn->log_fields},
	    code        => $code + 0,
	    duration_ms => sprintf('%.0f', (Time::HiRes::time() - $conn->opened_at) * 1000) + 0,
	});
	$self->_traced('WS close', $conn, sub { $self->on_close($conn, $code, $reason // '') })
	    if $ready;
	$conn->controller(undef);
    });

    $self->_load_session($c)->then(sub ($session) {
	return unless $conn->controller;	# closed meanwhile
	if (!$session && $self->require_session) {
	    $self->logger->info('websocket rejected: no session', $conn->log_fields);
	    return $conn->close(CLOSE_UNAUTHORIZED, 'unauthorized');
	}
	$conn->session($session || {});
	$ready = 1;
	$self->logger->info('websocket opened', $conn->log_fields);
	$self->_traced('WS open', $conn, sub { $self->on_open($conn) });
	$handle->($_) for splice @pending;
    })->catch(sub ($err) {
	$self->logger->error('websocket session lookup failed', { %{$conn->log_fields}, error => "$err" });
	$conn->close(CLOSE_UNAVAILABLE, 'session store unavailable') if $conn->controller;
    });
    return;
}

sub _join ($self, $conn, $room) {
    $conn->rooms->{$room} = 1;
    my $members = $self->rooms->{$room} ||= {};
    my $first = !%$members;
    $members->{$conn->id} = $conn;
    Scalar::Util::weaken($members->{$conn->id});

    my $pubsub = $self->pubsub or return Mojo::Promise->resolve;
    my $channel = $CHANNEL_PREFIX . $room;
    return $self->{_subscribing}{$channel} if $self->{_subscribing}{$channel};
    return Mojo::Promise->resolve unless $first;

    my $p = $self->{_subscribing}{$channel} = Mojo::Promise->new;
    $self->{_listeners}{$room} = $pubsub->listen($channel => sub ($pubsub, $message, $ch) {
	my $envelope = eval { Mojo::JSON::decode_json($message) } or return;
	$self->_deliver($envelope->{room}, $envelope->{data});
    });
    return $p;
}

sub _leave ($self, $conn, $room) {
    delete $conn->rooms->{$room};
    my $members = $self->rooms->{$room} or return;
    delete $members->{$conn->id};
    return if %$members;
    delete $self->rooms->{$room};
    if (my $cb = delete $self->{_listeners}{$room}) {
	$self->pubsub->unlisten($CHANNEL_PREFIX . $room, $cb);
    }
}

sub _deliver ($self, $room, $data) {
    my $members = $self->rooms->{$room} or return;
    $_->send($data) for grep defined, values %$members;
}

sub _ping_all ($self) {
    for my $conn (values %{$self->connections}) {
	my $c = $conn->controller or next;
	$c->tx->send([1, 0, 0, 0, WS_PING, 'ka']);
    }
}

# Same-origin by default; SLEDGE_WS_ALLOWED_ORIGINS lists exact origins otherwise.
# Requests without an Origin header (non-browser clients) are allowed: the check
# exists to stop other web sites from opening sockets with the user's cookies.
sub _origin_allowed ($self, $c) {
    my $origin = $c->req->headers->origin;
    return 1 unless defined $origin && length $origin;
    my @allowed = @{$self->allowed_origins};
    return scalar grep { lc $_ eq lc $origin } @allowed if @allowed;
    my($host) = $origin =~ m{\Ahttps?://([^/]+)\z}i or return 0;
    return lc $host eq lc($c->req->headers->host // '');
}

# Reads the Sledge session (read-only) from the Redis store or the encrypted cookie
sub _load_session ($self, $c) {
    my $config = $self->sledge_config;
    my $value = $c->cookie(Sledge::SessionManager::Cookie::_config($config, 'cookie_name', 'sledge_sid'));
    return Mojo::Promise->resolve(undef) unless defined $value && length $value;

    my $store = $self->session_store;
    if ($store eq 'cookie') {
	require Sledge::SessionManager::EncryptedCookie;
	my $page = bless { config => $config }, 'Sledge::WebSocket::_Page';
	my $payload = Sledge::SessionManager::EncryptedCookie->decrypt($page, $value);
	return Mojo::Promise->resolve($payload ? $payload->{data} : undef);
    }
    if ($store eq 'redis') {
	return Mojo::Promise->resolve(undef) unless $value =~ /\A[0-9a-f]{16,128}\z/;
	require Sledge::Session::Redis;
	no warnings 'once';
	return $self->redis->db->get_p($Sledge::Session::Redis::KeyPrefix . $value)->then(sub ($data) {
	    return defined $data ? Sledge::Session->_deserialize($data) : undef;
	});
    }
    return Mojo::Promise->resolve(undef);
}

# 'redis' or 'cookie' (stores that can be read without blocking the event loop)
sub session_store ($self) {
    my $store = $self->_conf('session_store', 'auto');
    return $store unless $store eq 'auto';
    return 'redis'  if $self->_conf('redis_server');
    return 'cookie' if $self->_conf('session_secret');
    return 'none';
}

# Runs an application callback; exceptions are logged instead of breaking the event loop
sub _traced ($self, $name, $conn, $code) {
    my $ok = eval {
	if ($Sledge::Tracing::Enabled) {
	    Sledge::Tracing->in_span($name, {
		'ws.connection.id' => $conn->id,
		'ws.request_id'    => $conn->request_id,
	    }, $code);
	} else {
	    $code->();
	}
	1;
    };
    unless ($ok) {
	$self->logger->error("unhandled exception in $name", { %{$conn->log_fields}, error => "$@" });
	$conn->send({ type => 'error', error => 'internal error' }) if $name eq 'WS message';
    }
    Sledge::Tracing->flush_if_due if $Sledge::Tracing::Enabled;
    return;
}

sub _conf ($self, $key, $default = undef) {
    return Sledge::SessionManager::Cookie::_config($self->sledge_config, $key, $default);
}

# Send Mojolicious' own log messages through Sledge::Logger (JSON)
sub _bridge_log ($self) {
    my $log = $self->log;
    $log->unsubscribe('message');
    $log->level(lc($ENV{SLEDGE_LOG_LEVEL} || 'info'));
    $log->on(message => sub ($log, $level, @lines) {
	$level = 'debug' if $level eq 'trace';
	Sledge::Logger->default->log($level => join("\n", @lines), { source => 'mojolicious' });
    });
}

package Sledge::WebSocket::_Page;
sub create_config { $_[0]{config} }

1;
__END__

=head1 NAME

Sledge::WebSocket - WebSocket server that shares Sledge sessions, logging and tracing

=head1 SYNOPSIS

  package MyChat;
  use Mojo::Base 'Sledge::WebSocket', -signatures;
  use MyApp::Config;

  sub sledge_config ($self) { MyApp::Config->instance }

  sub on_open ($self, $conn) {
      $conn->join('lobby');
  }

  sub on_message ($self, $conn, $data) {
      $self->broadcast(lobby => { user => $conn->session->{name}, text => $data->{text} });
  }

  # bin/chat
  MyChat->new->run_server(port => 5001);

=head1 DESCRIPTION

Sledge pages run on a prefork server such as Starlet, where one connection
occupies one worker. Long-lived WebSocket connections would exhaust the
workers, so they are served by this separate event-loop process (built on
L<Mojolicious>), typically routed by the Ingress as C</ws>.

=over 4

=item Sessions

After the handshake, the Sledge session is read from the session cookie, from
either L<Sledge::Session::Redis> or L<Sledge::SessionManager::EncryptedCookie>.
Without a session the connection is closed with code 4401 (unless
C<WS_REQUIRE_SESSION> is 0); if the store cannot be reached, with 1011.
C<on_open> is called only after the session has been loaded, and messages that
arrive before that are buffered. The session is read-only.

=item Origin check

Browsers send cookies with cross-site WebSocket requests, so the C<Origin>
header must match the C<Host> header, or one of C<WS_ALLOWED_ORIGINS>.
Otherwise the handshake fails with 403.

=item Rooms and pub/sub

C<< $conn->join($room) >> and C<< $app->broadcast($room, $data) >>. When
C<REDIS_SERVER> is set, messages go through Redis / Valkey pub/sub and reach
clients connected to every pod; otherwise they stay within the process.

=item Messages

Clients send JSON text frames; C<on_message> receives the decoded data.
Frames larger than C<WS_MAX_MESSAGE_SIZE> close the connection with 1009, and
clients sending more than C<WS_RATE_LIMIT> messages per second are closed with 1008.

=item Keepalive

The server pings every client every C<WS_PING_INTERVAL> seconds, and closes
connections idle for C<WS_IDLE_TIMEOUT> seconds.

=item Shutdown

On SIGTERM, C</readyz> starts returning 503, new connections are refused, and
every client is closed with 1001 (going away) so that it reconnects to another
pod. The process exits once the clients are gone or after C<WS_CLOSE_TIMEOUT> seconds.

=item Observability

Logs go through L<Sledge::Logger> as JSON. When L<Sledge::Tracing> is set up,
opening, closing and every message create a span.

=back

Configuration keys are read through C<sledge_config> (for example
C<SLEDGE_WS_ALLOWED_ORIGINS> with L<Sledge::Config::Env>):
C<WS_PATH> (default C</ws>), C<WS_REQUIRE_SESSION> (1), C<WS_PING_INTERVAL> (25),
C<WS_IDLE_TIMEOUT> (60), C<WS_MAX_MESSAGE_SIZE> (65536), C<WS_RATE_LIMIT> (20),
C<WS_CLOSE_TIMEOUT> (5), C<WS_ALLOWED_ORIGINS>, C<REDIS_SERVER>, C<REDIS_PASSWORD>,
C<SESSION_STORE>, C<SESSION_SECRET>, C<COOKIE_NAME>.

=cut
