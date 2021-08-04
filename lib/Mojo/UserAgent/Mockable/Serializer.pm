use 5.014;

package Mojo::UserAgent::Mockable::Serializer;

use warnings::register;

use Carp ();
use English qw/-no_match_vars/;
use Mojo::Base 'Mojo::EventEmitter';
use Mojo::File qw(path);
use Mojo::Loader qw(load_class);
use Mojo::Promise;
use JSON::MaybeXS qw(decode_json);
use Safe::Isa (qw/$_isa/);

# ABSTRACT: A class that serializes Mojo transactions created by Mojo::UserAgent::Mockable.

# VERSION

=head1 SYNOPSIS

    # This module is not intended to be used directly. Synopsis here is given to show how 
    # Mojo::UserAgent::Mockable uses the module to record transactions.
    
    use Mojo::UserAgent::Mockable::Serializer;
    use Mojo::UserAgent;
    use File::Slurper qw(read_text write_text);

    my $ua = Mojo::UserAgent->new;
    my $serializer = Mojo::UserAgent::Mockable::Serializer->new;
    
    my @transactions;
    push @transactions, $ua->get('http://example.com');
    push @transactions, $ua->get('http://example.com/object/123');
    push @transactions, $ua->get('http://example.com/subobject/456');

    my $json = $serializer->serialize(@transactions);
    write_text('/path/to/file/json', $json);

    # OR

    $serializer->store('/path/to/file.json', @transactions);

    # Later...

    my $json = read_text('/path/to/file.json');
    my @reconstituted_transactions = $serializer->deserialize($json);

    # OR
    #
    my @reconstituted_transactions = Mojo::UserAgent::Mockable::Serializer->retrieve('/path/to/file.json');

=head1 EVENTS

This module emits the following events:

=head2 pre_thaw

    $serializer->on( pre_thaw => sub {
        my ($serializer, $slush) = @_;
        ...
    });

Emitted immediately before transactions are deserialized. See L</DATA STRUCTURE> below for details
of the format of $slush.

=head2 post_thaw

    # Note that $transactions is an arrayref here.
    $serializer->on( post_thaw => sub {
        my ($serializer, $transactions, $slush) = @_;
        ...
    }

Emitted immediately after transactions are deserialized. See L</DATA STRUCTURE> below for details
of the format of $slush.

In addition, each transaction, as well as each message therein, serialized using this module will 
emit the following events:

=head2 pre_freeze
    
    $transaction->on(freeze => sub {
        my $tx = shift;
        ...
    });

Emitted immediately before the transaction is serialized.

=head2 post_freeze

Emitted immediately after the transaction is serialized. See L</Messages> for details of the 
frozen format. 

    $transaction->on(post_freeze => sub {
        my $tx = shift;
        my $frozen = shift;
        ...
    });

=head1 DATA STRUCTURE

L<serialize> produces, and L<deserialize> expects, JSON data. Transactions are stored as an array 
of JSON objects (i.e. hashes). Each transaction object has the keys:

=for :list
= 'class'
The original class of the transaction.
= 'request'
The request portion of the transaction (e.g. "GET /foo/bar ..."). See L</Messages> below for 
encoding details.
= 'response'
The response portion of the transaction (e.g. "200 OK ..."). See L</Messages> below for encoding
details.

=head2 Messages

Individual messages are stored as JSON objects (i.e. hashes) with the keys:

=for :list
= 'class'
The class name of the serialized object.  This should be a subclass of L<Mojo::Message>
= 'events'
Array of events with subscribers in the serialized object. These events will be re-emitted after 
the L</thaw> event is emitted, but any subscribers present in the original object will be lost.
= 'body'
The raw HTTP message body.

=head1 CAVEATS

This module does not serialize any event listeners.  This is unlikely to change in future releases.

=method serialize

Serialize or freeze one or more instances of L<Mojo::Transaction>.  Takes an array of transactions 
to be serialized as the single argument. This method will generate a warning if the instance has 
any subscribers (see L<Mojo::EventEmitter/on>).  Suppress this warning with (e.g.):

  no warnings 'Mojo::UserAgent::Mock::Serializer';
  $serializer->serialize(@transactions);
  use warnings 'Mojo::UserAgent::Mock::Serializer';

=method deserialize

Deserialize or thaw a previously serialized array of L<Mojo:Transaction>. Arguments:

=for :list
= $data 
JSON containing the serialized objects.

=method store

Serialize an instance of L<Mojo::Transaction> and write it to the given file or file handle.  Takes two
arguments:

=for :list
= $file 
File or handle to write serialized object to.
= @transactions
Array of L<Mojo::Transaction> to serialize
 
=method retrieve

Read from the specified file or file handle and deserialize one or more instances of 
L<Mojo::Transaction> from the data read.  If a file handle is passed, data will be 
read until an EOF is received. Arguments:

=for :list
= $file
File containing serialized object

=cut

sub serialize {
    my ( $self, @transactions ) = @_;

    my @serialized = map { $self->_serialize_tx($_) } @transactions;
    for (0 .. $#serialized) {
        $serialized[$_]->{txn_num} = $_;
    }
    my $JSON = JSON::MaybeXS->new(pretty => 1, sort_by => 1, utf8 => 1);
    return $JSON->encode( \@serialized );
}

sub _serialize_tx {
    my ( $self, $transaction ) = @_;

    if ( !$transaction->$_isa('Mojo::Transaction') ) {
        Carp::croak q{Only instances of Mojo::Transaction may be serialized using this class};
    }

    $transaction->emit('pre_freeze');
    my $slush = {
        request  => $self->_serialize_message( $transaction->req ),
        response => $self->_serialize_message( $transaction->res ),
        class    => ref $transaction,
    };
    for my $event ( keys %{ $transaction->{'events'} } ) {
        next if $event eq 'pre_freeze' or $event eq 'post_freeze' or $event eq 'resume' 
            or $event eq 'finish'; # 'finish' comes from Mojo::IOLoop; we probably don't need to serialize it
        Carp::carp(qq{Subscriber for event "$event" not serialized}) if warnings::enabled;
        push @{ $slush->{'events'} }, $event;
    }

    $transaction->emit( 'post_freeze', $slush );

    return $slush;
}

sub _serialize_message {
    my ( $self, $message ) = @_;

    $message->emit('pre_freeze');
    my $slush = {
        class => ref $message,
        body  => $message->to_string,
    };
    if ( $message->can('url') ) {
        $slush->{url} = _freeze_url( $message->url );
    }
    for my $event ( keys %{ $message->{'events'} } ) {
        next if $event eq 'pre_freeze' or $event eq 'post_freeze';
        Carp::carp(qq{Subscriber for event "$event" not serialized}) if warnings::enabled;
        push @{ $slush->{'events'} }, $event;
    }

    $message->emit( 'post_freeze', $slush );
    return $slush;
}

sub _freeze_url {
    my $url = shift;
    if ( !$url->$_isa('Mojo::URL') ) {
        $url = Mojo::URL->new($url);
    }
    my $slush;
    for my $attr (qw/scheme userinfo host port path query fragment/) {
        $slush->{$attr} = sprintf '%s', $url->$attr if defined $url->$attr;
    }
    if ( %{ $url->base } ) {
        $slush->{base} = _freeze_url( $url->base );
    }
    return $slush;
}

sub deserialize {
    my ( $self, $frozen ) = @_;

    my $slush = decode_json($frozen);

    if ( ref $slush ne 'ARRAY' ) {
        Carp::croak q{Invalid serialized data: not stored as array.};
    }
    $self->emit( 'pre_thaw', $slush );

    my @transactions;
    for my $tx_num ( 0 .. $#{$slush} ) {
        Mojo::Promise->resolve->then(sub {
            return $self->_deserialize_tx( $slush->[$tx_num] );
        })->then(sub {
            push @transactions, $_[0];
        })->catch(sub {
            my $tx_num = ( $tx_num + 1 );
            Carp::croak qq{Error deserializing transaction $tx_num: $_[0]};
        })->wait;
    }

    $self->emit( 'post_thaw', \@transactions, $slush );
    return @transactions;
}

sub _deserialize_tx {
    my ( $self, $slush ) = @_;

    for my $key (qw/class request response/) {
        if ( !defined $slush->{$key} ) {
            Carp::croak qq{Invalid serialized data: Missing required key '$key'};
        }
    }

    if (my $e = load_class( $slush->{'class'} )) {
      die $e;
    }
    my $obj = $slush->{'class'}->new();

    if ( !$obj->$_isa('Mojo::Transaction') ) {
        Carp::croak q{Only instances of Mojo::Transaction may be deserialized using this class};
    }

    my $response = $self->_deserialize_message( $slush->{response} );
    $obj->res($response);

    my $request = $self->_deserialize_message( $slush->{request} );
    $obj->req($request);

    if ( $slush->{'events'} ) {
        for my $event ( @{ $slush->{'events'} } ) {
            $obj->emit($event);
        }
    }
    return $obj;
}

sub _deserialize_message {
    my ( $self, $slush ) = @_;
    for my $key (qw/body class/) {
        if ( !$slush->{$key} ) {
            Carp::croak qq{Invalid serialized data: missing required key "$key"};
        }
    }

    if (my $e = load_class( $slush->{'class'} )) {
      die $e;
    }
    my $obj = $slush->{'class'}->new;
    if ( $slush->{'url'} && $obj->can('url') ) {
        $obj->url( _thaw_url( $slush->{url} ) );
    }
    if ( !$obj->can('parse') ) {
        die qq{Message class "$slush->{class}" must define the 'parse' method\n};
    }
    $obj->parse( $slush->{'body'} );

    if ( !$obj->can('emit') ) {
        die qq{Message class "$slush->{class}" must define the 'emit' method\n};
    }
    if ( $slush->{'events'} ) {
        for my $event ( @{ $slush->{'events'} } ) {
            $obj->emit($event);
        }
    }

    return $obj;
}

sub _thaw_url {
    my $slush = shift;
    # FIXME: Temporary workaround
    return Mojo::URL->new($slush) unless ref $slush;

    my $url   = Mojo::URL->new;

    for my $attr ( keys %{$slush} ) {
        $url->$attr( $slush->{$attr} );
    }
    if ( $slush->{base} ) {
        $url->base( _thaw_url( $slush->{base} ) );
    }
    return $url;
}

sub store {
    my ( $self, $file, @transactions ) = @_;

    my $serialized = $self->serialize(@transactions);
    path($file)->spurt($serialized);
}

sub retrieve {
    my ( $self, $file ) = @_;

    my $contents = path($file)->slurp;
    return $self->deserialize($contents);
}
1;
