package Sledge::SessionManager::EncryptedCookie;
#
# Encrypts the session data itself with AES-256-GCM and stores it in the cookie.
# No server-side store is needed, so any number of pods works without an extra database.
#

use strict;
use base qw(Sledge::SessionManager::Cookie);

use CGI::Cookie;
use Cpanel::JSON::XS ();
use Crypt::AuthEnc::GCM ();
use Crypt::URandom ();
use Digest::SHA ();
use MIME::Base64 ();

use Sledge::Exceptions;
use Sledge::Session;

use vars qw($MaxCookieSize $MinSecretLength);
$MaxCookieSize   = 4000;	# leave headroom below the browser limit (about 4KB)
$MinSecretLength = 32;

my $JSON = Cpanel::JSON::XS->new->utf8->canonical;

sub get_session {
    my($self, $page) = @_;
    my $config = $page->create_config;
    my %jar    = CGI::Cookie->fetch;
    my $cookie = $jar{$config->cookie_name};

    my $payload = $cookie ? $self->decrypt($page, $cookie->value) : undef;
    my $session = $payload
	? Sledge::Session::EncryptedCookie->new($payload->{sid}, $payload->{data})
	: Sledge::Session::EncryptedCookie->new;

    $session->param(_timestamp => time);
    return $session;
}

sub set_session { }

# Called by Sledge::Pages::Base right before the headers are sent
sub finalize_session {
    my($self, $page, $session) = @_;
    if ($session->isa('Sledge::Session::Expired')) {
	my $cookie = CGI::Cookie->new($self->cookie_options($page, -value => '', -expires => '-1d'));
	$page->r->header_out('Set-Cookie' => $cookie->as_string);
	return;
    }

    my $value = $self->encrypt($page, {
	sid  => $session->session_id,
	data => $session->{_data},
	exp  => time + $self->_ttl($page),
    });
    my $cookie = CGI::Cookie->new($self->cookie_options($page, -value => $value));
    my $string = $cookie->as_string;
    if (length $string > $MaxCookieSize) {
	Sledge::Exception::SessionCookieTooLarge->throw(
	    sprintf('session cookie is %d bytes (max %d)', length $string, $MaxCookieSize),
	);
    }
    $page->r->header_out('Set-Cookie' => $string);
}

sub encrypt {
    my($self, $page, $payload) = @_;
    my($key) = $self->_keys($page);
    my $iv = Crypt::URandom::urandom(12);
    my($ciphertext, $tag) = Crypt::AuthEnc::GCM::gcm_encrypt_authenticate(
	'AES', $key, $iv, '', $JSON->encode($payload),
    );
    return _b64(join '', $iv, $tag, $ciphertext);
}

# Returns undef on tampering, expiry or key mismatch, so a new session is started
sub decrypt {
    my($self, $page, $value) = @_;
    my $raw = _unb64($value);
    return unless defined $raw && length $raw > 28;
    my($iv, $tag, $ciphertext) = unpack 'a12 a16 a*', $raw;

    for my $key ($self->_keys($page)) {
	my $plain = Crypt::AuthEnc::GCM::gcm_decrypt_verify('AES', $key, $iv, '', $ciphertext, $tag);
	next unless defined $plain;
	my $payload = eval { $JSON->decode($plain) } or return;
	return unless ref $payload eq 'HASH' && ref $payload->{data} eq 'HASH';
	return if ($payload->{exp} || 0) < time;
	return $payload;
    }
    return;
}

# SESSION_SECRET may contain multiple keys separated by whitespace or commas.
# The first key encrypts, and every key is tried for decryption (for key rotation).
sub _keys {
    my($self, $page) = @_;
    my $secret = Sledge::SessionManager::Cookie::_config($page->create_config, 'session_secret');
    my @secrets = grep length, split /[\s,]+/, defined $secret ? $secret : '';
    if (!@secrets || grep { length($_) < $MinSecretLength } @secrets) {
	Sledge::Exception::SessionSecretError->throw(
	    "SESSION_SECRET must be set and each key must be at least $MinSecretLength characters",
	);
    }
    return map { Digest::SHA::sha256($_) } @secrets;
}

sub _ttl {
    my($self, $page) = @_;
    return Sledge::SessionManager::Cookie::_config($page->create_config, 'session_ttl', 86400);
}

sub _b64 {
    my $s = MIME::Base64::encode_base64(shift, '');
    $s =~ tr{+/}{-_};
    $s =~ s/=+$//;
    return $s;
}

sub _unb64 {
    my $s = shift;
    return unless defined $s && $s =~ /^[A-Za-z0-9_-]+$/;
    $s =~ tr{-_}{+/};
    return MIME::Base64::decode_base64($s);
}

package Sledge::Session::EncryptedCookie;
use base qw(Sledge::Session);

sub new {
    my($class, $sid, $data) = @_;
    my $self = bless {
	_sid     => $sid,
	_data    => $data || {},
	_changed => 0,
	_new     => 0,
    }, $class;
    unless ($sid) {
	$self->{_sid} = $self->_gen_session_id;
	$self->{_new} = 1;
    }
    return $self;
}

sub expire {
    my $self = shift;
    %$self = ();
    bless $self, 'Sledge::Session::Expired';
}

sub cleanup { }
sub DESTROY { }

1;
__END__

=head1 NAME

Sledge::SessionManager::EncryptedCookie - store session data in an encrypted cookie

=head1 SYNOPSIS

  package MyProj::Pages;
  use Sledge::SessionManager::EncryptedCookie;

  sub create_manager {
      my $self = shift;
      return Sledge::SessionManager::EncryptedCookie->new($self);
  }

  # create_session is not used

=head1 DESCRIPTION

Encrypts the session data with AES-256-GCM (which also detects tampering) and stores it in a cookie.
No server-side session store is needed, which makes horizontal scaling easier.

Configuration keys:

=over 4

=item SESSION_SECRET (required)

Secret key of at least 32 characters. With multiple keys separated by whitespace or commas, the first key
encrypts and every key is tried for decryption. To rotate keys, add the new key at the front,
and remove the old key once the old sessions have expired.

=item SESSION_TTL

Lifetime in seconds. Default 86400. Extended on every access.

=item COOKIE_NAME, COOKIE_PATH, COOKIE_DOMAIN, COOKIE_SECURE, COOKIE_HTTPONLY, COOKIE_SAMESITE

Same as L<Sledge::SessionManager::Cookie>.

=back

Data larger than the cookie limit (about 4KB) cannot be stored.
For larger data, use L<Sledge::Session::Redis> or another server-side store.

=cut
