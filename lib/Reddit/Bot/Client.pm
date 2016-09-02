package Reddit::Bot::Client;

# Because Reddit::Client is shit.
our $VERSION = "0.01";
#
use Moose;
use Moose::Util::TypeConstraints;
use Net::Async::HTTP;
use URI::Escape qw[uri_unescape];
use JSON::Tiny qw[decode_json encode_json];
use Try::Tiny;

# Disable tricky boolean handling
$JSON::Tiny::FALSE = 0;
$JSON::Tiny::TRUE  = 1;
use Data::Dump;
#
has access_token => (is => 'rw', isa => 'Str', lazy_build => 1);
has token_type   => (is => 'rw', isa => 'Str', lazy_build => 1);
has expires_in   => (is => 'rw', isa => 'Int', lazy_build => 1);
has scope        => (is => 'rw', isa => 'Str', lazy_build => 1);
subtype 'My::TokenRefresher' => as class_type('IO::Async::Timer::Countdown');
coerce 'My::TokenRefresher' => from 'Any' => via {
    IO::Async::Timer::Countdown->new(delay     => $_[0][0],
                                     on_expire => $_[0][1]);
};
has token_refresh => (is     => 'ro',
                      isa    => 'My::TokenRefresher',
                      writer => '_set_token_refresh',
                      coerce => 1
);
#
has loop => (is       => 'ro',
             isa      => 'IO::Async::Loop',
             required => 1,
             weak_ref => 1,
             handles  => [qw[parent add]]
);
has user_agent => (is       => 'ro',
                   isa      => 'Str',
                   required => 1,
                   default  => 'Reddit::Bot::Client/v' . $VERSION
);
has http => (is         => 'ro',
             isa        => 'Net::Async::HTTP',
             required   => 1,
             lazy_build => 1
);

sub _build_http {
    my $s = shift;
    Net::Async::HTTP->new(decode_content => 1,
                          user_agent     => $s->user_agent);
}

sub login {
    my ($s, $client_id, $secret, $u, $p) = @_;
    $s->loop->add($s->http) unless defined $s->http->loop;
    $s->_request('POST',
                 sprintf('https://%s:%s@www.reddit.com/api/v1/access_token',
                         $client_id, $secret
                 ),
                 [grant_type => 'password',
                  username   => uri_unescape($u),
                  password   => uri_unescape($p)
                 ]
        )->on_done(
        sub {
            my $response = shift;
            if ($response->is_success) {
                my $token = decode_json $response->decoded_content;
                $s->$_($token->{$_}) for keys %$token;
                $s->_set_token_refresh(
                    [$token->{expires_in} - 1,
                     sub {
                         $s->login($client_id, $secret, $u, $p);
                     }
                    ]
                );
                $s->loop->add($s->token_refresh)
                    unless defined $s->token_refresh->loop;
                $s->token_refresh->start;
                $s->_on_login();
            }
            else {
                warn $response->status_line, "\n";
            }
        }
        )->get;
}

# Callback system
has 'on_' . $_ => (
    traits  => ['Code'],
    is      => 'ro',
    isa     => 'CodeRef',
    default => sub {
        sub {1}
    },
    handles => {'_on_' . $_ => 'execute_method'},
) for qw[login mail comment new_thread];

# Account
sub get_me {
    decode_json
        shift->_request('GET', 'https://oauth.reddit.com/api/v1/me')
        ->get->decoded_content;
}

# PMs
sub get_messages {
    my ($s, $box, $content) = @_;
    my $url = sprintf(
        'https://oauth.reddit.com/message/%s/%s',
        $box,
        $content ?
            (
            '?' . join '&',
            map {
                      uri_unescape($_) . '='
                    . uri_unescape($content->{$_})
            } keys %$content
            )
        : ''
    );
    my $inbox = decode_json $s->_request('GET', $url)->get->decoded_content;
    return if !defined $inbox->{data};
    my $listing = Reddit::Bot::Client::Listing->new($inbox->{data});
    $s->_on_mail($_) for reverse $listing->all_children;
    $listing;
}

# Subreddit/Comments
sub get_subreddit_new {    # Returns new threads
    my ($s, $subreddit, $content) = @_;
    my $url = sprintf(
        'https://oauth.reddit.com/%s/new/%s',
        $subreddit,
        $content ?
            (
            '?' . join '&',
            map {
                      uri_unescape($_) . '='
                    . uri_unescape($content->{$_})
            } keys %$content
            )
        : ''
    );
    my $inbox = decode_json $s->_request('GET', $url)->get->decoded_content;
    return if !$inbox;
    my $listing = Reddit::Bot::Client::Listing->new($inbox->{data});
    $s->_on_new_thread($_) for reverse $listing->all_children;
    $listing;
}

sub get_subreddit_comments {    # Returns threads and comments
    my ($s, $subreddit, $content) = @_;
    my $url = sprintf(
        'https://oauth.reddit.com/%s/comments/%s',
        $subreddit,
        $content ?
            (
            '?' . join '&',
            map {
                      uri_unescape($_) . '='
                    . uri_unescape($content->{$_})
            } keys %$content
            )
        : ''
    );
    my $raw;
    try {
        $raw = $s->_request('GET', $url)->get->decoded_content;
        my $inbox = decode_json $raw;
        return if !$inbox;
        my $listing = Reddit::Bot::Client::Listing->new($inbox->{data});
        $s->_on_comment($_) for reverse $listing->all_children;
        return $listing;
    }
    catch {
        warn $_;
        warn $raw if $raw;
        ()
    }
}
has queue => (traits  => ['Hash'],
              is      => 'ro',
              isa     => 'HashRef[Future]',
              default => sub { {} },
              handles => {set_queued    => 'set',
                          get_queued    => 'get',
                          has_no_queue  => 'is_empty',
                          num_queued    => 'count',
                          delete_queued => 'delete',
                          queued_pairs  => 'kv'
              }
);

sub post_comment {
    my ($s, $parent, $text, $callback) = @_;
    my $request = $s->_request('POST',
                               'https://oauth.reddit.com/api/comment/',
                               {api_type => 'json',
                                thing_id => $parent,
                                text     => $text
                               }
    );
    if ($callback) {
        $request->on_done(
            sub {
                $s->set_queued(scalar $request, $request);
                my $response = decode_json $request->get->decoded_content;
                ddx $response;
                $callback->(Reddit::Bot::Client::Comment->new(
                                      $response->{json}{data}{things}[0]{data}
                            )
                );
            }
        );
        return $s->delete_queued(scalar $request);
    }
    my $response = decode_json $request->get->decoded_content;
    #
    if ($response->{json}{errors}) {

        # TODO: Don't forget $response->{json}{errors}
        use Data::Dump;
        ddx $response;
        warn 'I need to retry this. Or wait until I have enough karma.';
    }

    #    return if !$inbox;
    use Data::Dump;
    ddx $response;
    my $listing = Reddit::Bot::Client::Comment->new(
                                    $response->{json}{data}{things}[0]{data});

    #    $s->_on_comment($_) for reverse $listing->all_children;
    $listing;
}

sub edit_comment {
    my ($s, $postid, $text, $callback) = @_;

    my $request = $s->_request('POST',
                                 'https://oauth.reddit.com/api/editusertext/',
                               {api_type => 'json',
                                thing_id => $postid,
                                text     => $text
                               }
    );
    if ($callback) {
        $request->on_done(
            sub {
                $s->set_queued(scalar $request, $request);
                try {
                my $response = decode_json $request->get->decoded_content;
                ddx $response;
                $callback->(Reddit::Bot::Client::Comment->new(
                                      $response->{json}{data}{things}[0]{data}
                            )
                );
                }
            }
        );
        return $s->delete_queued(scalar $request);
    }
    my $response = decode_json $request->get->decoded_content;
    #
    if ($response->{json}{errors}) {

        # TODO: Don't forget $response->{json}{errors}
        use Data::Dump;
        ddx $response;
        warn 'I need to retry this. Or wait until I have enough karma.';
    }

    #    return if !$inbox;
    use Data::Dump;
    ddx $response;
    my $listing = Reddit::Bot::Client::Comment->new(
                                    $response->{json}{data}{things}[0]{data});

    #    $s->_on_comment($_) for reverse $listing->all_children;
    $listing;
}

# Utils
sub _request {
    my ($s, $verb, $url, $content) = @_;
    my $response = $s->http->do_request(
               ((defined $content ? (
                           content      => $content,
                           content_type => 'application/x-www-form-urlencoded'
                 ) : ()
                ),
                method => $verb,
                ($s->has_access_token ? (
                                        headers => {
                                            Authorization => ucfirst join ' ',
                                            $s->token_type, $s->access_token
                                        }
                 ) : ()
                ),
                uri => $url
               )
    );
    $response;
}
#
no Moose;
1;

package Reddit::Bot::Client::Listing;
use Moose;
use Moose::Util::TypeConstraints;
#
subtype 'My::Things'   => as class_type('Reddit::Bot::Client::Thing');
subtype 'ListOfThings' => as 'ArrayRef[My::Things]';

#coerce 'My::Things'    => from 'HashRef' => via {
#          $_->{kind} eq 't1' ? Reddit::Bot::Client::Comment->new($_)
#        : $_->{kind} eq 't3' ? Reddit::Bot::Client::Link->new($_)
#        : $_->{kind} eq 't4' ? Reddit::Bot::Client::Message->new($_)
#        : ()
#};
use Data::Dump;
coerce 'ListOfThings' => from 'ArrayRef[HashRef]' => via {
    [map {
         $_->{kind} eq 't1' ? Reddit::Bot::Client::Comment->new($_->{data})
             : $_->{kind} eq 't3' ? Reddit::Bot::Client::Link->new($_->{data})
             : $_->{kind} eq 't4'
             ? Reddit::Bot::Client::Message->new($_->{data})
             : ()
     } @$_
    ];
};
#
has _after => (is       => 'ro',
               isa      => 'Maybe[Str]',
               init_arg => 'after'
);
has _before => (is       => 'ro',
                isa      => 'Maybe[Str]',
                init_arg => 'before'
);
has modhash => (is  => 'ro',
                isa => 'Maybe[Str]',);
has children => (is      => 'ro',
                 isa     => 'ListOfThings',
                 coerce  => 1,
                 traits  => ['Array'],
                 default => sub { [] },
                 handles => {all_children    => 'elements',
                             add_child       => 'push',
                             map_children    => 'map',
                             filter_children => 'grep',
                             find_option     => 'first',
                             get_option      => 'get',
                             join_children   => 'join',
                             count_children  => 'count',
                             has_children    => 'count',
                             has_no_children => 'is_empty',
                             sorted_children => 'sort',
                 }
);
#
package Reddit::Bot::Client::Thing;
use Moose;
has $_ => (is       => 'ro',
           isa      => 'Maybe[Str]',
           required => 1
) for qw[author distinguished id name  subreddit];
has $_ => (is       => 'ro',
           isa      => 'Int',    # TODO: timestamp
           required => 1
) for qw[created created_utc];
#
package                   # t1
    Reddit::Bot::Client::Comment;
use Moose;
extends 'Reddit::Bot::Client::Link';
has $_ => (is  => 'ro',
           isa => 'Maybe[Str]'
) for qw[body body_html link_author link_id link_title link_url];
has $_ => (is  => 'ro',
           isa => 'Maybe[Int]'
) for qw[score controversiality];
#
package                   # t3
    Reddit::Bot::Client::Link;
use Moose;
extends 'Reddit::Bot::Client::Thing';
has $_ => (is  => 'ro',
           isa => 'Maybe[Str]')
    for qw[approved_by author_flair_css_class author_flair_css_text banned_by
    distinguished domain from from_id from_kind link_flair_css_class link_flair_text
    permalink removal_reason
    selftext selftext_html suggested_sort thumbnail title url
];
has $_ => (is  => 'ro',
           isa => 'Maybe[HashRef]',
) for qw[media media_embed secure_media secure_media_embed];
has $_ => (is  => 'ro',
           isa => 'ArrayRef',
) for qw[mod_reports remove_reasons user_reports];
has $_ => (is  => 'ro',
           isa => 'Maybe[Int]',
) for qw[downs guilded likes num_comments num_reports score ups];
has $_ => (is  => 'ro',
           isa => 'Bool|Int',
) for qw[edited];
has $_ => (is  => 'ro',
           isa => 'Bool',)
    for qw[archived clicked hidden hide_score is_self locked over_18
    quarantine saved stickied visited];
package    # t4
    Reddit::Bot::Client::Message;
use Moose;
extends 'Reddit::Bot::Client::Thing';
has $_ => (is  => 'ro',
           isa => 'Maybe[Str]',)
    for
    qw[context body body_html dest first_message first_message_name parent_id replies subject];
has was_comment => (is  => 'ro',
                    isa => 'Bool',);
has is_new => (init_arg => 'new',
               is       => 'ro',
               isa      => 'Bool'
);
1;
