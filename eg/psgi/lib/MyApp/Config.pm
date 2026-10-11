package MyApp::Config;
use strict;
use base qw(Sledge::Config::Env Class::Singleton);

use File::Basename ();
use File::Spec;

my $root = File::Spec->rel2abs(File::Basename::dirname(__FILE__) . '/../..');

# Can be overridden with SLEDGE_XXX environment variables (ConfigMap / Secret)
__PACKAGE__->env_prefix('SLEDGE_');
__PACKAGE__->defaults({
    TMPL_PATH     => "$root/tmpl",
    COOKIE_NAME   => 'sledge_sid',
    COOKIE_PATH   => '/',
    COOKIE_DOMAIN => undef,
    DATASOURCE    => undef,
    SESSION_STORE => 'auto',	# auto / redis / dbi / cookie / none
});

sub _new_instance {
    my $class = shift;
    $class->new($ENV{SLEDGE_CONFIG_NAME});
}

1;
