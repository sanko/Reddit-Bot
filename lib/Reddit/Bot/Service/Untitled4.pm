package Reddit::Bot::Service::Home;
#
use Moose;
use IO::Async::Timer::Periodic;
#
our $VERSION = "0.01";
#
extends 'Reddit::Bot::Service';
#
has subreddit => (
    is => 'ro',
    isa => 'Str',
    required => 1
);
has latest => (is  => 'rw',
               isa => 'Str');
has timer => (
    is       => 'ro',
    isa      => 'IO::Async::Timer',
    required => 1,
    default  => sub {
         my $s = shift;
         IO::Async::Timer::Periodic->new(
            interval       => 60,
            first_interval => 5,
            on_tick        => sub {$s->client->get_comments_new($s->subreddit, ($s->latest? $s->latest: ()))}
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
