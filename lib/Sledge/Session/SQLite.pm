package Sledge::Session::SQLite;
# $Id: SQLite.pm,v 1.1.1.1 2003/02/13 06:59:36 miyagawa Exp $
#
# Tatsuhiko Miyagawa <miyagawa@edge.co.jp>
# Livin' On The EDGE, Co., Ltd..
#

use strict;
use base qw(Sledge::Session::DBI);

use MIME::Base64;
use Storable;
use Sledge::Exceptions;

sub connect_attr {
    return {
	PrintError => 1, RaiseError => 1, AutoCommit => 1,
    };
}

sub _do_lock { }

# Storable is wrapped in base64 to fit a TEXT column (JSON is stored as is)
sub _serialize {
    my($self, $data) = @_;
    my $serialized = $self->SUPER::_serialize($data);
    return $Sledge::Session::Serializer eq q(Storable)
	? encode_base64($serialized) : $serialized;
}

sub _thaw_legacy {
    my($self, $data) = @_;
    return Storable::thaw(decode_base64($data));
}

sub _transaction { 0 }

sub _do_cleanup { Sledge::Exception::UnimplementedMethod->throw }

1;
