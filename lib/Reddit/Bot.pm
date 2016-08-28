package Reddit::Bot;
#
use Moose;
use IO::Async::Loop;
use Net::Async::HTTP;
use Try::Tiny;
#
use lib '..', '../lib';
use Reddit::Bot::Client;
use Reddit::Bot::Service::Inbox;
use Reddit::Bot::Service::Home;
#
our $VERSION = "0.01";
$|++;
#
has loop => (is       => 'ro',
             isa      => 'IO::Async::Loop',
             required => 1,
             weak_ref => 1
);
has services => (traits  => ['Array'],
                 is      => 'ro',
                 isa     => 'ArrayRef[Reddit::Bot::Service]',
                 default => sub { [] },
                 handles => {all_services    => 'elements',
                             add_service     => 'push',
                             map_services    => 'map',
                             filter_services => 'grep',
                             find_service    => 'first',
                             get_service     => 'get',
                             join_services   => 'join',
                             count_services  => 'count',
                             has_services    => 'count',
                             has_no_services => 'is_empty',
                             sorted_services => 'sort',
                 },
);
has client_id => (is       => 'ro',
                  isa      => 'Str',
                  required => 1
);
has secret => (is       => 'ro',
               isa      => 'Str',
               required => 1
);
has username => (is       => 'ro',
                 isa      => 'Str',
                 required => 1
);
has password => (is       => 'ro',
                 isa      => 'Str',
                 required => 1
);
#
has client => (is         => 'ro',
               isa        => 'Reddit::Bot::Client',
               required   => 1,
               lazy_build => 1
);

sub _build_client {
    my $s = shift;
    Reddit::Bot::Client->new(
        loop       => $s->loop,
        user_agent => 'Robingood:1.0.0 (by /u/CardinalNumber)',
        on_login   => sub {
            warn;
            my ($ss, $tokens) = @_;
            warn ref $ss;
            warn ref $tokens;

            #ddx $ss->get_me;
            warn;
            warn;

            #ddx $ss->get_messages('inbox');
            $s->_on_login($tokens);
            warn;
        },
        on_mail => sub {
            $s->_on_mail(@_);
        },
                on_comment => sub {
            $s->_on_comment(@_);
        } ,on_new_thread => sub {
            $s->_on_new_thread(@_);
        }
    );
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
#

sub load {
    my ($self, $module, $args) = @_;


    # This is possible a leeeetle bit evil.
     my $filename = $module;
    $filename =~ s{::}{/}g;
    my $file = "Reddit/Bot/Plugin/$filename.pm";
    $file = "./$filename.pm"         if ( -e "./$filename.pm" );
    $file = "./modules/$filename.pm" if ( -e "./modules/$filename.pm" );
     warn "Loading $module from $file";

    # force a reload of the file (in the event that we've already loaded it).
    no warnings 'redefine';
    delete $INC{$file};

    try { require $file } catch { die "Can't load $module: $_"; };

    # Ok, it's very evil. Don't bother me, I'm working.

    my $m = "Reddit::Bot::Plugin::$module"->new(
        bot   => $self,
        %$args
    );

    die("->new didn't return an object") unless ( $m and ref($m) );
    die( ref($m) . " isn't a $module" )
      unless ref($m) =~ /\Q$module/;

    #$self->add_handler( $m, $module );

    return $m;
}
#
sub BUILD {
    my ($s, $args) = @_;
    my $okay = 0;
    for (1 .. 6) {
         last if $okay;
        try {
            $s->client->login($s->client_id, $s->secret,
                              $s->username,  $s->password);

            # TODO: Move this service init somewhere else... Idk where yet
            $s->add_service(Reddit::Bot::Service::Home->new(
                                                         bot       => $s,
                                                         subreddit => $args->{home}
                            )
            ) if $args->{home};
            $s->add_service(Reddit::Bot::Service::Inbox->new(bot => $s));


            use Data::Dump;
            ddx $args->{plugins};
             for my $plugin (@{$args->{plugins}}) {
                my $service = $s->load($plugin->{type}, $plugin->{args});

                $s->add_service($service);
            }
            #
            $okay++;
        } catch {
  warn "caught error: $_";
};

    }
    die 'Failed to connect to Reddit after several attempts' if !$okay;
}
1;

=package layout

    Reddit::Bot
                ::Client                     - Reddit API wrapper
                    - identity_me
                    - mysubreddits_karma
                    - identity_me_prefs
                    - account_me_prefs
                    - identity_me_trophies
                    - read_prefs_friends
                    - read_prefs_blocked
                    - modflair_clearflairtemplates
                    - modflair_deleteflair
                    - modflair_deleteflairtemplate
                    - modflair_flair
                    - modflair_flairconfig
                    - modflair_flaircsv
                    - modflair_flairlist
                    - flair_flairselector
                    - modflair_flairtemplate
                    - flair_selectflair
                    - flair_setflairenabled



                ::Settings
                ::Plugin::PMCommand::Admin   - Administration level PM commands
                ::Plugin::PMCommand          - Respond to non-admin commands
                ::Plugin::PostCommand        -
                ::Plugin::PostCommand::Admin -
                ::Service::Message::Inbox
                ::Service::Subreddit::Posts
                ::Service::Subreddit::Wiki
                ::Service::Subreddit::Automoderator
                ::Command::Post::Edit
                ::Command::Post::Delete    ?
                ::Command::Admin::Ban
                ::Command::Admin::Block      - Block an account
                ::Command::Admin::
                ::Command::Admin::Flair
                ::Command::Admin::
                ::Command::Admin::Sidebar
                ::Command::Admin::Delete
                ::Command::Admin::Sticky
                ::Command::Admin::Contest
                ::Command::Admin::Lock     - Lock and Unlock threads
                ::Command::Admin::




=head1 SYNOPSIS

    use Reddit::Bot;

=head1 DESCRIPTION

Reddit::Bot is ...

=head1 LICENSE

Copyright (C) Sanko Robinson.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 AUTHOR

Sanko Robinson E<lt>sanko@cpan.orgE<gt>

=cut
