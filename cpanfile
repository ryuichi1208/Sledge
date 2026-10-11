requires 'CGI', '4.50';
requires 'Class::Accessor';
requires 'Class::Data::Inheritable';
requires 'Class::Singleton';
requires 'Class::Trigger';
requires 'Cpanel::JSON::XS';
requires 'Crypt::URandom';
requires 'CryptX';
requires 'Digest::SHA';
requires 'Error', '0.15';
requires 'File::Spec';
requires 'File::Temp';
requires 'HTML::FillInForm';
requires 'HTML::StickyQuery';
requires 'HTML::Template';
requires 'Jcode';
requires 'Storable';
requires 'Template';
requires 'Time::HiRes';
requires 'URI';

# PSGI (for running in containers, e.g. on Kubernetes)
requires 'Plack', '1.0050';
requires 'CGI::PSGI';
requires 'Starlet';
requires 'Plack::Middleware::ReverseProxy';

# Session stores
requires 'DBI';
recommends 'DBD::SQLite';
feature 'mysql', 'MySQL session store' => sub {
    requires 'DBD::mysql';
};
feature 'pg', 'PostgreSQL session store' => sub {
    requires 'DBD::Pg';
};
feature 'otel', 'OpenTelemetry tracing' => sub {
    requires 'OpenTelemetry', '0.039';
    requires 'OpenTelemetry::SDK', '0.028';
    requires 'OpenTelemetry::Exporter::OTLP', '0.021';
};
feature 'redis', 'Redis / Valkey session store' => sub {
    requires 'Redis::Fast';
};

on test => sub {
    requires 'Test::More', '0.98';
    requires 'IO::Stringy';
    requires 'DBD::SQLite';
    requires 'HTTP::Request::Common';
};
