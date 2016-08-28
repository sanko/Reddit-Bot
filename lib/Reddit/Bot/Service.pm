package Reddit::Bot::Service;
#
use Moose;
use IO::Async::Timer;
#
our $VERSION = "0.01";
#
has bot => (is       => 'ro',
            isa      => 'Reddit::Bot',
            required => 1,
            weak_ref => 1,
            handles  => [qw[client]]
);

sub state {


}

1;
