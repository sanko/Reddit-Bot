package Reddit::Bot::Service::Home;
# TODO: Rename this RBS::Monitor and make CashTag extend it after taking comment handler out
use Moose;
use IO::Async::Timer::Periodic;
#
our $VERSION = "0.01";
#
extends 'Reddit::Bot::Service';
#
has subreddit => (is       => 'ro',
                  isa      => 'Str',
                  required => 1
);
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
                    $s->client->get_subreddit_comments(
                              $s->subreddit,
                              {limit => 100,
                               ($s->_has_latest ? (before => $s->latest) : ())
                              }
                    );
                    return if !$listing; # Something happened to Reddit
                for my $post (reverse $listing->all_children) {
                    #warn $post->author . ': ' . $post->selftext;
                    $s->_set_latest($post->name);
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
1;
