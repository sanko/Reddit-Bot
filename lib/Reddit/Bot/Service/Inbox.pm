package Reddit::Bot::Service::Inbox;
#
use Moose;
use IO::Async::Timer::Periodic;
#
our $VERSION = "0.01";
#
extends 'Reddit::Bot::Service';
#
has latest => (is        => 'ro',
               isa       => 'Str',
               writer    => '_set_latest',
               predicate => '_has_latest'
);
has timer => (
    is       => 'ro',
    isa      => 'IO::Async::Timer',
    required => 1,
    default  => sub {
         my $s = shift;
         IO::Async::Timer::Periodic->new(
            interval       => 60,
            first_interval => 5,
            on_tick        => sub {

                my $listing =
                    $s->client->get_messages( 'unread',
                              {limit => 100,
                               ($s->_has_latest ? (before => $s->latest) : ())
                              }
                    );
                for my $msg (reverse $listing->all_children) {
                    #warn $post->author . ': ' . $post->selftext;
                    $s->_set_latest($msg->name);
                }



                }
        );
     }
);

sub BUILD {
    my $s = shift;
    $s->client->add($s->timer);
    $s->timer->start;
    warn 'Timer started!';
}
1;
