# $Id: 11_hooks.t,v 1.1.1.1 2003/02/13 06:59:36 miyagawa Exp $

use strict;
use Test::More tests => 10;

package Test::Pages;
use base qw(Sledge::Pages::Base);

eval {
    __PACKAGE__->register_hook(foo => sub { 1 });
};
::like $@, qr/not valid triggerpoint/;

my $foo;
__PACKAGE__->register_hook(AFTER_INIT => sub { $foo = 2 });
__PACKAGE__->register_hook(BEFORE_DISPATCH => sub { $foo++ });

package main;

my $p = bless {}, 'Test::Pages';
$p->invoke_hook('AFTER_INIT');

is $foo, 2, 'AFTER_INIT called';

$p->register_hook(AFTER_INIT => sub { $foo++ });
$p->invoke_hook('AFTER_INIT');

is $foo, 3, 'multiple hooks';

my $o = bless {}, 'Test::Pages';
$foo = 1;
$o->invoke_hook('AFTER_INIT');

is $foo, 2, 'class hook unchanged';

package Test::Pages::Bar;
@Test::Pages::Bar::ISA = qw(Test::Pages);

package main;

# Check inheritance through call results, not Class::Trigger internals
$foo = 0;
is +Test::Pages::Bar->invoke_hook('AFTER_INIT'), 1, 'inherited';
Test::Pages::Bar->register_hook(AFTER_INIT => sub { $foo = 4 });

is +Test::Pages::Bar->invoke_hook('AFTER_INIT'), 2, 'added';

my $b = bless {}, 'Test::Pages::Bar';
$b->invoke_hook('AFTER_INIT');
is $foo, 4, 'hook called';

my $q = bless {}, 'Test::Pages';
$foo = 0;
$q->invoke_hook('AFTER_INIT');
is $foo, 2, 'parent unchanged';

package Test::Pages::Bar::Baz;
@Test::Pages::Bar::Baz::ISA = qw(Test::Pages::Bar);

package main;

is +Test::Pages::Bar::Baz->invoke_hook('AFTER_INIT'), 2, 'inherited';
is +Test::Pages::Bar::Baz->invoke_hook('BEFORE_DISPATCH'), 1, 'inherited from granpa';
