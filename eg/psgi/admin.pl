#!/usr/bin/env perl
# One-off admin tasks for the sample app. They run with the same code, image
# and configuration (environment variables) as the app itself.
#
#   perl eg/psgi/admin.pl migrate                 # apply pending migrations
#   perl eg/psgi/admin.pl migrate-status          # list migrations
#   perl eg/psgi/admin.pl session-cleanup [MIN]   # delete sessions idle for MIN minutes (default 1440)
#   perl eg/psgi/admin.pl config-check            # load the configuration and reach backing services
#
# On Kubernetes: kubectl exec deploy/sledge -- perl eg/psgi/admin.pl migrate-status
use strict;
use warnings;
use File::Basename ();
use File::Spec;
use lib File::Spec->catdir(File::Basename::dirname(__FILE__), 'lib');

use DBI;
use Sledge::Logger;
use MyApp::Config;

my $dir = File::Basename::dirname(__FILE__);
my $log = Sledge::Logger->default;
my %commands = (
    'migrate'         => \&migrate,
    'migrate-status'  => \&migrate_status,
    'session-cleanup' => \&session_cleanup,
    'config-check'    => \&config_check,
);

my $command = shift @ARGV // '';
my $code = $commands{$command} or die "usage: $0 " . join('|', sort keys %commands) . "\n";
my $ok = eval { $code->(@ARGV); 1 };
unless ($ok) {
    $log->error("$command failed", { error => "$@" });
    exit 1;
}
exit 0;

sub config { MyApp::Config->instance }

sub dbh {
    my @dsn = config()->datasource;
    return unless $dsn[0];
    return DBI->connect(@dsn, { RaiseError => 1, PrintError => 0, AutoCommit => 1 });
}

sub migration {
    my $dbh = dbh() or return;
    require Sledge::Migration;
    return Sledge::Migration->new(
	dbh => $dbh, dir => File::Spec->catdir($dir, 'migrations'), logger => $log,
    );
}

sub migrate {
    my $m = migration() or return $log->info('migrate: no DATASOURCE configured, nothing to do');
    my @applied = $m->migrate;
    $log->info('migrate: done', { applied => scalar @applied, driver => $m->driver });
}

sub migrate_status {
    my $m = migration() or return $log->info('migrate-status: no DATASOURCE configured');
    printf "%-6s %-8s %s\n", $_->{version}, ($_->{applied} ? 'applied' : 'pending'), $_->{name}
	for $m->status;
}

# Redis / Valkey sessions expire by TTL and cookie sessions by their own
# expiry, so only the RDB stores need this (e.g. from a CronJob).
sub session_cleanup {
    my $minutes = shift // 1440;
    die "minutes must be a number\n" unless $minutes =~ /\A\d+\z/;
    my $page = bless {}, 'MyApp::Pages';
    my $store = $page->session_store;
    return $log->info('session-cleanup: nothing to do', { store => $store }) unless $store eq 'dbi';

    my($driver) = (config()->datasource)[0] =~ /^dbi:(\w+)/i;
    my $class = $Sledge::Session::DBIFactory::DriverBindMap->{$driver}
	or die "no session class for driver $driver\n";
    (my $file = "$class.pm") =~ s{::}{/}g;
    require $file;
    $class->cleanup($page, $minutes);
    $log->info('session-cleanup: done', { store => $store, driver => $driver, minutes => $minutes + 0 });
}

sub config_check {
    my $config = config();	# fails here when a required key is missing
    my %result = (session_store => MyApp::Pages->can('session_store')->(bless {}, 'MyApp::Pages'));
    if (my $dbh = dbh()) {
	$result{database} = $dbh->ping ? 'ok' : 'unreachable';
    }
    if (my $server = eval { $config->redis_server }) {
	require Redis::Fast;
	my $redis = Redis::Fast->new(server => $server, cnx_timeout => 2, reconnect => 0,
	    (eval { $config->redis_password } ? (password => $config->redis_password) : ()));
	$result{redis} = $redis->ping eq 'PONG' ? 'ok' : 'unreachable';
    }
    $log->info('config-check: ok', \%result);
}

BEGIN { require MyApp::Pages; require Sledge::Session::DBIFactory }
