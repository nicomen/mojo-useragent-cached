use Mojo::Base -strict;


BEGIN {
  use Mojo::File;
  $ENV{MUAC_CACHE_ROOT_DIR} = Mojo::File::tempdir();
  $ENV{MOJO_PROXY}   = 0;
  $ENV{MOJO_REACTOR} = 'Mojo::Reactor::Poll';
}

use Test::More;
use Mojo::IOLoop::TLS;

plan skip_all => 'set TEST_ONLINE to enable this test (developer only!)' unless $ENV{TEST_ONLINE} || $ENV{TEST_ALL};
plan skip_all => 'IO::Socket::SSL 2.009+ required for this test!'        unless Mojo::IOLoop::TLS->can_tls;
plan skip_all => 'Mozilla::CA required for this test!'                   unless eval { require Mozilla::CA; 1 };

use IO::Socket::INET;
use Mojo::IOLoop;
use Mojo::Transaction::HTTP;
use Mojo::UserAgent::Cached;
use Mojolicious::Lite;
use ojo;


get '/remote_address' => sub {
  my $c = shift;
  $c->render(text => $c->tx->remote_address);
};

my $loop = Mojo::IOLoop->singleton;
my $ua   = Mojo::UserAgent->new;

subtest 'Make sure user agents dont taint the ioloop' => sub {
  my ($id, $code);
  $ua->get(
    'http://metacpan.org' => sub {
      my ($ua, $tx) = @_;
      $id   = $tx->connection;
      $code = $tx->res->code;
      $loop->stop;
    }
  );
  $loop->start;
  $ua = undef;
  $loop->timer(0.25 => sub { shift->stop });
  $loop->start;
  ok !$loop->stream($id), 'loop not tainted';
  is $code, 301, 'right status';
};

$ua = Mojo::UserAgent::Cached->new;

subtest 'Local address' => sub {
  $ua->server->app(app);
  my $sock    = IO::Socket::INET->new(PeerAddr => 'mojolicious.org', PeerPort => 80);
  my $address = $sock->sockhost;
  isnt $address, '127.0.0.1', 'different address';
  $ua->max_connections(0)->socket_options->{LocalAddr} = '127.0.0.1';
  my $tx = $ua->get('/remote_address');
  ok !$ua->ioloop->stream($tx->connection), 'connection is not active';
  is $tx->res->body, '127.0.0.1', 'right address';
  $ua->socket_options->{LocalAddr} = $address;
  is $ua->get('/remote_address')->res->body, $address, 'right address';
};

$ua = Mojo::UserAgent::Cached->new;
my $port = Mojo::IOLoop::Server->generate_port;

subtest 'Connection refused' => sub {
  my $tx = $ua->build_tx(GET => "http://127.0.0.1:$port");
  $ua->start($tx);
  ok $tx->is_finished, 'transaction is finished';
  ok $tx->error,       'has error';
};

subtest 'Connection refused (IPv4)' => sub {
  my $tx = $ua->build_tx(GET => "http://127.0.0.1:$port");
  $ua->start($tx);
  ok $tx->is_finished, 'transaction is finished';
  ok $tx->error,       'has error';
};

subtest 'Connection refused (IPv6)' => sub {
  my $tx = $ua->build_tx(GET => "http://[::1]:$port");
  $ua->start($tx);
  ok $tx->is_finished, 'transaction is finished';
  ok $tx->error,       'has error';
};

subtest 'Host does not exist' => sub {
  my $tx = $ua->build_tx(GET => 'http://cdeabcdeffoobarnonexisting.com');
  $ua->start($tx);
  ok $tx->is_finished, 'transaction is finished';
  ok $tx->error,       'has error';
};

$ua = Mojo::UserAgent->new;

subtest 'Keep-alive' => sub {
  $ua->get('http://mojolicious.org' => sub { Mojo::IOLoop->singleton->stop });
  Mojo::IOLoop->singleton->start;
  my $kept_alive;
  $ua->get(
    'http://mojolicious.org' => sub {
      my ($ua, $tx) = @_;
      Mojo::IOLoop->singleton->stop;
      $kept_alive = $tx->kept_alive;
    }
  );
  Mojo::IOLoop->singleton->start;
  ok $kept_alive, 'connection was kept alive';
};

subtest 'Nested keep-alive' => sub {
  my @kept_alive;
  $ua->get(
    'http://mojolicious.org' => sub {
      my ($ua, $tx) = @_;
      push @kept_alive, $tx->kept_alive;
      $ua->get(
        'http://mojolicious.org' => sub {
          my ($ua, $tx) = @_;
          push @kept_alive, $tx->kept_alive;
          $ua->get(
            'http://mojolicious.org' => sub {
              my ($ua, $tx) = @_;
              push @kept_alive, $tx->kept_alive;
              Mojo::IOLoop->singleton->stop;
            }
          );
        }
      );
    }
  );
  Mojo::IOLoop->singleton->start;
  is_deeply \@kept_alive, [1, 1, 1], 'connections kept alive';
};

$ua = Mojo::UserAgent::Cached->new;

subtest 'Custom non-keep-alive request' => sub {
  my $tx = Mojo::Transaction::HTTP->new;
  $tx->req->method('GET');
  $tx->req->url->parse('http://metacpan.org?connection-close');
  $tx->req->headers->connection('close');
  $ua->start($tx);
use Data::Dumper;
  warn Dumper($tx);
  ok $tx->is_finished, 'transaction is finished';
  is $tx->res->code, 301, 'right status';
  like $tx->res->headers->connection, qr/close/i, 'right "Connection" header';
};

subtest 'One-liner' => sub {
  is g('mojolicious.org')->code,          200, 'right status';
  is h('mojolicious.org')->code,          200, 'right status';
  is h('mojolicious.org')->body,          '',  'no content';
  is p('mojolicious.org/lalalala')->code, 404, 'right status';
  is g('http://mojolicious.org')->code,   200, 'right status';
  my $res = p('https://metacpan.org/search' => form => {q => 'mojolicious'});
  like $res->body, qr/Mojolicious/, 'right content';
  is $res->code,   200,             'right status';
};

subtest 'Simple request' => sub {
  my $ua = Mojo::UserAgent::Cached->new( max_redirects => 0 );
  my $tx = $ua->get('http://metacpan.org');
  is $tx->req->method, 'GET',                 'right method';
  is $tx->req->url,    'http://metacpan.org', 'right url';
  is $tx->res->code,   301,                   'right status';
};

$ua = Mojo::UserAgent->new;

subtest 'Simple keep-alive requests' => sub {
  my $tx = $ua->get('https://www.wikipedia.org');
  is $tx->req->method, 'GET',                       'right method';
  is $tx->req->url,    'https://www.wikipedia.org', 'right url';
  is $tx->req->body,   '',                          'no content';
  is $tx->res->code,   200,                         'right status';
  ok $tx->keep_alive, 'connection will be kept alive';
  ok !$tx->kept_alive, 'connection was not kept alive';
  $tx = $ua->get('https://www.wikipedia.org');
  is $tx->req->method, 'GET',                       'right method';
  is $tx->req->url,    'https://www.wikipedia.org', 'right url';
  is $tx->res->code,   200,                         'right status';
  ok $tx->keep_alive, 'connection will be kept alive';
  ok $tx->kept_alive, 'connection was kept alive';
  $tx = $ua->get('https://www.wikipedia.org');
  is $tx->req->method, 'GET',                       'right method';
  is $tx->req->url,    'https://www.wikipedia.org', 'right url';
  is $tx->res->code,   200,                         'right status';
  ok $tx->keep_alive, 'connection will be kept alive';
  ok $tx->kept_alive, 'connection was kept alive';
};

subtest 'Simple HTTPS request' => sub {
  my $tx = $ua->get('https://metacpan.org');
  is $tx->req->method, 'GET',                  'right method';
  is $tx->req->url,    'https://metacpan.org', 'right url';
  is $tx->res->code,   200,                    'right status';
};

$ua = Mojo::UserAgent->new;

subtest 'Simple keep-alive form POST' => sub {
  my $tx = $ua->post('https://metacpan.org/search' => form => {q => 'mojolicious'});
  is $tx->req->method, 'POST',                        'right method';
  is $tx->req->url,    'https://metacpan.org/search', 'right url';
  is $tx->req->headers->content_length, 13, 'right content length';
  is $tx->req->body,   'q=mojolicious', 'right content';
  like $tx->res->body, qr/Mojolicious/, 'right content';
  is $tx->res->code,   200,             'right status';
  ok $tx->keep_alive, 'connection will be kept alive';
  $tx = $ua->post('https://metacpan.org/search' => form => {q => 'mojolicious'});
  is $tx->req->method, 'POST',                        'right method';
  is $tx->req->url,    'https://metacpan.org/search', 'right url';
  is $tx->req->headers->content_length, 13, 'right content length';
  is $tx->req->body,   'q=mojolicious', 'right content';
  like $tx->res->body, qr/Mojolicious/, 'right content';
  is $tx->res->code,   200,             'right status';
  ok $tx->kept_alive,    'connection was kept alive';
  ok $tx->local_address, 'has local address';
  ok $tx->local_port > 0, 'has local port';
  ok $tx->original_remote_address, 'has original remote address';
  ok $tx->remote_address,          'has remote address';
  ok $tx->remote_port > 0, 'has remote port';
};


$ua = Mojo::UserAgent::Cached->new;

subtest 'Simple request with redirect' => sub {
  $ua->max_redirects(3);
  my $tx = $ua->get('http://wikipedia.org/wiki/Perl');
  $ua->max_redirects(0);
  is $tx->req->method, 'GET',                                'right method';
  is $tx->req->url,    'https://en.wikipedia.org/wiki/Perl', 'right url';
  is $tx->res->code,   200,                                  'right status';
  is $tx->previous->req->method, 'GET',                                 'right method';
  is $tx->previous->req->url,    'https://www.wikipedia.org/wiki/Perl', 'right url';
  is $tx->previous->res->code,   301,                                   'right status';
  is $tx->redirects->[-1]->req->method, 'GET',                                 'right method';
  is $tx->redirects->[-1]->req->url,    'https://www.wikipedia.org/wiki/Perl', 'right url';
  is $tx->redirects->[-1]->res->code,   301,                                   'right status';
};

# Would return local file
#subtest 'Connect timeout (non-routable address)' => sub {
#  my $tx = $ua->connect_timeout(0.5)->get('192.0.2.1');
#  ok $tx->is_finished, 'transaction is finished';
#  is $tx->error->{message}, 'Connect timeout', 'right error';
#  $ua->connect_timeout(3);
#};

done_testing();
