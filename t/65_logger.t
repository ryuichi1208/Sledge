use strict;
use Test::More;
use File::Temp qw(tempfile);
use Cpanel::JSON::XS;
use Sledge::Logger;

sub capture(&;%) {
    my($code, %opt) = @_;
    my($fh, $file) = tempfile(UNLINK => 1);
    my $logger = Sledge::Logger->new(fh => $fh, %opt);
    $code->($logger);
    close $fh;
    open my $in, '<', $file or die;
    return map { chomp; $_ } <$in>;
}

{
    my @lines = capture { shift->info('hello', { user_id => 42 }) };
    is @lines, 1;
    my $rec = decode_json($lines[0]);
    is $rec->{level}, 'info';
    is $rec->{msg}, 'hello';
    is $rec->{user_id}, 42;
    like $rec->{time}, qr/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z\z/, 'ISO8601 UTC';
}

{
    my @lines = capture {
	my $log = shift;
	$log->debug('hidden');
	$log->info('shown');
	$log->error("trailing newline\n");
    } level => 'info';
    is @lines, 2, 'debug filtered';
    is decode_json($lines[1])->{msg}, 'trailing newline', 'trailing whitespace removed';
}

{
    local $Sledge::Logger::Context{request_id} = 'req-1';
    my @lines = capture { shift->warn("\x{65e5}\x{672c}\x{8a9e}") };
    my $rec = decode_json($lines[0]);
    is $rec->{request_id}, 'req-1', 'context is attached';
    is $rec->{msg}, "\x{65e5}\x{672c}\x{8a9e}", 'unicode';
}

{
    my @lines = capture { shift->info('text mode', { a => 1 }) } format => 'text';
    like $lines[0], qr/\A\S+Z INFO text mode a=1\z/, 'text format';
}

{
    local $ENV{SLEDGE_LOG_LEVEL} = 'error';
    is +Sledge::Logger->new->level, 'error', 'level from env';
}

done_testing;
