package Sledge::Migration;
#
# Applies SQL migration files in order and records them in schema_migrations.
# Safe to run from several processes at once (e.g. one init container per
# pod): a database lock serializes the runs, so each migration is applied once.
#

use strict;
use File::Basename ();
use File::Spec;
use POSIX ();

use Sledge::Exceptions;

my $LOCK_NAME = 'sledge-migrate';

sub new {
    my($class, %args) = @_;
    my $self = bless {
	dbh    => $args{dbh} || die("dbh is required\n"),
	dir    => $args{dir} || die("dir is required\n"),
	table  => $args{table} || 'schema_migrations',
	logger => $args{logger},
    }, $class;
    $self->{dbh}->{RaiseError} = 1;
    $self->{dbh}->{PrintError} = 0;
    # PostgreSQL reports "already exists, skipping" as NOTICE; keep logs clean
    $self->{dbh}->do('SET client_min_messages = warning') if $self->driver eq 'Pg';
    return $self;
}

sub driver { shift->{dbh}->{Driver}->{Name} }

# Migration files: NNN_description.sql, or NNN_description.<driver>.sql
# (mysql / Pg / SQLite) for driver-specific SQL. A driver-specific file wins
# over a generic one with the same version.
sub migrations {
    my $self = shift;
    my $driver = $self->driver;
    my %by_version;
    opendir my $dh, $self->{dir} or die "cannot open $self->{dir}: $!\n";
    for my $file (sort readdir $dh) {
	my($version, $name, $for) = $file =~ /\A(\d+)_(\w+?)(?:\.(\w+))?\.sql\z/ or next;
	next if defined $for && $for ne $driver;
	next if $by_version{$version} && !defined $for;	# keep the driver-specific one
	$by_version{$version} = {
	    version => $version,
	    name    => $name,
	    file    => File::Spec->catfile($self->{dir}, $file),
	};
    }
    return map { $by_version{$_} } sort { $a <=> $b } keys %by_version;
}

sub applied {
    my $self = shift;
    $self->_ensure_table;
    my $rows = $self->{dbh}->selectcol_arrayref("SELECT version FROM $self->{table}");
    return { map { $_ => 1 } @$rows };
}

sub pending {
    my $self = shift;
    my $applied = $self->applied;
    return grep { !$applied->{$_->{version}} } $self->migrations;
}

sub status {
    my $self = shift;
    my $applied = $self->applied;
    return map { +{ %$_, applied => $applied->{$_->{version}} ? 1 : 0 } } $self->migrations;
}

# Applies every pending migration. Returns the list of applied migrations.
sub migrate {
    my($self, %opt) = @_;
    my $dbh = $self->{dbh};
    $self->_ensure_table;
    $self->_lock;
    my @done;
    my $ok = eval {
	for my $m ($self->pending) {	# re-read after taking the lock
	    $self->_log(info => 'applying migration', { version => $m->{version}, name => $m->{name} });
	    next if $opt{dry_run};
	    $self->_apply($m);
	    push @done, $m;
	}
	1;
    };
    my $error = $@;
    $self->_unlock;
    die $error unless $ok;
    return @done;
}

sub _apply {
    my($self, $m) = @_;
    my $dbh = $self->{dbh};
    my $sql = do { local(@ARGV, $/) = $m->{file}; <> };
    my @statements = grep { /\S/ } split /;[ \t]*(?:\r?\n|\z)/, $sql;

    # PostgreSQL and SQLite run DDL in a transaction; MySQL commits each DDL
    # statement implicitly, so keep MySQL migrations to one change per file.
    local $dbh->{AutoCommit} = 0 if $self->driver ne 'mysql';
    my $ok = eval {
	$dbh->do($_) for @statements;
	$dbh->do("INSERT INTO $self->{table} (version, name, applied_at) VALUES (?, ?, ?)",
		 undef, $m->{version}, $m->{name}, POSIX::strftime('%Y-%m-%dT%H:%M:%SZ', gmtime));
	$dbh->commit unless $dbh->{AutoCommit};
	1;
    };
    unless ($ok) {
	my $error = $@;
	eval { $dbh->rollback } unless $dbh->{AutoCommit};
	die "migration $m->{version}_$m->{name} failed: $error";
    }
}

sub _ensure_table {
    my $self = shift;
    return if $self->{_table_ok}++;
    $self->{dbh}->do(<<SQL);
CREATE TABLE IF NOT EXISTS $self->{table} (
    version    VARCHAR(32)  NOT NULL PRIMARY KEY,
    name       VARCHAR(255) NOT NULL,
    applied_at VARCHAR(32)  NOT NULL
)
SQL
}

sub _lock {
    my $self = shift;
    my $dbh = $self->{dbh};
    my $driver = $self->driver;
    if ($driver eq 'mysql') {
	my($got) = $dbh->selectrow_array('SELECT GET_LOCK(?, 300)', undef, $LOCK_NAME);
	die "timed out waiting for the migration lock\n" unless $got;
    } elsif ($driver eq 'Pg') {
	$dbh->do('SELECT pg_advisory_lock(hashtext(?))', undef, $LOCK_NAME);
    }
    # SQLite: a single file; each migration runs in its own exclusive transaction
}

sub _unlock {
    my $self = shift;
    my $dbh = $self->{dbh};
    my $driver = $self->driver;
    eval {
	if ($driver eq 'mysql') {
	    $dbh->do('SELECT RELEASE_LOCK(?)', undef, $LOCK_NAME);
	} elsif ($driver eq 'Pg') {
	    $dbh->do('SELECT pg_advisory_unlock(hashtext(?))', undef, $LOCK_NAME);
	}
    };
}

sub _log {
    my($self, $level, $msg, $fields) = @_;
    $self->{logger}->log($level => $msg, $fields) if $self->{logger};
}

1;
__END__

=head1 NAME

Sledge::Migration - apply SQL migration files in order

=head1 SYNOPSIS

  my $migration = Sledge::Migration->new(dbh => $dbh, dir => 'migrations');
  my @applied = $migration->migrate;
  print "$_->{version} $_->{name} ", ($_->{applied} ? 'applied' : 'pending'), "\n"
      for $migration->status;

=head1 DESCRIPTION

Files are named C<NNN_description.sql>, or C<NNN_description.E<lt>driverE<gt>.sql>
(C<mysql>, C<Pg>, C<SQLite>) when the SQL differs between databases. They are
applied in numeric order, each recorded in the C<schema_migrations> table.

Concurrent runs are serialized with C<GET_LOCK> (MySQL) or an advisory lock
(PostgreSQL), so running migrations from every pod's init container is safe.

PostgreSQL and SQLite apply each file in a transaction. MySQL commits DDL
implicitly, so a failed MySQL migration may be partially applied; keep MySQL
migrations to one change per file.

=cut
