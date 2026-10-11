package Sledge::SessionManager::Cookie;
# $Id: Cookie.pm,v 1.1.1.1 2003/02/13 06:59:36 miyagawa Exp $
#
# Tatsuhiko Miyagawa <miyagawa@edge.co.jp>
# Livin' On The EDGE, Co., Ltd..
#

use strict;
use base qw(Sledge::SessionManager);
use CGI::Cookie;

sub get_session_id {
    my($self, $page) = @_;
    my $config = $page->create_config;
    my %jar    = CGI::Cookie->fetch;
    my $cookie = $jar{$config->cookie_name};
    return $cookie ? $cookie->value : undef;
}

sub set_session_id {
    my($self, $page, $sid) = @_;
    my $cookie = CGI::Cookie->new($self->cookie_options($page, -value => $sid));
    $page->r->header_out('Set-Cookie' => $cookie->as_string);
}

# Options passed to CGI::Cookie->new. Configuration keys:
#   COOKIE_NAME, COOKIE_PATH, COOKIE_DOMAIN
#   COOKIE_SECURE   : 1/0. If unset, Secure is added only over HTTPS
#   COOKIE_HTTPONLY : default 1
#   COOKIE_SAMESITE : Strict / Lax / None. Default Lax
sub cookie_options {
    my($self, $page, %extra) = @_;
    my $config = $page->create_config;

    my %options = (
	-name     => $config->cookie_name,
	-path     => $config->cookie_path,
	-httponly => _config($config, 'cookie_httponly', 1) ? 1 : 0,
	%extra,
    );
    my $domain = _config($config, 'cookie_domain');
    $options{-domain} = $domain if $domain;

    my $secure = _config($config, 'cookie_secure');
    $secure = $ENV{HTTPS} && $ENV{HTTPS} ne 'off' unless defined $secure && length $secure;
    $options{-secure} = 1 if $secure;

    my $samesite = _config($config, 'cookie_samesite', 'Lax');
    $options{-samesite} = $samesite if $samesite;
    return %options;
}

# A strict_param Sledge::Config croaks on unknown keys, so wrap the call in eval
sub _config {
    my($config, $key, $default) = @_;
    my $value = eval { $config->$key() };
    return defined $value ? $value : $default;
}

1;
