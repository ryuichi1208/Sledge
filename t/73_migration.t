use strict;
use warnings;
use Test::More;
use DBI;
use File::Temp qw(tempdir);
use Sledge::Migration;

my @targets = ([ 'SQLite', 'dbi:SQLite:dbname=' . tempdir(CLEANUP => 1) . '/m.db', '', '' ]);
push @targets, [ 'mysql', $ENV{SLEDGE_TEST_MYSQL_DSN}, $ENV{SLEDGE_TEST_MYSQL_USER}, $ENV{SLEDGE_TEST_MYSQL_PASSWORD} ]
    if $ENV{SLEDGE_TEST_MYSQL_DSN};
push @targets, [ 'Pg', $ENV{SLEDGE_TEST_PG_DSN}, $ENV{SLEDGE_TEST_PG_USER}, $ENV{SLEDGE_TEST_PG_PASSWORD} ]
    if $ENV{SLEDGE_TEST_PG_DSN};

sub write_file { my($path, $body) = @_; open my $fh, '>', $path or die $!; print $fh $body }

for my $target (@targets) {
    my($driver, @dsn) = @$target;
    subtest $driver => sub {
	my $dir = tempdir(CLEANUP => 1);
	my $table = "mig_test_$$";
	write_file("$dir/001_create.sql", "CREATE TABLE ${table}_a (id INTEGER PRIMARY KEY);\n");
	write_file("$dir/002_generic.sql", "CREATE TABLE ${table}_wrong (id INTEGER);\n");
	write_file("$dir/002_generic.$driver.sql",
		   "CREATE TABLE ${table}_b (id INTEGER);\nINSERT INTO ${table}_b VALUES (1);\n");
	write_file("$dir/002_generic.Other.sql", "THIS IS NOT SQL;\n");
	write_file("$dir/README", "ignored\n");

	my $dbh = DBI->connect(@dsn, { RaiseError => 1, PrintError => 0, AutoCommit => 1 });
	$dbh->do('SET client_min_messages = warning') if $driver eq 'Pg';
	my $cleanup = sub {
	    $dbh->do("DROP TABLE IF EXISTS $_") for "${table}_a", "${table}_b", "${table}_c", "${table}_wrong", "${table}_v";
	};
	$cleanup->();
	my $m = Sledge::Migration->new(dbh => $dbh, dir => $dir, table => "${table}_v");

	is_deeply [ map { "$_->{version}:" . File::Basename::basename($_->{file}) } $m->migrations ],
		  [ '001:001_create.sql', "002:002_generic.$driver.sql" ], 'driver-specific file wins';
	is_deeply [ map { $_->{version} } $m->pending ], [ '001', '002' ], 'all pending';

	my @applied = $m->migrate;
	is scalar @applied, 2, 'applied two';
	is $dbh->selectrow_array("SELECT COUNT(*) FROM ${table}_b"), 1, 'multi-statement file ran';
	ok !eval { $dbh->do("SELECT 1 FROM ${table}_wrong"); 1 }, 'generic file was skipped';
	is scalar($m->migrate), 0, 'second run applies nothing';
	is_deeply [ map { $_->{applied} } $m->status ], [ 1, 1 ], 'status';

	# A failing migration is reported and not recorded
	write_file("$dir/003_broken.sql", "CREATE TABLE ${table}_c (id INTEGER);\nTHIS IS NOT SQL;\n");
	eval { $m->migrate };
	like $@, qr/migration 003_broken failed/, 'failure names the file';
	is_deeply [ map { $_->{version} } $m->pending ], [ '003' ], 'failed migration stays pending';
	if ($driver ne 'mysql') {
	    ok !eval { $dbh->do("SELECT 1 FROM ${table}_c"); 1 }, 'failed migration was rolled back';
	}
	unlink "$dir/003_broken.sql";
	$dbh->do("DROP TABLE IF EXISTS ${table}_c");

	# Concurrent runs (e.g. init containers of several pods) apply each migration once
	if ($driver ne 'SQLite') {
	    write_file("$dir/004_slow.sql", "CREATE TABLE ${table}_c (id INTEGER);\n");
	    my @pids;
	    for (1 .. 3) {
		my $pid = fork // die;
		if (!$pid) {
		    my $dbh = DBI->connect(@dsn, { RaiseError => 1, PrintError => 0, AutoCommit => 1 });
		    my $ok = eval { Sledge::Migration->new(dbh => $dbh, dir => $dir, table => "${table}_v")->migrate; 1 };
		    POSIX::_exit($ok ? 0 : 1);
		}
		push @pids, $pid;
	    }
	    my @status = map { waitpid($_, 0); $? >> 8 } @pids;
	    is_deeply \@status, [ 0, 0, 0 ], 'concurrent runs all succeed';
	    is $dbh->selectrow_array("SELECT COUNT(*) FROM ${table}_v WHERE version = '004'"), 1, 'recorded once';
	}

	$cleanup->();
	$dbh->do("DROP TABLE IF EXISTS ${table}_c");
    };
}

done_testing;

use File::Basename ();
use POSIX ();
