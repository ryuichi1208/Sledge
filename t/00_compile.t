# $Id: 00_compile.t,v 1.1.1.1 2003/02/13 06:59:36 miyagawa Exp $
#
# Tatsuhiko Miyagawa <miyagawa@edge.co.jp>
# Livin' On The EDGE, Co., Ltd..
#

use strict;
use Test::More;

use File::Find;

my @mod;
find(\&wanted, 'lib');

plan tests => scalar @mod;
for my $mod (@mod) {
  SKIP: {
	# mod_perl 1.x (Apache.pm) is not available for current Perl
	skip "$mod requires mod_perl 1.x", 1
	    if $mod eq 'Sledge::Pages::Apache' && !eval { require Apache; 1 };
	require_ok $mod;
    }
}

sub wanted {
    if (/\.pm$/) {
	my $module = $File::Find::name;
	$module =~ s@^lib/(.*)\.pm$@$1@;
	$module =~ s@/@::@g;
	push @mod, $module;
    }
}
