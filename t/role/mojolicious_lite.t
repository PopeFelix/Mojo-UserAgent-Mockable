use Mojolicious::Lite;
use Mojo::File qw(tempdir);
use Test::More;
use Test::Mojo;

my $hello = 0;
my $bye   = 0;
get '/'    => sub { ++$hello; shift->render(text => 'Hello') };
get '/bye' => sub { ++$bye;   shift->render(text => 'Goodbye') };

my $temp = tempdir;
my $t    = Test::Mojo->new;
$t->ua->with_roles('+Recorder')->request_normalizer(sub {
  my ($req, $recorded_req) = @_;
  for ($req, $recorded_req) {
    $_->url->port(443);
  }
});

subtest "Recording" => sub {
  $t->ua->record_to($temp->child('test.json'));
  $t->get_ok('/')->status_is(200)->content_is('Hello');
  is $hello, 1, 'recorded';
};

subtest "Playback" => sub {
  $t->ua->mode('playback');
  $t->get_ok('/')->status_is(200)->content_is('Hello');
  is $hello, 1, 'played back';
};

subtest "Switching to passthrough" => sub {
  $t->ua->passthrough;

  $t->get_ok('/')->status_is(200)->content_is('Hello');
  is $hello, 2, 'passthrough';
};

subtest "Switching to record" => sub {
  $t->ua->record_to($temp->child('again.json'));
  $t->get_ok('/bye')->status_is(200)->content_is('Goodbye');
  is $bye, 1, 'record';

  $t->get_ok('/bye')->status_is(200)->content_is('Goodbye');
  is $bye, 2, 'record';
};

subtest "Switching to playback" => sub {
  $t->ua->mode('playback');
  $t->get_ok('/bye')->status_is(200)->content_is('Goodbye');
  is $bye, 2, 'played back';
  $t->get_ok('/bye')->status_is(200)->content_is('Goodbye');
  is $bye, 2, 'played back';
  $t->get_ok('/bye')->status_is(200)->content_is('Goodbye');
  is $bye, 2, 'played back';
};

done_testing;
