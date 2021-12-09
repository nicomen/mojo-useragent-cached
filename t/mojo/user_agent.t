use Mojo::Base -strict;

BEGIN {
  $ENV{MOJO_NO_NNR}  = $ENV{MOJO_NO_SOCKS} = $ENV{MOJO_NO_TLS} = 1;
  $ENV{MOJO_REACTOR} = 'Mojo::Reactor::Poll';
}

use Test::More;
use Mojo::IOLoop;
use Mojo::Message::Request;
use Mojo::Promise;
use Mojo::Server::Daemon;
use Mojo::UserAgent::Cached;
use Mojo::UserAgent::Server;
use Mojo::Util qw(gzip);
use Mojolicious::Lite;

# Silence
my $level = $Mojolicious::VERSION >= 9.20 ? 'trace' : 'debug';
app->log->level($level)->unsubscribe('message');

get '/' => {text => 'works!'};

get '/huge' => {text => 'x' x 262144};

my $timeout = undef;
get '/timeout' => sub {
  my $c = shift;
  $c->inactivity_timeout($c->param('timeout'));
  $c->on(finish => sub { $timeout = 1 });
};

get '/no_length' => sub {
  my $c = shift;
  $c->finish('works too!');
  $c->rendered(200);
};

get '/no_content' => {text => 'fail!', status => 204};

get '/echo' => sub {
  my $c          = shift;
  my $compressed = gzip $c->req->body;
  $c->res->headers->content_encoding($c->req->headers->accept_encoding);
  $c->render(data => $compressed);
};

post '/echo' => sub {
  my $c = shift;
  $c->render(data => $c->req->body);
};

any '/method' => {inline => '<%= $c->req->method =%>'};

get '/one' => sub {
  my $c = shift;

  $c->res->version('1.0');
  if (my $connection = $c->param('connection')) {
    $c->res->headers->connection($connection);
  }

  $c->render(text => 'One!');
};

get '/redirect_close' => sub {
  my $c = shift;
  $c->res->headers->connection('close');
  $c->res->headers->location($c->url_for('/')->to_abs);
  $c->rendered(302);
  $c->res->fix_headers->headers->remove('Content-Length');
};

# Max redirects
{
  local $ENV{MOJO_MAX_REDIRECTS} = 25;
  is(Mojo::UserAgent::Cached->new->max_redirects, 25, 'right value');
  $ENV{MOJO_MAX_REDIRECTS} = 0;
  is(Mojo::UserAgent::Cached->new->max_redirects, 0, 'right value');
}

# Timeouts
{
  is(Mojo::UserAgent::Cached->new->connect_timeout, 10, 'right value');
  local $ENV{MOJO_CONNECT_TIMEOUT} = 25;
  is(Mojo::UserAgent::Cached->new->connect_timeout,    25, 'right value');
  is(Mojo::UserAgent::Cached->new->inactivity_timeout, 20, 'right value');
  local $ENV{MOJO_INACTIVITY_TIMEOUT} = 25;
  is(Mojo::UserAgent::Cached->new->inactivity_timeout, 25, 'right value');
  $ENV{MOJO_INACTIVITY_TIMEOUT} = 0;
  is(Mojo::UserAgent::Cached->new->inactivity_timeout, 0, 'right value');
  is(Mojo::UserAgent::Cached->new->request_timeout,    0, 'right value');
  local $ENV{MOJO_REQUEST_TIMEOUT} = 25;
  is(Mojo::UserAgent::Cached->new->request_timeout, 25, 'right value');
  $ENV{MOJO_REQUEST_TIMEOUT} = 0;
  is(Mojo::UserAgent::Cached->new->request_timeout, 0, 'right value');
}

# Default application
is(Mojo::UserAgent::Server->app,      app, 'applications are equal');
is(Mojo::UserAgent::Cached->new->server->app, app, 'applications are equal');
Mojo::UserAgent::Server->app(app);
is(Mojo::UserAgent::Server->app, app, 'applications are equal');
my $dummy = Mojolicious::Lite->new;
isnt(Mojo::UserAgent::Cached->new->server->app($dummy)->app, app, 'applications are not equal');
is(Mojo::UserAgent::Server->app, app, 'applications are still equal');
Mojo::UserAgent::Server->app($dummy);
isnt(Mojo::UserAgent::Server->app, app, 'applications are not equal');
is(Mojo::UserAgent::Server->app, $dummy, 'application are equal');
Mojo::UserAgent::Server->app(app);
is(Mojo::UserAgent::Server->app, app, 'applications are equal again');

# Clean up non-blocking requests
my $ua  = Mojo::UserAgent::Cached->new;
my $get = my $post = '';
$ua->get('/' => sub { $get = pop->error });
$ua->post('/' => sub { $post = pop->error });
undef $ua;
is $get->{message},  'Premature connection close', 'right error';
is $post->{message}, 'Premature connection close', 'right error';

# The poll reactor stops when there are no events being watched anymore
my $time = time;
Mojo::IOLoop->start;
ok time < ($time + 10), 'stopped automatically';

# Blocking and non-blocking
$ua = Mojo::UserAgent::Cached->new;
my ($success, $code, $body);
$ua->get(
  '/' => sub {
    my ($ua, $tx) = @_;
    $success = !$tx->error;
    $code    = $tx->res->code;
    $body    = $tx->res->body;
    Mojo::IOLoop->stop;
  }
);
is $ua->get('/')->res->code, 200, 'right status';
Mojo::IOLoop->start;
ok $success, 'successful';
is $code,    200,      'right status';
is $body,    'works!', 'right content';

# Promises
my @results;
my $p1 = $ua->get_p('/');
my $p2 = $ua->get_p('/');
Mojo::Promise->all($p1, $p2)->then(sub {
  my ($first, $second) = @_;
  push @results, $first, $second;
})->wait;
ok !$results[0][0]->error, 'no error';
is $results[0][0]->res->code, 200,      'right status';
is $results[0][0]->res->body, 'works!', 'right content';
ok !$results[1][0]->error, 'no error';
is $results[1][0]->res->code, 200,      'right status';
is $results[1][0]->res->body, 'works!', 'right content';

# Promises (shortcut methods)
my $result;
$ua->delete_p('/method')->then(sub { $result = shift->res->body })->wait;
is $result, 'DELETE', 'right result';
$ua->get_p('/method')->then(sub { $result = shift->res->body })->wait;
is $result, 'GET', 'right result';
$ua->head_p('/method')->then(sub { $result = shift->res->body })->wait;
is $result, '', 'no result';
$ua->options_p('/method')->then(sub { $result = shift->res->body })->wait;
is $result, 'OPTIONS', 'right result';
$ua->patch_p('/method')->then(sub { $result = shift->res->body })->wait;
is $result, 'PATCH', 'right result';
$ua->post_p('/method')->then(sub { $result = shift->res->body })->wait;
is $result, 'POST', 'right result';
$ua->put_p('/method')->then(sub { $result = shift->res->body })->wait;
is $result, 'PUT', 'right result';
$ua->start_p($ua->build_tx(TEST => '/method'))->then(sub { $result = shift->res->body })->wait;
is $result, 'TEST', 'right result';

# No timeout
$ua = Mojo::UserAgent::Cached->new(inactivity_timeout => 0);
my $tx = $ua->get('/');
ok $tx->keep_alive, 'keep connection alive';
is $tx->res->code, 200,      'right status';
is $tx->res->body, 'works!', 'right content';
$tx = $ua->get('/');
ok $tx->kept_alive, 'kept connection alive';
ok $tx->keep_alive, 'keep connection alive';
is $tx->res->code, 200,      'right status';
is $tx->res->body, 'works!', 'right content';

# SOCKS proxy request without SOCKS support
$ua = Mojo::UserAgent::Cached->new;
$tx = $ua->build_tx(GET => '/');
$tx->req->proxy($ua->server->url->scheme('socks'));
$tx = $ua->start($tx);
like $tx->error->{message}, qr/IO::Socket::Socks/, 'right error';
ok !Mojo::IOLoop::Client->can_socks, 'no SOCKS5 support';

# HTTPS request without TLS support
$ua = Mojo::UserAgent::Cached->new;
$tx = $ua->get($ua->server->url->scheme('https'));
like $tx->error->{message}, qr/IO::Socket::SSL/, 'right error';
ok !Mojo::IOLoop::TLS->can_tls, 'no TLS support';

# Promises (rejected)
my $error;
$ua->get_p($ua->server->url->scheme('https'))->catch(sub { $error = shift })->wait;
like $error, qr/IO::Socket::SSL/, 'right error';

# No non-blocking name resolution
ok !Mojo::IOLoop::Client->can_nnr, 'no non-blocking name resolution support';

# Blocking
$tx = $ua->get('/');
ok !$tx->error,      'no error';
ok !$tx->kept_alive, 'kept connection not alive';
is $tx->res->version, '1.1', 'right version';
is $tx->res->code,    200,   'right status';
ok !$tx->res->headers->connection, 'no "Connection" value';
is $tx->res->max_message_size, 2147483648, 'right value';
is $tx->res->body,             'works!',   'right content';

# Again
$tx = $ua->get('/');
ok !$tx->error, 'no error';
ok $tx->kept_alive, 'kept connection alive';
is $tx->res->version, '1.1', 'right version';
is $tx->res->code,    200,   'right status';
ok !$tx->res->headers->connection, 'no "Connection" value';
is $tx->res->body, 'works!', 'right content';
$tx = $ua->max_response_size(0)->get('/');
ok !$tx->error, 'no error';
is $tx->res->version, '1.1', 'right version';
is $tx->res->code,    200,   'right status';
ok !$tx->res->headers->connection, 'no "Connection" value';
is $tx->res->max_message_size, 0,        'right value';
is $tx->res->body,             'works!', 'right content';

# Unsupported protocol
$tx = $ua->request_timeout(3600)->get('htttp://example.com');
is $tx->error->{message}, 'Unsupported protocol: htttp', 'right error';
eval { $tx->result };
like $@, qr/Unsupported protocol: htttp/, 'right error';

# Shortcuts for common request methods
is $ua->delete('/method')->res->body,  'DELETE',  'right content';
is $ua->get('/method')->res->body,     'GET',     'right content';
is $ua->head('/method')->res->body,    '',        'no content';
is $ua->options('/method')->res->body, 'OPTIONS', 'right method';
is $ua->patch('/method')->res->body,   'PATCH',   'right method';
is $ua->post('/method')->res->body,    'POST',    'right method';
is $ua->put('/method')->res->body,     'PUT',     'right method';

# No keep-alive
$tx = $ua->get('/one?connection=test');
ok !$tx->error,      'no error';
ok !$tx->keep_alive, 'connection will not be kept alive';
is $tx->res->version, '1.0', 'right version';
is $tx->res->code,    200,   'right status';
is $tx->res->headers->connection, 'test', 'right "Connection" value';
is $tx->res->body, 'One!', 'right content';
$tx = $ua->get('/one?connection=test');
ok !$tx->error,      'no error';
ok !$tx->kept_alive, 'kept connection not alive';
ok !$tx->keep_alive, 'connection will not be kept alive';
is $tx->res->version, '1.0', 'right version';
is $tx->res->code,    200,   'right status';
is $tx->res->headers->connection, 'test', 'right "Connection" value';
is $tx->res->body, 'One!', 'right content';
$tx = $ua->get('/one');
ok !$tx->error,      'no error';
ok !$tx->kept_alive, 'kept connection not alive';
ok !$tx->keep_alive, 'connection will not be kept alive';
is $tx->res->version, '1.0', 'right version';
is $tx->res->code,    200,   'right status';
ok !$tx->res->headers->connection, 'no "Connection" value';
is $tx->res->body, 'One!', 'right content';

# Error in callback
Mojo::IOLoop->singleton->reactor->unsubscribe('error');
my $err;
Mojo::IOLoop->singleton->reactor->once(error => sub { $err .= pop; Mojo::IOLoop->stop });
app->ua->get('/' => sub { die 'error event works' });
Mojo::IOLoop->start;
like $err, qr/error event works/, 'right error';

# Events
my ($finished_req, $finished_tx, $finished_res);
$tx = $ua->build_tx(GET => '/does_not_exist');
ok !$tx->is_finished, 'transaction is not finished';
$ua->once(
  prepare => sub {
    my ($ua, $tx) = @_;
    $tx->req->url->path('/');
  }
);
$ua->once(
  start => sub {
    my ($ua, $tx) = @_;
    $tx->req->on(finish => sub { $finished_req++ });
    $tx->on(finish => sub { $finished_tx++ });
    $tx->res->on(finish => sub { $finished_res++ });
  }
);
$tx = $ua->start($tx);
ok !$tx->error, 'no error';
is $finished_req, 1, 'finish event has been emitted once';
is $finished_tx,  1, 'finish event has been emitted once';
is $finished_res, 1, 'finish event has been emitted once';
ok $tx->req->is_finished, 'request is finished';
ok $tx->is_finished, 'transaction is finished';
ok $tx->res->is_finished, 'response is finished';
is $tx->res->code,        200,      'right status';
is $tx->res->body,        'works!', 'right content';

# Missing Content-Length header
($finished_req, $finished_tx, $finished_res) = ();
$tx = $ua->build_tx(GET => '/no_length');
ok !$tx->is_finished, 'transaction is not finished';
$ua->once(
  start => sub {
    my ($ua, $tx) = @_;
    $tx->req->on(finish => sub { $finished_req++ });
    $tx->on(finish => sub { $finished_tx++ });
    $tx->res->on(finish => sub { $finished_res++ });
  }
);
$tx = $ua->start($tx);
ok !$tx->error, 'no error';
is $finished_req, 1, 'finish event has been emitted once';
is $finished_tx,  1, 'finish event has been emitted once';
is $finished_res, 1, 'finish event has been emitted once';
ok $tx->req->is_finished, 'request is finished';
ok $tx->is_finished, 'transaction is finished';
ok $tx->res->is_finished, 'response is finished';
ok !$tx->error, 'no error';
ok $tx->kept_alive, 'kept connection alive';
ok !$tx->keep_alive, 'keep connection not alive';
is $tx->res->code, 200,          'right status';
is $tx->res->body, 'works too!', 'right content';

# 204 No Content
$tx = $ua->get('/no_content');
ok !$tx->error,      'no error';
ok !$tx->kept_alive, 'kept connection not alive';
ok $tx->keep_alive, 'keep connection alive';
is $tx->res->code, 204, 'right status';
ok $tx->is_empty, 'transaction is empty';
is $tx->res->body, '', 'no content';

# Connection was kept alive
$tx = $ua->head('/huge');
ok !$tx->error, 'no error';
ok $tx->kept_alive, 'kept connection alive';
is $tx->res->code, 200, 'right status';
is $tx->res->headers->content_length, 262144, 'right "Content-Length" value';
ok $tx->is_empty, 'transaction is empty';
is $tx->res->body, '', 'no content';
$tx = $ua->get('/huge');
ok !$tx->error, 'no error';
ok $tx->kept_alive, 'kept connection alive';
is $tx->res->code, 200, 'right status';
is $tx->res->headers->content_length, 262144, 'right "Content-Length" value';
ok !$tx->is_empty, 'transaction is not empty';
is $tx->res->body, 'x' x 262144, 'right content';

# Non-blocking form
($success, $code, $body) = ();
$ua->post(
  '/echo' => form => {hello => 'world'} => sub {
    my ($ua, $tx) = @_;
    $success = !$tx->error;
    $code    = $tx->res->code;
    $body    = $tx->res->body;
    Mojo::IOLoop->stop;
  }
);
Mojo::IOLoop->start;
ok $success, 'successful';
is $code,    200,           'right status';
is $body,    'hello=world', 'right content';

# Non-blocking JSON
($success, $code, $body) = ();
$ua->post(
  '/echo' => json => {hello => 'world'} => sub {
    my ($ua, $tx) = @_;
    $success = !$tx->error;
    $code    = $tx->res->code;
    $body    = $tx->res->body;
    Mojo::IOLoop->stop;
  }
);
Mojo::IOLoop->start;
ok $success, 'successful';
is $code,    200,                 'right status';
is $body,    '{"hello":"world"}', 'right content';

# Built-in web server times out
$ua = Mojo::UserAgent::Cached->new(ioloop => Mojo::IOLoop->singleton);
my $log = '';
my $msg = app->log->on(message => sub { $log .= pop });
$tx = $ua->get('/timeout?timeout=0.25');
app->log->unsubscribe(message => $msg);
is $tx->error->{message}, 'Premature connection close', 'right error';
is $timeout, 1,                      'finish event has been emitted';
like $log,   qr/Inactivity timeout/, 'right log message';
eval { $tx->result };
like $@, qr/Premature connection close/, 'right error';

# Client times out
$ua->once(
  start => sub {
    my ($ua, $tx) = @_;
    $tx->on(
      connection => sub {
        my ($tx, $connection) = @_;
        Mojo::IOLoop->stream($connection)->timeout(0.25);
      }
    );
  }
);
$tx = $ua->get('/timeout?timeout=5');
is $tx->error->{message}, 'Inactivity timeout', 'right error';
eval { $tx->result };
like $@, qr/Inactivity timeout/, 'right error';

# Keep alive connection times out
my $id;
$ua->get(
  '/' => sub {
    my ($ua, $tx) = @_;
    Mojo::IOLoop->timer(0.5 => sub { Mojo::IOLoop->stop });
    $id = $tx->connection;
    Mojo::IOLoop->stream($id)->timeout(0.25);
  }
);
Mojo::IOLoop->start;
ok !Mojo::IOLoop->stream($id), 'connection timed out';

# Request timeout with keep-alive
$ua->request_timeout(3600);
ok !$ua->get('/')->error, 'priming the keep-alive connection';
$ua->request_timeout(0.01);
$tx = $ua->get('/timeout?timeout=5');
is $tx->error->{message}, 'Request timeout', 'right error message';
is $tx->error->{code},    undef,             'no status';
$ua->request_timeout(0);

# Response exceeding message size limit
$ua->once(
  start => sub {
    my ($ua, $tx) = @_;
    $tx->res->max_message_size(12);
  }
);
$tx = $ua->get('/echo' => 'Hello World!');
is $tx->error->{message}, 'Maximum message size exceeded', 'right error';
is $tx->error->{code},    undef,                           'no status';
ok $tx->res->is_limit_exceeded, 'limit is exceeded';

# 404 response
$tx = $ua->get('/does_not_exist');
ok $tx->result, 'has a result';
is $tx->result->code, 404, 'right status';
ok !$tx->kept_alive, 'kept connection not alive';
ok $tx->keep_alive, 'keep connection alive';
is $tx->error->{message}, 'Not Found', 'right error';
is $tx->error->{code},    404,         'right status';
$tx = $ua->get('/does_not_exist');
ok $tx->kept_alive, 'kept connection alive';
ok $tx->keep_alive, 'keep connection alive';
is $tx->error->{message}, 'Not Found', 'right error';
is $tx->error->{code},    404,         'right status';

# Redirect with connection close
$tx = $ua->max_redirects(3)->get('/redirect_close');
ok !$tx->error,      'no error';
ok !$tx->kept_alive, 'kept connection not alive';
is $tx->res->version, '1.1',    'right version';
is $tx->res->code,    200,      'right status';
is $tx->res->body,    'works!', 'right content';
$ua->max_redirects(0);

# Compressed response
$tx = $ua->build_tx(GET => '/echo' => 'Hello GZip!');
$tx = $ua->start($ua->build_tx(GET => '/echo' => 'Hello GZip!'));
ok !$tx->error, 'no error';
ok $tx->result, 'has a result';
is $tx->result->code, 200, 'right status';
is $tx->res->code,    200, 'right status';
is $tx->res->headers->content_encoding, undef, 'no "Content-Encoding" value';
is $tx->res->body, 'Hello GZip!', 'right content';
$tx = $ua->build_tx(GET => '/echo' => 'Hello GZip!');
$tx->res->content->auto_decompress(0);
$tx = $ua->start($tx);
ok !$tx->error, 'no error';
is $tx->res->code, 200, 'right status';
is $tx->res->headers->content_encoding, 'gzip', 'right "Content-Encoding" value';
isnt $tx->res->body, 'Hello GZip!', 'different content';

# Keep-alive timeout in between requests
my $daemon = Mojo::Server::Daemon->new(
  app                => app,
  ioloop             => $ua->ioloop,
  keep_alive_timeout => 0.5,
  listen             => ['http://127.0.0.1'],
  silent             => 1
);
my $port = $daemon->start->ports->[0];
$tx = $ua->get("http://127.0.0.1:$port");
ok $tx->keep_alive, 'keep connection alive';
is $tx->res->code, 200,      'right status';
is $tx->res->body, 'works!', 'right content';
Mojo::Promise->new->ioloop($ua->ioloop)->timer(1)->wait;
$tx = $ua->get("http://127.0.0.1:$port");
ok !$tx->kept_alive, 'kept connection not alive';
ok $tx->keep_alive, 'keep connection alive';
is $tx->res->code, 200,      'right status';
is $tx->res->body, 'works!', 'right content';

subtest 'Fork-safety' => sub {
  my $tx = $ua->get('/');
  ok $tx->keep_alive, 'keep connection alive';
  is $tx->res->body, 'works!', 'right content';
  my $last = $tx->connection;
  my $port = $ua->server->url->port;
  $tx = $ua->get('/');
  is $tx->res->body, 'works!', 'right content';
  is $tx->connection, $last, 'same connection';
  is $ua->server->url->port, $port, 'same port';
  {
    local $$ = -23;
    my $tx = $ua->get('/');
    ok !$tx->kept_alive, 'kept connection not alive';
    ok $tx->keep_alive, 'keep connection alive';
    is $tx->res->body, 'works!', 'right content';
    isnt $tx->connection, $last, 'new connection';
    isnt $ua->server->url->port, $port, 'new port';
    my $port2 = $ua->server->url->port;
    my $last2 = $tx->connection;
    {
      local $$ = -24;
      my $tx = $ua->get('/');
      ok !$tx->kept_alive, 'kept connection not alive';
      ok $tx->keep_alive, 'keep connection alive';
      is $tx->res->body, 'works!', 'right content';
      isnt $tx->connection, $last,  'new connection';
      isnt $tx->connection, $last2, 'new connection';
      isnt $ua->server->url->port, $port,  'new port';
      isnt $ua->server->url->port, $port2, 'new port';
    }
  }
};

# Introspect
my $req = my $res = '';
my @num;
my $start = $ua->on(
  start => sub {
    my ($ua, $tx) = @_;
    $tx->on(
      connection => sub {
        my ($tx, $connection) = @_;
        my $stream = Mojo::IOLoop->stream($connection);
        push @num, $stream->bytes_read, $stream->bytes_written;
        my $read = $stream->on(
          read => sub {
            my ($stream, $chunk) = @_;
            $res .= $chunk;
          }
        );
        my $write = $stream->on(
          write => sub {
            my ($stream, $chunk) = @_;
            $req .= $chunk;
          }
        );
        $tx->on(
          finish => sub {
            push @num, $stream->bytes_read, $stream->bytes_written;
            $stream->unsubscribe(read  => $read);
            $stream->unsubscribe(write => $write);
          }
        );
      }
    );
  }
);
$tx = $ua->get('/', 'whatever');
ok !$tx->error, 'no error';
is $tx->res->code, 200,      'right status';
is $tx->res->body, 'works!', 'right content';
is scalar @{Mojo::IOLoop->stream($tx->connection)->subscribers('write')}, 0, 'unsubscribed successfully';
is scalar @{Mojo::IOLoop->stream($tx->connection)->subscribers('read')},  1, 'unsubscribed successfully';
like $req, qr!^GET / .*whatever$!s,      'right request';
like $res, qr|^HTTP/.*200 OK.*works!$|s, 'right response';
is_deeply \@num, [0, 0, length $res, length $req], 'right structure';
$ua->unsubscribe(start => $start);
ok !$ua->has_subscribers('start'), 'unsubscribed successfully';

# Stream with drain callback and compressed response
$tx = $ua->build_tx(GET => '/echo');
my $i = 0;
my ($stream, $drain);
$drain = sub {
  my $content = shift;
  return $ua->ioloop->timer(
    0.25 => sub {
      $content->write_chunk('');
      $tx->resume;
      $stream += @{Mojo::IOLoop->stream($tx->connection)->subscribers('drain')};
    }
  ) if $i >= 10;
  $content->write_chunk($i++, $drain);
  $tx->resume;
  return unless my $id = $tx->connection;
  $stream += @{Mojo::IOLoop->stream($id)->subscribers('drain')};
};
$tx->req->content->$drain;
$ua->start($tx);
ok !$tx->error, 'no error';
ok $tx->kept_alive, 'kept connection alive';
ok $tx->keep_alive, 'keep connection alive';
is $tx->res->code, 200,          'right status';
is $tx->res->body, '0123456789', 'right content';
is $stream, 1, 'no leaking subscribers';

# Upload progress
$ua = Mojo::UserAgent::Cached->new;
my $progress = {};
$ua->on(
  start => sub {
    my ($ua, $tx) = @_;
    $tx->req->on(
      progress => sub {
        my ($req, $state, $offset) = @_;
        $progress->{$state} = 1;
      }
    );
    $tx->req->on(finish => sub { $progress->{finish} = 1 });
  }
);
$tx = $ua->post('/echo' => 'Hello Mojo!');
ok !$tx->error, 'no error';
is $tx->res->code, 200,           'right status';
is $tx->res->body, 'Hello Mojo!', 'right content';
is_deeply $progress, {start_line => 1, headers => 1, body => 1, finish => 1}, 'right structure';

# Mixed blocking and non-blocking requests, with custom URL
$ua = Mojo::UserAgent->new(ioloop => Mojo::IOLoop->singleton);
$tx = $ua->get($ua->server->url);
ok !$tx->error,      'no error';
ok !$tx->kept_alive, 'kept connection not alive';
ok $tx->keep_alive, 'keep connection alive';
is $tx->res->code, 200,      'right status';
is $tx->res->body, 'works!', 'right content';
my @kept_alive;
$ua->get(
  $ua->server->nb_url => sub {
    my ($ua, $tx) = @_;
    push @kept_alive, $tx->kept_alive;
    $ua->get(
      '/' => sub {
        my ($ua, $tx) = @_;
        push @kept_alive, $tx->kept_alive;
        $ua->get(
          $ua->server->nb_url => sub {
            my ($ua, $tx) = @_;
            push @kept_alive, $tx->kept_alive;
            Mojo::IOLoop->stop;
          }
        );
      }
    );
  }
);
Mojo::IOLoop->start;
is_deeply \@kept_alive, [undef, 1, 1], 'connections kept alive';
$tx = $ua->get($ua->server->url);
ok !$tx->error, 'no error';
ok $tx->kept_alive, 'kept connection alive';
ok $tx->keep_alive, 'keep connection alive';
is $tx->res->code, 200,      'right status';
is $tx->res->body, 'works!', 'right content';

# Simple nested non-blocking requests with timers
@kept_alive = ();
$ua->get(
  '/' => sub {
    push @kept_alive, pop->kept_alive;
    Mojo::IOLoop->next_tick(sub {
      $ua->get(
        '/' => sub {
          push @kept_alive, pop->kept_alive;
          Mojo::IOLoop->next_tick(sub { Mojo::IOLoop->stop });
        }
      );
    });
  }
);
Mojo::IOLoop->start;
is_deeply \@kept_alive, [1, 1], 'connections kept alive';

# Unexpected 1xx responses
$req = Mojo::Message::Request->new;
$id  = Mojo::IOLoop->server(
  {address => '127.0.0.1'} => sub {
    my ($loop, $stream) = @_;
    $stream->on(
      read => sub {
        my ($stream, $chunk) = @_;
        $stream->write("HTTP/1.1 100 Continue\x0d\x0a"
            . "X-Foo: Bar\x0d\x0a\x0d\x0a"
            . "HTTP/1.1 101 Switching Protocols\x0d\x0a\x0d\x0a"
            . "HTTP/1.1 200 OK\x0d\x0a"
            . "Content-Length: 3\x0d\x0a\x0d\x0a" . 'Hi!')
          if $req->parse($chunk)->is_finished;
      }
    );
  }
);
$port = Mojo::IOLoop->acceptor($id)->port;
$tx   = $ua->build_tx(GET => "http://127.0.0.1:$port/");
my @unexpected;
$tx->on(unexpected => sub { push @unexpected, pop });
$tx = $ua->start($tx);
is $unexpected[0]->code, 100, 'right status';
is $unexpected[0]->headers->header('X-Foo'), 'Bar', 'right "X-Foo" value';
is $unexpected[1]->code, 101, 'right status';
ok !$tx->error, 'no error';
is $tx->res->code, 200,   'right status';
is $tx->res->body, 'Hi!', 'right content';

# Connection limit
$ua     = Mojo::UserAgent::Cached->new(max_connections => 2);
$result = undef;
my @txs = map { $ua->get_p('/') } 1 .. 5;
Mojo::Promise->all(@txs)->then(sub {
  $result = [grep {defined} map { Mojo::IOLoop->stream($_->connection) } map { $_->[0] } @_];
})->wait;
is scalar @$result, 2, 'two active connections';

done_testing();
