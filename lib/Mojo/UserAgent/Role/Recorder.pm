package Mojo::UserAgent::Role::Recorder;

use Mojo::Base -role;
use Mojo::File qw(path);
use Mojo::UserAgent::Mockable::Proxy;
use Mojo::UserAgent::Mockable::Serializer;
use Mojo::UserAgent::Mockable::Request::Compare;
use Mojolicious;
use Scalar::Util;

use constant DEBUG => !!$ENV{MOJO_USERAGENT_RECORDER_DEBUG};

has comparator => sub {
  Mojo::UserAgent::Mockable::Request::Compare->new(
    ignore_headers  => 'all',
    ignore_body     => $_[0]->ignore_body,
    ignore_userinfo => $_[0]->ignore_userinfo,
  );
};
has file               => sub { Mojo::File->new('.')->to_abs->child('t', 'fixtures', 'default.json') };
has ignore_body        => undef;
has ignore_headers     => sub { [] };
has ignore_userinfo    => undef;
has mode               => sub { $ENV{MOJO_USERAGENT_RECORDER_MODE} || 'passthrough' };
has request_normalizer => undef;
has serializer         => sub { Mojo::UserAgent::Mockable::Serializer->new };
has unrecognized       => 'exception';

around proxy => sub {
  my ($orig, $self, @args) = @_;
  return $self->$orig unless @args;
  return $self->$orig(Mojo::UserAgent::Mockable::Proxy->new) if $self->mode eq 'playback';
  return $self->$orig(@args);
};

around start => sub {
  my ($orig, $self, $tx, $cb) = (shift, shift, @_);
  $self->_init_callbacks->_init_routes->unsubscribe(start => $self->{playback_start})
    ->unsubscribe(start => $self->{record_start});
  if ($self->mode eq 'playback') {
    $self->_init_playback->on(start => $self->{playback_start});
  }
  elsif ($self->mode eq 'record') {
    $self->on(start => $self->{record_start});
  }
  $self->{non_blocking} = 1 if $cb;
  return $self->$orig(@_);
};

sub passthrough {
  return shift->mode('passthrough');
}

sub playback_from {
  my ($self, $path) = @_;
  return $self->mode('playback')->proxy(undef)->file(ref $path ? $path : Mojo::File->new($path));
}

sub record_to {
  my ($self, $path) = @_;
  return $self->mode('record')->file(ref $path ? $path : Mojo::File->new($path));
}

sub save {
  my $self = shift;
  my $path = shift || $self->file;
  if ($self->mode eq 'record') {
    $path->dirname->make_path;
    my $transactions = $self->{'recorded_transactions'};
    $self->serializer->store("$path", @{$transactions});
  }
  else {
    Carp::carp 'save() only works in record mode' if warnings::enabled;
  }
  return $self;
}

sub _init_callbacks {
  my $self = shift;
  return $self if $self->{record_start};

  Scalar::Util::weaken($self);

  $self->{playback_start} = sub {
    my ($ua, $tx) = @_;
    my $port        = $self->{non_blocking} ? $self->server->nb_url->port : $self->server->url->port;
    my $recorded_tx = shift @{$self->{recorded_transactions}};

    my ($this_req, $recorded_req) = $self->_normalized_req($tx, $recorded_tx);

    if ($self->comparator->compare($this_req, $recorded_req)) {
      $self->{current_txn} = $recorded_tx;

      $tx->req->url($tx->req->url->clone)->url->host('')->scheme('')->port($port);
    }
    else {
      unshift @{$self->{recorded_transactions}}, $recorded_tx;

      my $result = $self->comparator->compare_result;
      $self->{current_txn} = undef;
      if ($self->unrecognized eq 'exception') {
        Carp::croak qq{Unrecognized request: $result};
      }
      elsif ($self->unrecognized eq 'null') {
        $tx->req->headers->header('X-MUA-Mockable-Request-Recognized'      => 0);
        $tx->req->headers->header('X-MUA-Mockable-Request-Match-Exception' => $result);
        $tx->req->url->host('')->scheme('')->port($port);
      }
      elsif ($self->unrecognized eq 'fallback') {
        $tx->on(
          finish => sub {
            my $self = shift;
            $tx->req->headers->header('X-MUA-Mockable-Request-Recognized'      => 0);
            $tx->req->headers->header('X-MUA-Mockable-Request-Match-Exception' => $result);
          }
        );
      }
    }
  };

  $self->{record_start} = sub {
    my ($ua, $tx) = @_;
    if ($tx->req->proxy) {

      # HTTP CONNECT - used for proxy
      return if $tx->req->method eq 'CONNECT';

      # If the TX has a connection assigned, then the request is a copy of the request
      # that initiated the proxy connection
      return if $tx->connection;
    }

    $tx->once(
      finish => sub {
        my $tx = shift;
        push @{$self->{'recorded_transactions'}}, $tx;

        # 15: During global destruction the $tx object may no longer exist
        # so save now
        $self->save($self->file);
      },
    );
    1;
  };
  return $self;
}

sub _init_playback {
  my $self = shift;
  if (not -e (my $file = $self->file)) {
    Carp::croak qq{Playback file $file not found};
  }
  $self->{recorded_transactions} = [$self->serializer->retrieve($self->file)];
  return $self;
}

sub _init_routes {
  my $self = shift;
  my $app  = $self->server->app || Mojolicious->new;

  my $route_name = 'x-mojo-useragent-role-recorder';
  unless ($app->routes->find($route_name)) {
    Scalar::Util::weaken($self);

    # copy top level route children
    my $original = [@{$app->routes->children}];
    my $any      = $app->routes->under(
      '/' => sub {
        my $c = shift;
        return 1 if $self->mode ne 'playback';
        my $tx = $c->tx;

        my $txn = $self->{current_txn};
        if ($txn) {
          $self->cookie_jar->collect($txn);
          $tx->res($txn->res);
          $tx->res->headers->header('X-MUA-Mockable-Regenerated' => 1);
          $c->rendered($txn->res->code);
        }
        else {
          for my $header (keys %{$tx->req->headers->to_hash}) {
            if ($header =~ /^X-MUA-Mockable/) {
              my $val = $tx->req->headers->header($header);
              $tx->res->headers->header($header, $val);
            }
          }
          $c->render(text => '');
        }
        return 0;
      }
    )->name($route_name);
    $any->add_child($_) for (@$original);
  }
  $self->server->app($app);
  return $self;
}

sub _normalized_req {
  my $self = shift;
  my ($tx, $recorded_tx) = @_;

  my $request_normalizer = $self->request_normalizer or return ($tx->req, $recorded_tx->req);
  Carp::croak("The request_normalizer attribute is not a coderef") if (ref($request_normalizer) ne "CODE");

  my $req          = $tx->req->clone;
  my $recorded_req = $recorded_tx->req->clone;
  $request_normalizer->($req, $recorded_req);    # To be modified in-place

  return ($req, $recorded_req);
}


1;
