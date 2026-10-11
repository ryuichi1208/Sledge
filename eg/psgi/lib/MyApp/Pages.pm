package MyApp::Pages;
use strict;
use base qw(Sledge::Pages::PSGI);

use Sledge::Authorizer::Null;
use Sledge::Charset::UTF8;
use Sledge::SessionManager::Cookie;
use Sledge::SessionManager::EncryptedCookie;
use Sledge::SessionManager::Null;
use Sledge::Session::DBIFactory;
use Sledge::Template::TT;

use MyApp::Config;

# Templates are written in UTF-8
__PACKAGE__->register_hook(BEFORE_DISPATCH => sub {
    my $self = shift;
    $self->tmpl->set_option(ENCODING => 'UTF-8');
});

sub create_authorizer {
    my $self = shift;
    return Sledge::Authorizer::Null->new($self);
}

sub create_charset {
    my $self = shift;
    return Sledge::Charset::UTF8->new($self);
}

sub create_config {
    my $self = shift;
    return MyApp::Config->instance;
}

# Where sessions are stored (SLEDGE_SESSION_STORE)
#   redis  : Redis / Valkey at SLEDGE_REDIS_SERVER
#   dbi    : MySQL / PostgreSQL / SQLite at SLEDGE_DSN
#   cookie : encrypted cookie (requires SLEDGE_SESSION_SECRET)
#   none   : request scope only
#   auto   : the first of the above that is configured (default)
sub session_store {
    my $self = shift;
    my $config = $self->create_config;
    my $store = $config->session_store;
    return $store unless $store eq 'auto';
    return 'redis'  if Sledge::SessionManager::Cookie::_config($config, 'redis_server');
    return 'dbi'    if $config->datasource;
    return 'cookie' if Sledge::SessionManager::Cookie::_config($config, 'session_secret');
    return 'none';
}

sub create_manager {
    my $self = shift;
    my $store = $self->session_store;
    return Sledge::SessionManager::EncryptedCookie->new($self) if $store eq 'cookie';
    return Sledge::SessionManager::Null->new($self)            if $store eq 'none';
    return Sledge::SessionManager::Cookie->new($self);
}

sub create_session {
    my($self, $sid) = @_;
    if ($self->session_store eq 'redis') {
	require Sledge::Session::Redis;
	return Sledge::Session::Redis->new($self, $sid);
    }
    return Sledge::Session::DBIFactory->new($self, $sid);
}

1;
