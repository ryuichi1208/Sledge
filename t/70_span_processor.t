use strict;
use Test::More;

BEGIN {
    eval { require OpenTelemetry::SDK; 1 }
	or plan skip_all => 'OpenTelemetry::SDK is required';
}

use Future;
use OpenTelemetry::Constants qw(TRACE_EXPORT_SUCCESS TRACE_EXPORT_FAILURE);
use Sledge::Tracing::SpanProcessor;

package Test::Exporter;
sub new { bless { calls => 0, result => 0, spans => [] }, shift }
sub export { my($self, $batch) = @_; $self->{calls}++; push @{$self->{spans}}, @$batch; $self->{result} }
sub shutdown { Future->done(0) }

package Test::Span;
sub new { my($class, $sampled) = @_; bless { sampled => $sampled }, $class }
sub context { $_[0] }
sub trace_flags { $_[0] }
sub sampled { $_[0]{sampled} }
sub snapshot { $_[0] }

package main;

my $exporter = Test::Exporter->new;
my $p = Sledge::Tracing::SpanProcessor->new(
    exporter => $exporter, batch_size => 3, max_queue_size => 5,
    schedule_delay => 60, failure_backoff => 60,
);

$p->on_end(Test::Span->new(1)) for 1..2;
$p->on_end(Test::Span->new(0));
is $p->queue_size, 2, 'unsampled spans are ignored';
$p->flush_if_due;
is $exporter->{calls}, 0, 'not due yet';

$p->on_end(Test::Span->new(1));
$p->flush_if_due;
is $exporter->{calls}, 1, 'exported when batch is full';
is $p->queue_size, 0;

$p->on_end(Test::Span->new(1)) for 1..7;
is $p->queue_size, 5, 'queue is bounded';
is $p->dropped, 2, 'overflow is counted';

$exporter->{result} = TRACE_EXPORT_FAILURE;
$p->force_flush->get;
is $exporter->{calls}, 2, 'export attempted';
is $p->queue_size, 0;

$exporter->{result} = TRACE_EXPORT_SUCCESS;
$p->on_end(Test::Span->new(1)) for 1..3;
$p->flush_if_due;
is $exporter->{calls}, 2, 'suspended after failure';
is $p->queue_size, 0, 'spans dropped while suspended';

$p = Sledge::Tracing::SpanProcessor->new(exporter => $exporter, schedule_delay => 0);
$p->on_end(Test::Span->new(1));
$p->shutdown->get;
is $exporter->{calls}, 3, 'shutdown flushes';
$p->on_end(Test::Span->new(1));
is $p->queue_size, 0, 'no spans after shutdown';

done_testing;
