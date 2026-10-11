package Sledge::Logger;
#
# Writes structured logs to stderr, one JSON object per line, so that container
# platforms (Kubernetes + Fluent Bit / Datadog Agent etc.) can collect and search them as is.
#

use strict;
use Cpanel::JSON::XS ();
use POSIX ();
use Time::HiRes ();

use vars qw(%Context);

# Fields added to every log line for the current request (request_id etc.).
# Set with local by Sledge::Middleware::RequestId.
%Context = ();

my %LEVEL = (debug => 10, info => 20, warn => 30, error => 40, fatal => 50);

my $JSON = Cpanel::JSON::XS->new->utf8->canonical->allow_blessed->convert_blessed->allow_unknown;

my $Default;

# Logger shared by the whole application
#   SLEDGE_LOG_LEVEL  : debug / info (default) / warn / error / fatal
#   SLEDGE_LOG_FORMAT : json (default) / text
#   SLEDGE_RELEASE    : added to every line as "release" (set by the image build)
sub default {
    my $class = shift;
    $Default = shift if @_;
    $Default ||= $class->new;
}

sub new {
    my($class, %opt) = @_;
    my $level  = lc($opt{level}  || $ENV{SLEDGE_LOG_LEVEL}  || 'info');
    my $format = lc($opt{format} || $ENV{SLEDGE_LOG_FORMAT} || 'json');
    $level = 'info' unless $LEVEL{$level};
    bless {
	level  => $level,
	format => $format,
	fh     => $opt{fh} || \*STDERR,
	fields => {
	    (length($ENV{SLEDGE_RELEASE} // '') ? (release => $ENV{SLEDGE_RELEASE}) : ()),
	    %{ $opt{fields} || {} },
	},
    }, $class;
}

sub level {
    my $self = shift;
    $self->{level} = lc shift if @_ && $LEVEL{lc $_[0]};
    return $self->{level};
}

sub is_enabled {
    my($self, $level) = @_;
    return ($LEVEL{$level} || 0) >= $LEVEL{$self->{level}};
}

sub debug { shift->log(debug => @_) }
sub info  { shift->log(info  => @_) }
sub warn  { shift->log(warn  => @_) }
sub error { shift->log(error => @_) }
sub fatal { shift->log(fatal => @_) }

sub log {
    my($self, $level, $message, $fields) = @_;
    return unless $self->is_enabled($level);

    my %record = (
	%{$self->{fields}},
	%Context,
	# Correlate logs with OpenTelemetry traces
	($Sledge::Tracing::Enabled ? Sledge::Tracing->current_ids : ()),
	($fields ? %$fields : ()),
	time  => _timestamp(),
	level => $level,
	msg   => defined $message ? "$message" : '',
    );
    $record{msg} =~ s/\s+\z//;

    my $line = $self->{format} eq 'text' ? _format_text(\%record) : $JSON->encode(\%record);
    utf8::encode($line) if utf8::is_utf8($line);
    # Write with a single write() so lines from multiple workers never interleave
    syswrite $self->{fh}, "$line\n";
    return 1;
}

# Turn warn() output into JSON log lines as well
sub capture_warnings {
    my $self = ref $_[0] ? shift : shift->default;
    $SIG{__WARN__} = sub { $self->warn($_[0]) };
}

sub _timestamp {
    my($sec, $usec) = Time::HiRes::gettimeofday();
    return POSIX::strftime('%Y-%m-%dT%H:%M:%S', gmtime $sec) . sprintf('.%03dZ', $usec / 1000);
}

sub _format_text {
    my $r = shift;
    my %rest = %$r;
    my($time, $level, $msg) = delete @rest{qw(time level msg)};
    my $extra = join ' ', map {
	my $v = $rest{$_};
	$v = ref $v ? $JSON->encode($v) : defined $v ? $v : '';
	"$_=$v";
    } sort keys %rest;
    return join ' ', grep length, $time, uc $level, $msg, $extra;
}

1;
__END__

=head1 NAME

Sledge::Logger - structured JSON logger

=head1 SYNOPSIS

  # from inside Pages
  $self->logger->info('user logged in', { user_id => $id });

  # from anywhere
  Sledge::Logger->default->error('payment failed', { order_id => $order });

  # example output
  {"level":"info","msg":"user logged in","request_id":"5f2c...","time":"2026-10-11T04:38:57.123Z","user_id":42}

=cut
