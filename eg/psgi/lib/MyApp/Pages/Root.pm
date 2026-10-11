package MyApp::Pages::Root;
use strict;
use base qw(MyApp::Pages);

__PACKAGE__->tmpl_dirname('root');

sub dispatch_index {
    my $self = shift;
    my $count = ($self->session->param('count') || 0) + 1;
    $self->session->param(count => $count);
    $self->logger->info('visited', { count => $count });
    $self->tmpl->param(
	count => $count,
	name  => scalar $self->r->param('name'),
    );
}

1;
