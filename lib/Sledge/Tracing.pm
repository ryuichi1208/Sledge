package Sledge::Tracing;
#
# Tracing with OpenTelemetry.
# Does nothing (and does not even load the OpenTelemetry modules) unless setup() is called.
#

use strict;
use Sledge;

use vars qw($Enabled $Processor);
$Enabled = 0;

# Call once from app.psgi. Configure with the standard OpenTelemetry environment variables:
#   OTEL_SDK_DISABLED=true        disable tracing
#   OTEL_SERVICE_NAME             service name
#   OTEL_TRACES_EXPORTER          otlp (default) / console / none
#   OTEL_EXPORTER_OTLP_ENDPOINT   e.g. http://otel-collector:4318
#   OTEL_TRACES_SAMPLER(_ARG)     sampling
#   OTEL_PROPAGATORS              default tracecontext,baggage
#
#   instrumentations => [ 'DBI', 'HTTP::Tiny' ]  enable OpenTelemetry::Instrumentation for these
sub setup {
    my($class, %opt) = @_;
    return if $Enabled;
    return if lc($ENV{OTEL_SDK_DISABLED} || '') eq 'true';

    require OpenTelemetry;
    require OpenTelemetry::SDK;
    require OpenTelemetry::SDK::Trace::TracerProvider;
    require Sledge::Tracing::SpanProcessor;

    OpenTelemetry::SDK->configure_propagators;

    my $provider = OpenTelemetry::SDK::Trace::TracerProvider->new($class->_resource_args);
    if (my $exporter = $opt{exporter} || $class->_exporter_from_env) {
	$Processor = Sledge::Tracing::SpanProcessor->new(exporter => $exporter);
	$provider->add_span_processor($Processor);
    }
    OpenTelemetry->tracer_provider = $provider;

    if (my @inst = @{ $opt{instrumentations} || [] }) {
	require OpenTelemetry::Instrumentation;
	OpenTelemetry::Instrumentation->import(@inst);
    }

    $Enabled = 1;
    return $provider;
}

# Report the release (SLEDGE_RELEASE, the git revision baked into the image)
# as service.version, unless OTEL_RESOURCE_ATTRIBUTES already sets one
sub _resource_args {
    my $release = $ENV{SLEDGE_RELEASE};
    return unless defined $release && length $release;
    return if ($ENV{OTEL_RESOURCE_ATTRIBUTES} || '') =~ /(?:^|,)\s*service\.version=/;
    require OpenTelemetry::SDK::Resource;
    return (resource => OpenTelemetry::SDK::Resource->new(
	attributes => { 'service.version' => $release },
    ));
}

sub _exporter_from_env {
    my $name = lc($ENV{OTEL_TRACES_EXPORTER} || 'otlp');
    if ($name eq 'otlp') {
	require OpenTelemetry::Exporter::OTLP::Traces;
	return OpenTelemetry::Exporter::OTLP::Traces->new;
    }
    if ($name eq 'console') {
	require OpenTelemetry::SDK::Exporter::Console;
	return OpenTelemetry::SDK::Exporter::Console->new;
    }
    warn "Sledge::Tracing: unsupported OTEL_TRACES_EXPORTER '$name'; spans are not exported\n"
	unless $name eq 'none';
    return;
}

sub enabled { $Enabled }

sub tracer {
    return OpenTelemetry->tracer_provider->tracer(
	name => 'Sledge', version => $Sledge::VERSION,
    );
}

# When tracing is disabled, just call $code
sub in_span {
    my($class, $name, $attributes, $code) = @_;
    return $code->() unless $Enabled;
    my %attr = map { defined $attributes->{$_} ? ($_ => $attributes->{$_}) : () }
	keys %{ $attributes || {} };
    return $class->tracer->in_span($name, attributes => \%attr, sub { $code->() });
}

sub current_span {
    return unless $Enabled;
    my $span = OpenTelemetry::Trace->span_from_context(OpenTelemetry::Context->current);
    return $span->context->valid ? $span : undef;
}

# trace_id / span_id to add to log lines
sub current_ids {
    my $span = shift->current_span or return;
    my $ctx = $span->context;
    return (trace_id => $ctx->hex_trace_id, span_id => $ctx->hex_span_id);
}

sub flush_if_due {
    $Processor->flush_if_due if $Processor;
}

sub shutdown {
    return unless $Enabled;
    OpenTelemetry->tracer_provider->shutdown->get;
}

# Export the remaining spans when a worker process exits
END {
    eval { __PACKAGE__->shutdown } if $Enabled;
}

1;
__END__

=head1 NAME

Sledge::Tracing - OpenTelemetry tracing for Sledge

=head1 SYNOPSIS

  # app.psgi
  use Sledge::Tracing;
  Sledge::Tracing->setup(instrumentations => [ 'DBI' ]);

  builder {
      enable '+Sledge::Middleware::OpenTelemetry';
      ...
  };

  # turn any piece of work into a span
  Sledge::Tracing->in_span('charge card', { 'order.id' => $id }, sub { ... });

=head1 DESCRIPTION

Once C<setup> has been called, the following spans are recorded.

=over 4

=item * HTTP server span (Sledge::Middleware::OpenTelemetry)

Continues the trace from the C<traceparent> header. Named like C<GET /page>.

=item * C<Sledge session>, C<Sledge dispatch_xxx>, C<Sledge render>

=item * Modules listed in C<instrumentations> (DBI etc.)

=back

Lines logged with L<Sledge::Logger> get C<trace_id> and C<span_id>.

=cut
