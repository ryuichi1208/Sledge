package Sledge::Config::Env;
#
# A Sledge::Config that reads its settings from environment variables,
# so Kubernetes ConfigMaps / Secrets can be used directly as configuration.
#

use strict;
use base qw(Sledge::Config Class::Data::Inheritable);

use Carp ();
use Sledge::Exceptions;

__PACKAGE__->mk_classdata(env_prefix => 'SLEDGE_');
__PACKAGE__->mk_classdata(defaults   => {});
__PACKAGE__->mk_classdata(required   => []);

sub case_sensitive { 0 }

sub new {
    my($class, $configname) = @_;

    # Also load existing modules such as Config::_common, if present
    my $self = $class->SUPER::new($configname);

    my $defaults = $class->defaults;
    for my $key (keys %$defaults) {
	$self->{lc $key} = $defaults->{$key} unless exists $self->{lc $key};
    }

    my %env = $class->_read_env;
    $self->{$_} = $env{$_} for keys %env;

    # Build DATASOURCE from DSN / DB_USER / DB_PASSWORD
    if (defined $self->{dsn} && length $self->{dsn} && !defined $self->{datasource}) {
	$self->{datasource} = [ @{$self}{qw(dsn db_user db_password)} ];
    }

    my $prefix = $class->env_prefix;
    my @missing = grep { !defined $self->{lc $_} || !length $self->{lc $_} } @{$class->required};
    if (@missing) {
	Sledge::Exception::ConfigMissing->throw(
	    'missing required configuration: '
	    . join(', ', map { "$prefix\U$_\E (or $prefix\U$_\E_FILE)" } @missing),
	);
    }
    return $self;
}

# PREFIX_FOO=bar      => foo => 'bar'
# PREFIX_FOO_FILE=/x  => foo => contents of /x (for Secrets mounted as files)
sub _read_env {
    my $class = shift;
    my $prefix = $class->env_prefix;
    my(%value, %file);
    for my $name (keys %ENV) {
	next unless $name =~ /^\Q$prefix\E(.+)$/;
	my $key = lc $1;
	if ($key =~ s/_file$//) {
	    $file{$key} = $ENV{$name};
	} else {
	    $value{$key} = $ENV{$name};
	}
    }
    for my $key (keys %file) {
	next if exists $value{$key};	# a value set directly takes precedence
	open my $fh, '<', $file{$key}
	    or Sledge::Exception::ConfigMissing->throw("cannot read $prefix\U$key\E_FILE ($file{$key}): $!");
	local $/;
	(my $content = <$fh>) =~ s/\r?\n\z//;
	$value{$key} = $content;
    }
    return %value;
}

1;
__END__

=head1 NAME

Sledge::Config::Env - read Sledge configuration from environment variables

=head1 SYNOPSIS

  package MyApp::Config;
  use base qw(Sledge::Config::Env Class::Singleton);

  __PACKAGE__->env_prefix('MYAPP_');
  __PACKAGE__->defaults({
      TMPL_PATH   => '/app/tmpl',
      COOKIE_NAME => 'myapp_sid',
      COOKIE_PATH => '/',
  });
  __PACKAGE__->required([qw(SESSION_SECRET)]);

  sub _new_instance { shift->new($ENV{SLEDGE_CONFIG_NAME}) }

=head1 DESCRIPTION

Environment variables starting with C<env_prefix> are read as keys, with the prefix removed and lowercased
(C<MYAPP_TMPL_PATH> becomes C<< $config->tmpl_path >>).

=over 4

=item *

If C<MYAPP_FOO_FILE> is set, the contents of that file become the value of C<foo>.
Use this when a Kubernetes Secret is mounted as a volume.
If both C<MYAPP_FOO> and C<MYAPP_FOO_FILE> are set, C<MYAPP_FOO> wins.

=item *

If C<DSN>, C<DB_USER> and C<DB_PASSWORD> are set, C<DATASOURCE> is built from them.

=item *

If a key listed in C<required> is missing, the constructor throws L<Sledge::Exception::ConfigMissing>,
so missing configuration is detected right at startup.

=back

Precedence: environment variables > configuration modules (C<Config::_common> etc.) > C<defaults>.

=cut
