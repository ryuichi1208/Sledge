package Sledge::Session::Redis;
#
# Stores sessions in Redis / Valkey.
# Expiry is handled with a TTL, so no batch job is needed to delete old sessions.
#

use strict;
use base qw(Sledge::Session);

use Crypt::URandom ();
use Redis::Fast;
use Time::HiRes ();
use Sledge::Exceptions;
use Sledge::SessionManager::Cookie;

use vars qw($KeyPrefix $UseLock $LockTimeout $LockWait);
$KeyPrefix   = 'sledge:session:';
$UseLock     = 1;		# serialize concurrent requests for the same session
$LockTimeout = 30;		# lock auto-release (seconds), so a crashed worker cannot leave it behind
$LockWait    = 10;		# maximum seconds to wait for the lock

my %Connection;			# per-process connection cache

sub _connect_database {
    my($self, $page) = @_;
    my $config = $page->create_config;
    my $server = _config($config, 'redis_server', '127.0.0.1:6379');
    my $password = _config($config, 'redis_password');

    # Do not reuse the parent's connection in prefork child processes
    my $key = join "\0", $$, $server;
    my $redis = $Connection{$key};
    unless ($redis) {
	%Connection = map { $_ => $Connection{$_} } grep /^$$\0/, keys %Connection;
	$redis = eval {
	    Redis::Fast->new(
		server    => $server,
		reconnect => 2,
		every     => 100_000,
		cnx_timeout   => 1,
		read_timeout  => 2,
		write_timeout => 2,
		(defined $password && length $password ? (password => $password) : ()),
	    );
	} or Sledge::Exception::DBConnectionError->throw("Redis connect failed: $@");
	$Connection{$key} = $redis;
    }

    $self->{_ttl} = _config($config, 'session_ttl', 86400) if ref $self;
    return $Sledge::Tracing::Enabled
	? Sledge::Session::Redis::TracedClient->new($redis, $server)
	: $redis;
}

sub _key { $KeyPrefix . shift->{_sid} }

sub _commit { }

sub _select_me {
    my $self = shift;
    my $data = $self->{_dbh}->get($self->_key);
    unless (defined $data) {
	$self->_unlock;
	Sledge::Exception::SessionIdNotFound->throw('no such session_id in redis.');
    }
    $self->{_data} = $self->_deserialize($data);
}

sub _insert_me {
    my $self = shift;
    $self->{_dbh}->set($self->_key, $self->_serialize($self->{_data}), 'EX', $self->{_ttl});
}

sub _update_me { shift->_insert_me }

sub _delete_me {
    my $self = shift;
    $self->{_dbh}->del($self->_key);
}

sub _lockid {
    my $self = shift;
    return $self->_key . ':lock';
}

sub _do_lock {
    my $self = shift;
    return unless $UseLock;

    my $token = unpack 'H*', Crypt::URandom::urandom(16);
    my $deadline = Time::HiRes::time() + $LockWait;
    while (1) {
	last if $self->{_dbh}->set($self->_lockid, $token, 'NX', 'EX', $LockTimeout);
	if (Time::HiRes::time() > $deadline) {
	    Sledge::Exception::DBConnectionError->throw('timed out waiting for session lock');
	}
	Time::HiRes::sleep(0.05);
    }

    $self->{_lock} = sub {
	my $self = shift;
	# Delete the lock only if we still own it
	$self->{_dbh}->eval(
	    q{if redis.call('get', KEYS[1]) == ARGV[1] then return redis.call('del', KEYS[1]) end return 0},
	    1, $self->_lockid, $token,
	);
    };
}

sub _unlock {
    my $self = shift;
    my $lock = delete $self->{_lock} or return;
    $lock->($self);
}

sub _do_cleanup { }		# not needed; keys expire via TTL

*_config = \&Sledge::SessionManager::Cookie::_config;

# When OpenTelemetry is enabled, create a CLIENT span for each Redis command.
# Keys contain the session ID, so they are not recorded as attributes.
package Sledge::Session::Redis::TracedClient;
use vars qw($AUTOLOAD);
use Sledge::Tracing;

sub new {
    my($class, $redis, $server) = @_;
    my($host, $port) = split /:/, $server, 2;
    bless { redis => $redis, host => $host, port => $port }, $class;
}

sub AUTOLOAD {
    my $self = shift;
    (my $command = $AUTOLOAD) =~ s/.*:://;
    my @args = @_;
    require OpenTelemetry::Constants;
    return Sledge::Tracing->tracer->in_span(
	uc $command,
	kind       => OpenTelemetry::Constants::SPAN_KIND_CLIENT(),
	attributes => {
	    'db.system.name'    => 'redis',
	    'db.operation.name' => uc $command,
	    'server.address'    => $self->{host},
	    ($self->{port} ? ('server.port' => $self->{port} + 0) : ()),
	},
	sub { $self->{redis}->$command(@args) },
    );
}

sub DESTROY { }

1;
__END__

=head1 NAME

Sledge::Session::Redis - Redis / Valkey session store

=head1 SYNOPSIS

  package MyProj::Pages;
  use Sledge::Session::Redis;

  sub create_session {
      my($self, $sid) = @_;
      return Sledge::Session::Redis->new($self, $sid);
  }

=head1 DESCRIPTION

Configuration keys:

=over 4

=item REDIS_SERVER

C<host:port>. Default C<127.0.0.1:6379>.

=item REDIS_PASSWORD

=item SESSION_TTL

Lifetime in seconds. Default 86400. Extended on every access.

=back

When C<$Sledge::Session::Redis::UseLock> is true (the default), concurrent access to the same session
is serialized with a lock taken with C<SET NX>.

=cut
