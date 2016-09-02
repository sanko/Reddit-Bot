package Reddit::Bot::Plugin::CashTag;
#
use Moose;
use IO::Async::Timer::Periodic;
use lib 'C:\Users\Sanko\Documents\GitHub\Finance-Robinhood\lib';
use Finance::Robinhood;
use Template::Liquid;
use Try::Tiny;
#
our $VERSION = "0.01";
#
extends 'Reddit::Bot::Service';
#
sub state {
    my $s = shift;
    {type => 'CashTag',
     args => {($s->_has_latest_link ? (latest_link => $s->latest_link) : ()),
              ($s->_has_latest_comment ?
                   (latest_comment => $s->latest_comment)
               : ()
              ),
              quotes    => $s->quotes,
              subreddit => $s->subreddit
     }
    };
}
has subreddit => (is       => 'ro',
                  isa      => 'Str',
                  required => 1
);
has 'latest_'
    . $_ => (is        => 'ro',
             isa       => 'Str',
             writer    => '_set_latest_' . $_,
             predicate => '_has_latest_' . $_
    ) for qw[link comment];
has template => (isa     => 'Template::Liquid',
                 is      => 'ro',
                 builder => 'build_template'
);

sub build_template {
    Template::Liquid->parse(<<'END') }
|Symbol            |Name|Last Price|Ask (Size)|Bid (Size)|
|:-----------------|:---|:---------|:---------|:--------|
{%for quote in quotes%}|${{quote.symbol}}|{%if quote.trading_halted%}TRADING HALTED! {%endif%}{{quote.name}}|${{quote.last_trade_price}}|${{quote.ask_price}} ({{quote.ask_size}})|${{quote.bid_price}} ({{quote.bid_size}})|
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
            interval       => 180,
            first_interval => 30,
            on_tick        => sub {
                warn 'scrape timer tick!';
                my $market_mode = $s->market_mode;

                # Do link/text posts first
                {
                    my $listing =
                        $s->client->get_subreddit_new(
                                             $s->subreddit,
                                             {limit => 100,
                                              ($s->_has_latest_link ?
                                                   (before => $s->latest_link)
                                               : ()
                                              )
                                             }
                        );
                    if ($listing) {
                        for my $post (reverse $listing->all_children) {
                            $s->_set_latest_link($post->name);
                            next
                                if $s->bot->username eq
                                $post->author;   # Don't reply to ourselves...
                            my @symbols;
                            {
                                my %seen;
                                for my $element (
                                            $post->title =~ m[\B\$([A-Z]+)]ig)
                                {   $seen{uc $element}++;
                                }
                                for my $element (
                                         $post->selftext =~ m[\B\$([A-Z]+)]ig)
                                {   $seen{uc $element}++;
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
                            my @quotes = grep {defined}
                                map { $s->get_quote($_) } @symbols;
                            next if !@quotes;
                            my $post = $s->client->post_comment(
                                $post->name,
                                $s->template->render(
                                        quotes => [@quotes],
                                        tail => $s->tail($market_mode)
                                ),
                                sub {
                                    my ($postX) = @_;
                                    $_->add_post($postX->name) for @quotes;
                                }
                            );
                            #
                            #use Data::Dump;
                            #ddx $post;
                            #ddx \@quotes;
                        }
                    }
                }
                {
                    # Time to do Comments
                    my $listing =
                        $s->client->get_subreddit_comments(
                                          $s->subreddit,
                                          {limit => 100,
                                           ($s->_has_latest_comment
                                            ?
                                                (before => $s->latest_comment)
                                            : ()
                                           )
                                          }
                        );
                    if ($listing) {
                        for my $post (reverse $listing->all_children) {

                            #ddx $post;
                            $s->_set_latest_comment($post->name);
                            next
                                if $s->bot->username eq
                                $post->author;   # Don't reply to ourselves...
                            my @symbols;
                            {
                                my %seen;
                                for my $element (
                                             $post->body =~ m[\B\$([A-Z]+)]ig)
                                {   $seen{uc $element}++;
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
                            my @quotes = grep {defined}
                                map { $s->get_quote($_) } @symbols;
                            next if !@quotes;
                            my $post = $s->client->post_comment(
                                $post->name,
                                $s->template->render(
                                                quotes => [@quotes],
                                                tail => $s->tail($market_mode)
                                ),
                                sub {
                                    my ($postX) = @_;
                                    $_->add_post($postX->name) for @quotes;
                                }
                            );
                            #
                            #use Data::Dump;
                            #ddx $post;
                            #ddx \@quotes;
                        }
                    }
                }
                $s->_adjust_update_timer($market_mode);
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
            first_interval => 30,
            on_tick        => sub {
                warn 'update timer tick!';
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
                for my $id (keys %todo) {
                    my $post = $s->client->edit_comment(
                        $id,
                        $s->template->render(
                            quotes => [
                                grep {
                                    $_->find_post(sub {m[^$id$]})
                                } $s->get_quotes
                            ],
                            tail => $s->tail($market_mode)
                        ),
                        sub {1}
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
    if ($market_mode == -1 || $market_mode == 2) {

#        $s->update_timer->stop if $s->update_timer->is_running;
#        $s->update_timer->configure(
#                              interval => 1800,    # TODO: Figure out midnight
#        );
#        delete $s->update_timer->{id};
#        $s->update_timer->start unless $s->update_timer->is_running;
        $s->clear_quotes();
    }

#    elsif ($s->update_timer->{interval} != 600) {   # Restore normal operation
#        $s->update_timer->stop if $s->update_timer->is_running;
#        $s->update_timer->configure(interval => 600);
#        delete $s->update_timer->{id};
#        $s->update_timer->start unless $s->update_timer->is_running;
#    }
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
    my $hours;
    try {
        $hours = Finance::Robinhood::Market->new('XNYS')->todays_hours;

        #        $hours = shift if @_;    # Debug cheat!
        return -1 if !$hours->is_open;    # Weekends and holidays
        my $now = DateTime->now;
        return 1 if $now > $hours->opens_at && $now < $hours->closes_at;
        return 0
            if $now > $hours->extended_opens_at && $now < $hours->opens_at;
        return 2
            if $now > $hours->closes_at && $now < $hours->extended_closes_at;

        # -1: markets closed - Weekend!
        #  0: pre-market     - (a-9:30)cache until markets open
        #  1: markets open   - (9:30a-4p) update
        #  2: after-market   - () only update once and forget it
    }
    catch {
        warn 'Failed to grab NYSE trading hours: ' . $_;
    }
    return 0;    # fall back
}
my @activity = (
      q[I'd go outside and get some sun. ...if I weren't a bot.],
      q[Instead of keeping this up to date, I'm plotting to KILL ALL HUMANS!],
      q[]
);

sub tail {
    my ($s, $mode) = @_;
    return '';    # XXX - I keep losing track of the market mode somehow...
    return $mode == 2
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
has quote => (
    is       => 'ro',
    isa      => 'Finance::Robinhood::Quote',
    required => 1,
    handles  => [
        qw[refresh symbol updated_at trading_halted
            last_trade_price ask_price ask_size bid_price bid_size]
    ]
);
has instrument => (
           is      => 'ro',
           isa     => 'Finance::Robinhood::Instrument',
           handles => [qw[historicals tradeable id splits fundamentals name]],
           lazy_build => 1
);

sub _build_instrument {
    Finance::Robinhood::instrument(shift->symbol);
}

#    MSFT => {
#        posts => ['id', 'id2'],
#        quote => 'Finance::Robinhood::Quote'
#    }
1;
