package MyChat;
#
# Sample chat server. The user name comes from the Sledge session that the
# sample Sledge app (eg/psgi) stores when the user enters a name.
#
use Mojo::Base 'Sledge::WebSocket', -signatures;

use MyApp::Config;

my $ROOM = 'lobby';

sub sledge_config ($self) { MyApp::Config->instance }

sub user ($self, $conn) { $conn->session->{name} // 'anonymous' }

sub on_open ($self, $conn) {
    my $user = $self->user($conn);
    $conn->join($ROOM)->then(sub {
	$conn->send({ type => 'welcome', user => $user });
	$self->broadcast($ROOM => { type => 'join', user => $user });
    });
}

sub on_message ($self, $conn, $data) {
    return $conn->send({ type => 'error', error => 'unknown message type' })
	unless ($data->{type} // '') eq 'say';
    my $text = $data->{text} // '';
    $text =~ s/^\s+|\s+$//g;
    return unless length $text;
    return $conn->send({ type => 'error', error => 'message too long' }) if length $text > 500;

    $self->logger->info('chat message', { %{$conn->log_fields}, length => length $text });
    $self->broadcast($ROOM => {
	type => 'say', user => $self->user($conn), text => $text, at => time,
    });
}

sub on_close ($self, $conn, $code, $reason) {
    $self->broadcast($ROOM => { type => 'leave', user => $self->user($conn) });
}

1;
