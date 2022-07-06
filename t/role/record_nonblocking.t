use Mojo::Base -strict;
use Mojo::File qw(tempdir);
use Mojo::UserAgent;
use Mojo::UserAgent::Mockable::Serializer;
use Test::More;
use Test::Mojo;

my $t = Test::Mojo->new;
my (@results, @transactions);
my @promises = (
  $t->ua->get_p(q{https://www.vam.ac.uk/api/json/museumobject/O1}),
  $t->ua->get_p(q{https://www.vam.ac.uk/api/json/museumobject/O1})
);
Mojo::Promise->all(@promises)->then(sub {
  @transactions = map { $_->[0] } @_;
  @results      = map { $_->res->json } @transactions;
})->catch(sub {
  plan skip_all => "Museum API not responing properly: $_[0]";
})->wait;

my $dir         = tempdir('record.XXXXX', TMPDIR => 1, CLEANUP => 1);
my $output_file = $dir->child('victoria_and_albert.json');

my $mock = Mojo::UserAgent->with_roles('+Recorder')->new;
$mock->record_to($output_file);

for (0 .. $#transactions) {
  my $index = $_;

  diag qq{Check result $index};
  $mock->get(
    $transactions[$_]->req->url->clone,
    sub {
      my ($ua, $tx) = @_;
      diag qq{Get URL $index};
      is_deeply $tx->res->json, $results[$index], qq{result $index matches that of stock Mojo UA (nonblocking)};
      Mojo::IOLoop->stop;
    }
  );
  Mojo::IOLoop->start unless Mojo::IOLoop->is_running;
}
$mock->save;

ok -e $output_file, 'Output file exists';
isnt $output_file->stat->size, 0, 'Output file has nonzero size';
my @deserialized = Mojo::UserAgent::Mockable::Serializer->new->retrieve("$output_file");

is scalar @deserialized, scalar @transactions, 'Transaction count matches';
done_testing;
