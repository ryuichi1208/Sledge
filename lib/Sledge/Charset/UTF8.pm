package Sledge::Charset::UTF8;
# $Id: UTF8.pm,v 1.2 2004/02/25 12:08:36 miyagawa Exp $
#
# Tatsuhiko Miyagawa <miyagawa@edge.co.jp>
# Livin' On The EDGE, Co., Ltd..
#

use strict;
use base qw(Sledge::Charset::Null);

use Encode ();

my $decode = sub { Encode::decode("UTF-8", shift) };
my $encode = sub { Encode::encode("UTF-8", shift) };

sub convert_param {
    my($self, $page) = @_;
    for my $p ($page->r->param) {
	my @v = map $decode->($_), $page->r->param($p);
	$page->r->param($p => \@v);
    }
    return;
}

sub content_type {
    return 'text/html; charset=UTF-8';
}

sub output_filter {
    my($self, $content) = @_;
    # If the template returned bytes, they are already UTF-8; return them as is
    return utf8::is_utf8($content) ? $encode->($content) : $content;
}

1;
