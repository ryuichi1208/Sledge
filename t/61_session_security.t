use strict;
use Test::More;

use MIME::Base64;
use Storable;
use Sledge::Session;
use Sledge::Session::SQLite;

# --- session id ---
{
    my %seen;
    for (1..1000) {
	my $sid = Sledge::Session->_gen_session_id;
	like $sid, qr/\A[0-9a-f]{32}\z/ or last if $_ == 1;
	$seen{$sid}++;
    }
    is scalar keys %seen, 1000, 'session ids are unique';

    local $Sledge::Session::SessionIdLength = 41;
    like +Sledge::Session->_gen_session_id, qr/\A[0-9a-f]{41}\z/, 'odd length';
}

# --- JSON serialization ---
{
    my $data = { foo => 'bar', list => [1, 2], nested => { 'k' => "\x{3042}" } };
    my $json = Sledge::Session->_serialize($data);
    like $json, qr/\A\{/, 'serialized as JSON';
    is_deeply +Sledge::Session->_deserialize($json), $data, 'round trip';
    is_deeply +Sledge::Session->_deserialize(undef), {}, 'empty data';

    eval { Sledge::Session->_serialize({ obj => bless {}, 'Foo' }) };
    isa_ok $@, 'Sledge::Exception::SessionSerializeError', 'objects are rejected';

    eval { Sledge::Session->_deserialize('{broken') };
    isa_ok $@, 'Sledge::Exception::SessionSerializeError', 'broken JSON';
}

# --- reading the old (Storable) format ---
{
    my $legacy = Storable::nfreeze({ foo => 'legacy' });
    is +Sledge::Session->_deserialize($legacy)->{foo}, 'legacy', 'legacy Storable is readable';

    my $legacy64 = encode_base64(Storable::freeze({ foo => 'legacy64' }));
    is +Sledge::Session::SQLite->_deserialize($legacy64)->{foo}, 'legacy64', 'legacy base64 Storable (SQLite/Pg)';

    local $Sledge::Session::AllowLegacyStorable = 0;
    eval { Sledge::Session->_deserialize($legacy) };
    isa_ok $@, 'Sledge::Exception::SessionSerializeError', 'legacy disabled';
}

# --- Storable mode ---
{
    local $Sledge::Session::Serializer = 'Storable';
    my $obj = { obj => bless { a => 1 }, 'Foo' };
    my $frozen = Sledge::Session->_serialize($obj);
    is ref +Sledge::Session->_deserialize($frozen)->{obj}, 'Foo', 'Storable keeps objects';

    my $b64 = Sledge::Session::SQLite->_serialize($obj);
    like $b64, qr/\A[A-Za-z0-9+\/=\n]+\z/, 'SQLite wraps Storable in base64';
    is ref +Sledge::Session::SQLite->_deserialize($b64)->{obj}, 'Foo';
}

done_testing;
