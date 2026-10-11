use strict;
use Test::More;

BEGIN {
    eval { require DBD::SQLite; 1 } or plan skip_all => 'DBD::SQLite is required';
}

use File::Temp qw(tempdir);
use Sledge::Session::SQLite;

my $dir = tempdir(CLEANUP => 1);

package Mock::Pages;
sub create_config { bless {}, 'Mock::Config' }
package Mock::Config;
sub datasource { ("dbi:SQLite:dbname=$dir/sessions.db", '', '') }

package main;

my $page = bless {}, 'Mock::Pages';
my $session = bless {}, 'Sledge::Session::SQLite';

my $parent = $session->_connect_database($page);
is $parent->{private_sledge_pid}, $$, 'handle is tagged with pid';
ok $parent->{AutoInactiveDestroy}, 'AutoInactiveDestroy';
is $session->_connect_database($page), $parent, 'cached in the same process';

pipe my $r, my $w or die;
my $pid = fork;
die "fork: $!" unless defined $pid;
if ($pid == 0) {
    close $r;
    my $child = $session->_connect_database($page);
    print $w (($child == $parent ? 'same' : 'new') . " $child->{private_sledge_pid}\n");
    close $w;
    exit 0;
}
close $w;
my $line = <$r>;
waitpid $pid, 0;

is $line, "new $pid\n", 'child process opens its own connection';
ok $parent->ping, 'parent connection survives child exit';

done_testing;
