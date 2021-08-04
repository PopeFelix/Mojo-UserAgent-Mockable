use 5.014;

# ABSTRACT: Proxy class for Mojo::UserAgent::Mockable that will not set any proxy.

package Mojo::UserAgent::Mockable::Proxy;

use Mojo::Base 'Mojo::UserAgent::Proxy';

sub detect { # Do not set any proxy 
    return; 
}
1;
