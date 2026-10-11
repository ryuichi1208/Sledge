use v5.26;
use Object::Pad 0.74;

# A synchronous batch SpanProcessor for prefork servers (Starlet / Starman).
#
# The SDK's BatchSpanProcessor exports from an IO::Async event loop, so nothing is
# exported on a prefork server, which never runs that loop.
# This processor queues spans in the process and exports them synchronously from
# flush_if_due(), which Sledge::Middleware::OpenTelemetry calls after the response is sent.
package Sledge::Tracing::SpanProcessor;

class Sledge::Tracing::SpanProcessor :does(OpenTelemetry::Trace::Span::Processor) {
    use Future;
    use OpenTelemetry::Constants qw(TRACE_EXPORT_SUCCESS TRACE_EXPORT_FAILURE);
    use Time::HiRes ();

    field $exporter       :param;
    # Environment variable names follow the OpenTelemetry BatchSpanProcessor spec
    field $max_queue_size :param = $ENV{OTEL_BSP_MAX_QUEUE_SIZE}        // 2048;
    field $batch_size     :param = $ENV{OTEL_BSP_MAX_EXPORT_BATCH_SIZE} // 512;
    # Default 0 (export after every request). On a prefork server an idle worker is not guaranteed
    # to get another request, so with a longer interval spans could stay in the worker.
    field $schedule_delay :param = ($ENV{OTEL_BSP_SCHEDULE_DELAY} // 0) / 1000;
    field $export_timeout :param = ($ENV{OTEL_BSP_EXPORT_TIMEOUT} // 1000) / 1000;
    # After a failed export, stop exporting for this many seconds and drop spans,
    # so workers do not wait for the timeout on every request while the collector is down.
    field $failure_backoff :param = $ENV{SLEDGE_OTEL_FAILURE_BACKOFF} // 30;
    field @queue;
    field $last_flush = Time::HiRes::time();
    field $suspended_until = 0;
    field $done = 0;
    field $dropped :reader = 0;

    method on_start ( $span, $context ) { }

    method on_end ($span) {
	return if $done;
	return unless $span->context->trace_flags->sampled;
	push @queue, $span->snapshot;
	if (@queue > $max_queue_size) {
	    my $overflow = @queue - $max_queue_size;
	    splice @queue, 0, $overflow;	# drop the oldest first
	    $dropped += $overflow;
	}
	return;
    }

    method process (@items) { $self->on_end($_) for @items; return }

    method queue_size () { scalar @queue }

    # Export once the batch is full or schedule_delay has passed since the last export
    method flush_if_due () {
	return unless @queue;
	return if @queue < $batch_size
	    && Time::HiRes::time() - $last_flush < $schedule_delay;
	$self->export_all;
    }

    method export_all () {
	my $now = Time::HiRes::time();
	$last_flush = $now;
	if ($now < $suspended_until) {
	    $dropped += @queue;
	    @queue = ();
	    return TRACE_EXPORT_FAILURE;
	}
	while (my @batch = splice @queue, 0, $batch_size) {
	    my $res = eval { $exporter->export(\@batch, $export_timeout) } // TRACE_EXPORT_FAILURE;
	    next if $res == TRACE_EXPORT_SUCCESS;
	    $dropped += @batch + @queue;
	    @queue = ();
	    $suspended_until = Time::HiRes::time() + $failure_backoff;
	    return $res;
	}
	return TRACE_EXPORT_SUCCESS;
    }

    method force_flush ( $timeout = undef ) {
	return Future->done($self->export_all);
    }

    method shutdown ( $timeout = undef ) {
	return Future->done(TRACE_EXPORT_SUCCESS) if $done;
	my $result = $self->export_all;
	$done = 1;
	eval { $exporter->shutdown($timeout)->get };
	return Future->done($result);
    }
}

1;
