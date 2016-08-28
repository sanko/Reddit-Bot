package Reddit::Bot::Plugin::CashTag;
#
use Moose;
use IO::Async::Timer::Periodic;
use lib 'C:\Users\Sanko\Documents\GitHub\Finance-Robinhood\lib';
use Finance::Robinhood;
use Template::Liquid;
#
our $VERSION = "0.01";
#
extends 'Reddit::Bot::Service';
#
sub state {
    my $s = shift;
    (latest    => $s->latest,
     subreddit => $s->subreddit);
}
has subreddit => (is       => 'ro',
                  isa      => 'Str',
                  required => 1
);
has latest => (is        => 'ro',
               isa       => 'Str',
               writer    => '_set_latest',
               predicate => '_has_latest'
);
has template => (isa     => 'Template::Liquid',
                 is      => 'ro',
                 builder => 'build_template'
);

sub build_template {
    Template::Liquid->parse(<<'END') }
|Symbol            |Last Price|Ask (Size)|Bid (Size)|
|:----------------:|:--------:|:--------:|:--------:|
{%for quote in quotes%}|${{quote.symbol}}{%if quote.trading_halted%} TRADING HALTED!{%endif%}|${{quote.last_trade_price}}|${{quote.ask_price}} ({{quote.ask_size}})|${{quote.bid_price}} ({{quote.bid_size}})|
{%endfor%}

{{tail}}
END
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
                my $market_mode = $s->market_mode;
                $s->_adjust_update_timer($market_mode);
                return if !$listing;    # Something not right happened
                                        #ddx $listing;
                for my $post (reverse $listing->all_children) {
                    warn $post->author . ': ' . $post->body;

                    #ddx $post;
                    $s->_set_latest($post->name);
                    next
                        if $s->bot->username eq
                        $post->author;    # Don't reply to ourselves...
                    my @symbols;
                    {
                        my %seen;
                        for my $element ($post->body =~ m[\B\$([A-Z]+)]ig) {
                            $seen{uc $element}++;
                        }
                        @symbols = sort keys %seen;
                    }

                    #ddx \@symbols;
                    next if !@symbols;

                    # Check to see if we need to cache any quote objects
                    my @need = grep { !$s->has_quote($_) } @symbols;
                    if (@need) {
                        my $quotes = Finance::Robinhood::quote(@need);

                        #use Data::Dump;
                        #ddx $quotes;
                        for (@{$quotes->{results}}) {
                            $s->set_quote($_->symbol,
                                          quotebot::quote->new(quote => $_));
                        }
                    }
                    my @quotes
                        = grep {defined} map { $s->get_quote($_) } @symbols;
                    next if !@quotes;
                    my $post =
                        $s->client->post_comment(
                                    $post->name,
                                    $s->template->render(
                                        quotes => [map { $_->quote } @quotes],
                                        tail => $s->tail($market_mode)
                                    )
                        );
                    #
                    #use Data::Dump;
                    #ddx $post;
                    #ddx \@quotes;
                    $_->add_post($post->name) for @quotes;
                }
            }
        );
    }
);
has update_timer => (
    is       => 'ro',
    isa      => 'IO::Async::Timer',
    required => 1,
    default  => sub {
        my $s = shift;
        IO::Async::Timer::Periodic->new(
            interval       => 300,
            first_interval => 600,
            on_tick        => sub {
                my ($tick) = @_;
                my %todo;
                my $five_min_ago
                    = DateTime->now(time_zone => 'Z')
                    ->subtract(minutes => 15)->epoch;
                for my $quote (grep { $_->updated_at->epoch <= $five_min_ago }
                               $s->get_quotes)
                {   warn 'refreshing quote data for ' . $quote->symbol;
                    $todo{$_}++ for $quote->all_posts;
                    my $epoch = $quote->updated_at->epoch;
                    $quote->refresh();
                    next
                        if $quote->updated_at->epoch
                        == $epoch;    # Robinhood lags on some tickers
                }
                #
                my $market_mode = $s->market_mode;
                #
                for my $id (keys %todo) {
                    $s->client->edit_comment(
                        $id,
                        $s->template->render(
                            quotes => [
                                map { $_->quote } (
                                    grep {
                                        $_->find_post(sub {m[^$id$]})
                                    } $s->get_quotes
                                )
                            ],
                            tail => $s->tail($market_mode)
                        )
                    );
                }
                #
                $s->_adjust_update_timer($market_mode);
            }
        );
    }
);

sub _adjust_update_timer {
    my ($s, $market_mode) = @_;

    # Update the timer's configuration
    # -1: markets closed - Weekend!
    #  0: pre-market     - (a-9:30)cache until markets open
    #  1: markets open   - (9:30a-4p) update
    #  2: after-market   - () only update once and forget it
    if ($market_mode == -1) {
        $s->update_timer->stop if $s->update_timer->is_running;
        $s->update_timer->configure(
                              interval => 1800,    # TODO: Figure out midnight
        );

        #$s->update_timer->start unless $s->update_timer->is_running;
        $s->clear_quotes();
    }
    elsif ($s->update_timer->{interval} != 600) {   # Restore normal operation
        $s->update_timer->stop if $s->update_timer->is_running;
        $s->update_timer->configure(interval => 600);

        #$s->update_timer->start unless $s->update_timer->is_running;
    }
}
has quotes => (traits  => ['Hash'],
               is      => 'ro',
               isa     => 'HashRef[quotebot::quote]',
               default => sub { {} },
               handles => {set_quote     => 'set',
                           get_quote     => 'get',
                           has_no_quotes => 'is_empty',
                           num_quotes    => 'count',
                           delete_quote  => 'delete',
                           quote_pairs   => 'kv',
                           get_quotes    => 'values',
                           has_quote     => 'defined',
                           del_quote     => 'delete',
                           clear_quotes  => 'clear'
               }
);

sub market_mode {
    shift;    # $s;
    my $hours = Finance::Robinhood::Market->new('XNYS')->todays_hours;
    $hours = shift if @_;             # Debug cheat!
    return -1 if !$hours->is_open;    # Weekends and holidays
    my $now = DateTime->now;
    return 0 if $now > $hours->extended_opens_at && $now < $hours->opens_at;
    return 1 if $now > $hours->opens_at          && $now < $hours->closes_at;
    return 2 if $now > $hours->closes_at && $now < $hours->extended_closes_at;

    # -1: markets closed - Weekend!
    #  0: pre-market     - (a-9:30)cache until markets open
    #  1: markets open   - (9:30a-4p) update
    #  2: after-market   - () only update once and forget it
    return -1;    # fall back
}
my @activity = (
      q[I'd go outside and get some sun. ...if I weren't a bot.],
      q[Instead of keeping this up to date, I'm plotting to KILL ALL HUMANS!],
      q[]
);

sub tail {
    my ($s, $mode) = @_;
    return $mode == 1
        ? q[I'll update this once more when after-hours trading ends.]
        : $mode == 1
        ? q[I'll keep this updated until markets close today. Take note of the last time this post was edited.]
        : $mode == 0
        ? q[Markets aren't open right now but I'll start updating this when they do.]
        : $mode == -1
        ? q[Markets are closed all day today. ] . $activity[rand @activity]
        : '';
}

sub random_activity {
}

sub BUILD {
    my $s = shift;
    $s->client->add($s->timer);
    $s->timer->start;
    #
    $s->client->add($s->update_timer);
    $s->update_timer->start;
}
#
package quotebot::quote;
use Moose;
has posts => (traits  => ['Array'],
              is      => 'ro',
              isa     => 'ArrayRef[Str]',
              default => sub { [] },
              handles => {all_posts    => 'elements',
                          add_post     => 'push',
                          map_posts    => 'map',
                          filter_posts => 'grep',
                          find_post    => 'first',
                          get_post     => 'get',
                          join_posts   => 'join',
                          count_posts  => 'count',
                          has_posts    => 'count',
                          has_no_posts => 'is_empty',
                          sorted_posts => 'sort',
              }
);
has quote => (is       => 'ro',
              isa      => 'Finance::Robinhood::Quote',
              required => 1,
              handles  => [qw[refresh symbol updated_at]]
);

#    MSFT => {
#        posts => ['id', 'id2'],
#        quote => 'Finance::Robinhood::Quote'
#    }
1;
