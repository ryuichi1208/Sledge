package Sledge::Pages::Base;
# $Id: Base.pm,v 1.4 2005/07/06 17:05:58 yoshiki Exp $
#
# Tatsuhiko Miyagawa <miyagawa@edge.co.jp>
# Livin' On The EDGE, Co., Ltd..
#

use strict;
use base qw(Class::Accessor Class::Data::Inheritable);

__PACKAGE__->mk_accessors(
    'r',			# Apache::Request or Sledge::Request::CGI
    'session',			# Sledge::Session
    'manager',			# Sledge::SessionManager
    'authorizer',		# Sledge::Authorizer
    'charset',			# Sledge::Charset
    'tmpl',			# Sledge::Template
    'fillin_form',		# Sledge::FillInForm
    'finished',			# flag whether request is finished
    'page',			# page name (arg to dispatch())
    'filters',			# filter subs
);

__PACKAGE__->mk_classdata('tmpl_dirname');
__PACKAGE__->tmpl_dirname('.');	# default: should be overriden

use constant REDIRECT     => 302;
use constant SERVER_ERROR => 500;

use File::Spec;
use URI;

use Sledge::Exceptions;
use Sledge::FillInForm;
use Sledge::Template;
use Sledge::Registrar;
use Sledge::Tracing;

# abstract methods
sub create_authorizer { Sledge::Exception::AbstractMethod->throw }
sub create_manager    { Sledge::Exception::AbstractMethod->throw }
sub create_charset    { Sledge::Exception::AbstractMethod->throw }
sub create_session    { Sledge::Exception::AbstractMethod->throw }
sub create_config     { Sledge::Exception::AbstractMethod->throw }

# abstract methods for CGI/mod_perl implementor
sub create_request    { Sledge::Exception::AbstractMethod->throw }

# deprecated methods
sub do_request        { Sledge::Exception::DeprecatedMethod->throw }
sub send_content      { Sledge::Exception::DeprecatedMethod->throw }

# Formerly implemented via LoadHooks
use Class::Trigger qw(BEFORE_INIT AFTER_INIT BEFORE_DISPATCH AFTER_DISPATCH AFTER_OUTPUT);

# Class::Trigger 0.14 and later no longer validate trigger names in subclasses, so validate here.
# Subclasses that want their own hooks should extend hook_points.
__PACKAGE__->mk_classdata('hook_points');
__PACKAGE__->hook_points({
    map { $_ => 1 } qw(BEFORE_INIT AFTER_INIT BEFORE_DISPATCH AFTER_DISPATCH AFTER_OUTPUT)
});

sub register_hook {
    my($self, $when) = @_;
    unless ($self->hook_points->{$when}) {
	require Carp;
	Carp::croak("$when is not valid triggerpoint for " . (ref($self) || $self));
    }
    goto &add_trigger;
}

*invoke_hook   = \&call_trigger;

sub new {
    my $class = shift;
    my $self = bless {}, $class;
    $self->invoke_hook('BEFORE_INIT');
    $self->init(@_);
    $self->invoke_hook('AFTER_INIT');
    return $self;
}

sub init {
    my($self, $r) = @_;
    $self->r($self->create_request($r));
    $self->authorizer($self->create_authorizer);
    $self->manager($self->create_manager);
    $self->charset($self->create_charset);
}

# this method is called from .cgi
sub dispatch {
    my($self, $page) = @_;
    return if $self->finished; # already redirected?

    no warnings 'redefine';
    local *Sledge::Registrar::context = sub { $self };
    Sledge::Exception->do_trace(1) if $self->debug_level;
    eval {
	$self->init_dispatch($page);
	$self->invoke_hook('BEFORE_DISPATCH') unless $self->finished;
	if ($self->is_post_request && ! $self->finished) {
	    my $postmeth = 'post_dispatch_' . $page;
	    $self->_call_page_method($postmeth) if $self->can($postmeth);
	}
	unless ($self->finished) {
	    my $method = 'dispatch_' . $page;
	    $self->_call_page_method($method);
	    $self->invoke_hook('AFTER_DISPATCH');
	}
	$self->output_content unless $self->finished;
    };
    $self->handle_exception($@) if $@;
    # Saving the session (Session::DESTROY) happens here
    $Sledge::Tracing::Enabled
	? Sledge::Tracing->in_span('Sledge session save', {}, sub { $self->_destroy_me })
	: $self->_destroy_me;
}

# Avoid extra stack frames when tracing is disabled
sub _call_page_method {
    my($self, $method) = @_;
    return $self->$method() unless $Sledge::Tracing::Enabled;
    Sledge::Tracing->in_span("Sledge $method", {
	'code.namespace' => ref $self,
	'code.function'  => $method,
    }, sub { $self->$method() });
}

sub handle_exception {
    my($self, $E) = @_;
    die $E;
}

sub logger {
    require Sledge::Logger;
    return Sledge::Logger->default;
}

sub debug_level {
    my $self = shift;
    return 0;
    # return $self->r->dir_config('SledgeDebug')
}

sub init_dispatch {
    my($self, $page) = @_;
    $self->page($page);
    unless (defined $self->session) {
	$Sledge::Tracing::Enabled
	    ? Sledge::Tracing->in_span('Sledge session load', {}, sub { $self->construct_session })
	    : $self->construct_session;
    }
    $self->authorizer->authorize($self);
    $self->charset->convert_param($self);
    $self->load_template($page);
    $self->load_fillin_form if $self->is_post_request;
}

sub output_content {
    my $self = shift;
    $self->r->content_type($self->charset->content_type); # set
    my $content = $Sledge::Tracing::Enabled
	? Sledge::Tracing->in_span('Sledge render', {
	    'sledge.template' => $self->tmpl ? $self->tmpl->{_options}->{filename} : undef,
	}, sub { $self->make_content })
	: $self->make_content;
    $self->set_content_length(length $content);
    $self->send_http_header;
    $self->r->print($content);
    $self->invoke_hook('AFTER_OUTPUT');
    $self->finished(1);
}

sub send_http_header {
    my $self = shift;
    # Session managers that store the session in a cookie write it out before the headers are sent
    my $manager = $self->manager;
    if ($manager && $self->session && $manager->can('finalize_session')) {
	$manager->finalize_session($self, $self->session);
    }
    $self->r->send_http_header(@_);
}

sub set_content_length {
    my($self, $length) = @_;
    $self->r->header_out('Content-Length' => $length);
}

sub construct_session {
    my $self = shift;
    my $session = $self->manager->get_session($self);
    $self->session($session);
    $self->manager->set_session($self, $session) if $session->is_fresh;
}

sub load_template {
    my($self, $page) = @_;
    my $file = $self->guess_filename($page);
    return $self->template_not_found($page, $file) unless -e $file;
    if ($self->tmpl) {
	$self->tmpl->set_option(filename => $file);
    } else {
	$self->tmpl($self->create_template($file));
    }
}

sub template_not_found {
    my($self, $page, $file) = @_;
    $self->tmpl($self->create_template($file));
}

sub guess_filename {
    my($self, $page) = @_;

    # foo     => $TMPL_PATH/$DIR/foo.html
    # /foo    => $TMPL_PATH/foo.html
    # foo.txt => $TMPL_PATH/$DIR/foo.txt
    my $dir = ($page =~ s,^/,,) ? '' : $self->tmpl_dirname . '/';
    my $suf = $page =~ /\./ ? '' : '.html';
    my $path = sprintf '%s/%s%s%s', $self->create_config->tmpl_path, $dir, $page, $suf;
    return File::Spec->canonpath($path);
}

sub create_template {
    my($self, $file) = @_;
    return Sledge::Template->new($file, $self);
}

sub load_fillin_form {
    my $self = shift;
    $self->fillin_form(Sledge::FillInForm->new($self));
}

sub is_post_request {
    my $self = shift;
    return $self->r->method eq 'POST';
}

sub make_content {
    my $self = shift;
    # template output, then fillin forms
    my $output = $self->tmpl->output;

    my $send = $self->fillin_form
	? $self->fillin_form->fillin($output, $self) : $output;
    my($content) = $self->charset->output_filter($send);

    for my $filter (@{$self->{filters}}) {
	$content = $filter->($self, $content);
    }
    return $content;
}

sub add_filter {
    my($self, $sub) = @_;
    unless (ref($sub) eq 'CODE') {
	require Carp;
	Carp::croak("add_filter() needs coderef");
    }
    push @{$self->{filters}}, $sub;
}

sub redirect {
    my($self, $url, $scheme) = @_;
    unless ($self->finished) {
	my $uri = $self->make_absolute_url($url, $scheme);
	$self->r->header_out(Location => $uri->as_string);
	$self->r->status(REDIRECT);
	$self->send_http_header;
	$self->finished(1);
    }
}

sub make_absolute_url {
    my($self, $url, $scheme) = @_;
    return URI->new_abs($url, $self->current_url($scheme));
}

sub current_url {
    my($self, $scheme) = @_;
    $scheme ||= $ENV{HTTPS} ? 'https' : 'http';
    my $url = sprintf '%s://%s%s', $scheme, $self->r->header_in('Host'), $self->r->uri;
    $url .= '?' . $self->r->args if $self->r->args;
    return $url;
}

sub _destroy_me {
    my $self = shift;
    # paranoia: guard against cyclic reference
    delete $self->{$_} for keys %$self;
    # don't use me after dispatch()
    bless $self, 'Sledge::Pages::LivingDead';
}

package Sledge::Pages::LivingDead;
sub AUTOLOAD { }

1;
