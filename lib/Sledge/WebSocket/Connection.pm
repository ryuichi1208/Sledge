package Sledge::WebSocket::Connection;
#
# One WebSocket client connection handled by Sledge::WebSocket.
#

use Mojo::Base -base, -signatures;
use Mojo::JSON ();
use Mojo::IOLoop;
use Mojo::Promise;
use Scalar::Util ();
use Time::HiRes ();

has [qw(app controller id session request_id remote_addr)];
has rooms     => sub { {} };
has 'opened_at';
has stash     => sub { {} };	# free space for the application

sub new ($class, @args) {
    my $self = $class->SUPER::new(@args);
    $self->opened_at(Time::HiRes::time()) unless defined $self->opened_at;
    return $self;
}

# Send a data structure to this client as a JSON text frame
sub send ($self, $data) {
    my $frame = { text => Mojo::JSON::encode_json($data) };
    $self->_when_established(sub ($c) { $c->send($frame) });
    return $self;
}

# Join a room. Returns a promise that resolves once messages for the room
# can be received (i.e. after the pub/sub subscription is confirmed).
sub join ($self, $room) {
    return $self->app->_join($self, $room);
}

sub leave ($self, $room) {
    $self->app->_leave($self, $room);
    return $self;
}

sub close ($self, $code = 1000, $reason = '') {
    $self->_when_established(sub ($c) { $c->finish($code, $reason) });
    return $self;
}

# Mojolicious answers the handshake once the action returns, but the socket is
# only established after the 101 response has been written. Calling send() or
# finish() in between makes Mojolicious render the handshake a second time and
# drops the connection, so queue the calls until the socket is established
# (which happens right after the handshake transaction finishes).
sub _when_established ($self, $cb) {
    my $c = $self->controller or return;
    my $tx = $c->tx or return;
    return $cb->($c) if $tx->established;
    push @{$self->{_queue}}, $cb;
    return if $self->{_waiting}++;
    Scalar::Util::weaken(my $weak = $self);
    $tx->handshake->once(finish => sub {
	Mojo::IOLoop->next_tick(sub {
	    return unless $weak;
	    my $c = $weak->controller or return;
	    $_->($c) for splice @{$weak->{_queue}};
	});
    });
}

# Fields added to every log line about this connection
sub log_fields ($self) {
    return {
	connection_id => $self->id,
	(defined $self->request_id  ? (request_id  => $self->request_id)  : ()),
	(defined $self->remote_addr ? (remote_addr => $self->remote_addr) : ()),
    };
}

1;
__END__

=head1 NAME

Sledge::WebSocket::Connection - a WebSocket client connection

=head1 METHODS

=over 4

=item id

Unique connection ID.

=item session

The Sledge session data (a hash reference) of the user, read-only.
Changes are not written back to the session store.

=item send($data)

Sends C<$data> to this client as JSON.

=item join($room) / leave($room)

Joins / leaves a room. C<join> returns a L<Mojo::Promise>.

=item close($code, $reason)

Closes the connection.

=item stash

A hash reference the application can use to keep per-connection state.

=back

=cut
