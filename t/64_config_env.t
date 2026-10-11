use strict;
use Test::More;
use File::Temp qw(tempfile);

package Test::EnvConfig;
use base qw(Sledge::Config::Env);
__PACKAGE__->env_prefix('TESTAPP_');
__PACKAGE__->defaults({ TMPL_PATH => '/default/tmpl', COOKIE_NAME => 'sid' });

package Test::EnvConfig::_common;
use vars qw(%C);
*Config = \%C;
$C{COOKIE_NAME} = 'from_module';
$INC{'Test/EnvConfig/_common.pm'} = __FILE__;

package Test::RequiredConfig;
use base qw(Sledge::Config::Env);
__PACKAGE__->env_prefix('TESTREQ_');
__PACKAGE__->required([qw(SESSION_SECRET DSN)]);

package main;

delete $ENV{$_} for grep /^TEST(APP|REQ)_/, keys %ENV;

{
    my $c = Test::EnvConfig->new;
    is $c->tmpl_path, '/default/tmpl', 'default';
    is $c->cookie_name, 'from_module', 'module overrides default';
    eval { $c->no_such_key };
    like $@, qr/no such key/, 'strict param';
}

{
    local $ENV{TESTAPP_TMPL_PATH}   = '/env/tmpl';
    local $ENV{TESTAPP_COOKIE_NAME} = 'from_env';
    local $ENV{TESTAPP_DSN}         = 'dbi:mysql:database=app';
    local $ENV{TESTAPP_DB_USER}     = 'user';
    local $ENV{TESTAPP_DB_PASSWORD} = 'pass';
    local $ENV{OTHER_TMPL_PATH}     = '/ignored';
    my $c = Test::EnvConfig->new;
    is $c->tmpl_path, '/env/tmpl', 'env overrides default';
    is $c->cookie_name, 'from_env', 'env overrides module';
    is_deeply [ $c->datasource ], [ 'dbi:mysql:database=app', 'user', 'pass' ], 'datasource from DSN';
}

{
    my($fh, $file) = tempfile(UNLINK => 1);
    print $fh "s3cret\n";
    close $fh;
    local $ENV{TESTAPP_DB_PASSWORD_FILE} = $file;
    local $ENV{TESTAPP_SECRET_FILE}      = $file;
    local $ENV{TESTAPP_SECRET}           = 'direct';
    my $c = Test::EnvConfig->new;
    is $c->db_password, 's3cret', '_FILE reads file and strips newline';
    is $c->secret, 'direct', 'direct value wins over _FILE';

    local $ENV{TESTAPP_X_FILE} = '/nonexistent/file';
    eval { Test::EnvConfig->new };
    isa_ok $@, 'Sledge::Exception::ConfigMissing', 'unreadable _FILE';
}

{
    eval { Test::RequiredConfig->new };
    isa_ok $@, 'Sledge::Exception::ConfigMissing';
    like "$@", qr/TESTREQ_SESSION_SECRET .*TESTREQ_DSN/, 'lists missing keys';

    local $ENV{TESTREQ_SESSION_SECRET} = 'x';
    local $ENV{TESTREQ_DSN} = 'dbi:SQLite:';
    ok eval { Test::RequiredConfig->new }, 'required keys present';
}

done_testing;
