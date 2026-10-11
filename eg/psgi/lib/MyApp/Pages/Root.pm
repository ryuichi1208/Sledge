package MyApp::Pages::Root;
use strict;
use base qw(MyApp::Pages);

__PACKAGE__->tmpl_dirname('root');

sub dispatch_index {
    my $self = shift;
    my $count = ($self->session->param('count') || 0) + 1;
    $self->session->param(count => $count);

    # Remember the name in the session; the chat (eg/websocket) reads it from there
    my $name = $self->r->param('name');
    if (defined $name && $name =~ /\S/) {
	$name =~ s/^\s+|\s+$//g;
	$self->session->param(name => substr($name, 0, 32));
    }

    $self->logger->info('visited', { count => $count });
    $self->tmpl->param(
	count => $count,
	name  => $self->session->param('name'),
    );
}

sub dispatch_chat {
    my $self = shift;
    return $self->redirect('/') unless $self->session->param('name');
    $self->tmpl->param(name => $self->session->param('name'));
}

1;
