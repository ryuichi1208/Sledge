use strict;
use Test::More;
use lib 't/lib';

BEGIN {
    eval { require OpenTelemetry::SDK; 1 }
	or plan skip_all => 'OpenTelemetry::SDK is required';
    delete $ENV{$_} for grep /^OTEL_/, keys %ENV;
    $ENV{OTEL_BSP_SCHEDULE_DELAY} = 0;	# export after every request
}

use Cpanel::JSON::XS;
use File::Temp qw(tempfile);
use HTTP::Request::Common;
use Plack::Builder;
use Plack::Test;
use Sledge::Logger;
use Sledge::Tracing;

# Exporter that just collects the exported spans
package Test::MemoryExporter;
use Future;
sub new { bless { spans => [] }, shift }
sub export { my($self, $batch) = @_; push @{$self->{spans}}, @$batch; 0 }
sub shutdown { Future->done(0) }
sub take { my $self = shift; my @s = @{$self->{spans}}; $self->{spans} = []; @s }

package Mock::OTel::Pages;
use base qw(Sledge::Pages::PSGI);
use Sledge::Authorizer::Null;
use Sledge::Charset::Default;
use Sledge::SessionManager::Null;
use Sledge::Template::TT;

use vars qw($TMPL_PATH);
$TMPL_PATH = 't/template';

sub create_authorizer { Sledge::Authorizer::Null->new(shift) }
sub create_manager    { Sledge::SessionManager::Null->new(shift) }
sub create_charset    { Sledge::Charset::Default->new(shift) }
sub create_config     { Sledge::TestConfig->new(shift) }

sub dispatch_psgi {
    my $self = shift;
    $self->logger->info('in page');
    Sledge::Tracing->in_span('custom work', { 'work.id' => 7 }, sub { 1 });
}

sub dispatch_die { die "boom\n" }

package main;
require Sledge::TestPages;

my(undef, $logfile) = tempfile(UNLINK => 1);
open my $logfh, '>>', $logfile or die;
Sledge::Logger->default(Sledge::Logger->new(fh => $logfh));
sub logs {
    open my $in, '<', $logfile or die;
    my @rec = map { decode_json($_) } <$in>;
    truncate $logfile, 0;
    return @rec;
}

my $exporter = Test::MemoryExporter->new;
ok +Sledge::Tracing->setup(exporter => $exporter), 'setup';
ok +Sledge::Tracing->enabled;

my $app = builder {
    enable '+Sledge::Middleware::RequestId';
    enable '+Sledge::Middleware::OpenTelemetry', skip => qr{^/healthz$};
    enable '+Sledge::Middleware::AccessLog';
    Mock::OTel::Pages->to_app;
};

local $ENV{PLACK_ENV} = 'deployment';
my $trace_id  = '0af7651916cd43dd8448eb211c80319c';
my $parent_id = 'b7ad6b7169203331';

test_psgi $app, sub {
    my $cb = shift;

    my $res = $cb->(GET '/psgi?q=1', traceparent => "00-$trace_id-$parent_id-01");
    is $res->code, 200;

    my %span = map { $_->name => $_ } $exporter->take;
    my $server = $span{'GET /psgi'} or BAIL_OUT('server span not found: ' . join ', ', keys %span);
    is $server->kind, 2, 'server span kind';
    is $server->hex_trace_id, $trace_id, 'trace id from traceparent';
    is $server->hex_parent_span_id, $parent_id, 'parent from traceparent';
    is $server->attributes->{'http.route'}, '/psgi';
    is $server->attributes->{'http.request.method'}, 'GET';
    is $server->attributes->{'http.response.status_code'}, 200;
    is $server->attributes->{'url.query'}, 'q=1';

    for my $name ('Sledge session load', 'Sledge dispatch_psgi', 'Sledge render', 'Sledge session save') {
	ok $span{$name}, "$name span";
	is $span{$name} && $span{$name}->hex_parent_span_id, $server->hex_span_id, "$name is child of server span";
    }
    is $span{'custom work'}->hex_parent_span_id, $span{'Sledge dispatch_psgi'}->hex_span_id, 'custom span nests in dispatch';
    is $span{'custom work'}->attributes->{'work.id'}, 7;
    is $span{'Sledge dispatch_psgi'}->attributes->{'code.function'}, 'dispatch_psgi';
    like $span{'Sledge render'}->attributes->{'sledge.template'}, qr/psgi\.html$/;

    my @logs = logs();
    is $logs[0]{msg}, 'in page';
    is $logs[0]{trace_id}, $trace_id, 'app log has trace_id';
    is $logs[0]{span_id}, $span{'Sledge dispatch_psgi'}->hex_span_id, 'app log has span_id';
    is $logs[1]{type}, 'access';
    is $logs[1]{trace_id}, $trace_id, 'access log has trace_id';

    $res = $cb->(GET '/psgi');
    my($root) = grep { $_->name eq 'GET /psgi' } $exporter->take;
    like $root->hex_trace_id, qr/\A[0-9a-f]{32}\z/, 'new trace without traceparent';
    isnt $root->hex_trace_id, $trace_id;
    logs();

    $res = $cb->(GET '/die');
    is $res->code, 500;
    %span = map { $_->name => $_ } $exporter->take;
    ok $span{'GET /die'}->status->is_error, '5xx marks server span as error';
    ok $span{'Sledge dispatch_die'}->status->is_error, 'exception marks dispatch span as error';
    is +($span{'Sledge dispatch_die'}->events)[0]->name, 'exception', 'exception recorded';
    logs();

    $res = $cb->(GET '/nope');
    is $res->code, 404;
    ($root) = $exporter->take;
    is $root->name, 'GET', 'unknown route keeps method-only name';
    ok !$root->status->is_error, '404 is not a server error';
    logs();

    $res = $cb->(GET '/healthz');
    is scalar($exporter->take), 0, 'skipped path creates no span';
    logs();
};

done_testing;
