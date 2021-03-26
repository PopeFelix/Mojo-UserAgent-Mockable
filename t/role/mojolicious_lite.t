BEGIN { $ENV{MOJO_USERAGENT_RECORDER_DEBUG} = 0; }
use Mojolicious::Lite -signatures;
use Mojo::File qw(tempdir);
use Test::More;
use Test::Mojo;

my $called = 0;
my $bye = 0;
get '/' => sub ($c) { ++$called; $c->render(text => 'Hello') };
get '/bye' => sub ($c) { ++$bye; $c->render(text => 'Goodbye') };

my $temp = tempdir;
my $t = Test::Mojo->new;
$t->ua->with_roles('+Recorder')->request_normalizer(
  sub ($req, $recorded_req) {
    for ($req, $recorded_req) {
      $_->url->port(443);
    }
  }
);
note "Recording";
$t->ua->record_to($temp->child('test.json'));
$t->get_ok('/')->status_is(200)->content_is('Hello');
is $called, 1, 'recorded';

note "Switching to playback";
$t->ua->mode('playback');
$t->get_ok('/')->status_is(200)->content_is('Hello');
is $called, 1, 'played back';

note "Switching to passthrough";
$t->ua->passthrough;

$t->get_ok('/')->status_is(200)->content_is('Hello');
is $called, 2, 'passthrough';

note "Switching to record";
$t->ua->record_to($temp->child('again.json'));
$t->get_ok('/bye')->status_is(200)->content_is('Goodbye');
is $bye, 1, 'record';

$t->get_ok('/bye')->status_is(200)->content_is('Goodbye');
is $bye, 2, 'record';

note "Switching to playback";
$t->ua->mode('playback');
$t->get_ok('/bye')->status_is(200)->content_is('Goodbye');
is $bye, 2, 'played back';
$t->get_ok('/bye')->status_is(200)->content_is('Goodbye');
is $bye, 2, 'played back';
$t->get_ok('/bye')->status_is(200)->content_is('Goodbye');
is $bye, 2, 'played back';

done_testing;

app->start;
