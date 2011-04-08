#!/usr/bin/env perl
use strict;
use warnings;

chdir $ARGV[0] if @ARGV;
use POE qw(Component::IRC);
use Config::General;
use Hash::Util qw/ lock_hash /;
#use DB_File::Lock;

my  %opstate;
my  %config = read_config();
while( my ($server_addr,$server) = each %{$config{server}} ) {
    my  @username;

    if( exists $server->{username} && defined $server->{username} ) {
        @username = ( username => $server->{username} );

    }

    print "setting up $server_addr...\n";

    # We create a new PoCo-IRC object
    my $irc = POE::Component::IRC->spawn(
        nick    => $server->{nick},
        ircname => $server->{description},
        @username,
        server  => $server_addr,
       ) or die "Oh noooo! $!";

    POE::Session->create(
        package_states => [main => [qw[ _start _default ]]],
        inline_states => {
            # on server welcome message
            irc_001  => sub {
                my $sender = $_[SENDER];

                # Since this is an irc_* event, we can get the component's object by
                # accessing the heap of the sender. Then we register and connect to the
                # specified server.
                my $irc = $sender->get_heap();

                print "$server_addr: connected to ", $irc->server_name, "\n";

                for my $channel ( keys %{ $server->{channel} } ) {
                    # flag that we don't have op yet for this channel
                    $opstate{$server_addr}{$channel}{state} = 0;

                    # List of known users that are logged in this channel that
                    # we need to +op once we can
                    %{$opstate{$server_addr}{$channel}{noop}} = ();

                }

                # we join our channels
                $irc->yield( join => "#$_" ) for keys %{ $server->{channel} };
            },


            # notification of who is on the list after joining
            irc_353 => sub {
                my ( $args ) = $_[ ARG2 ];
                my  $channel = @$args[1];
                my  @names = split /\s+/, @$args[2];
                $channel =~ s/^#//;

                _inline_debug( 'irc_353', @_[ ARG0 .. $#_ ] );

                # Don't bother processing unless we're an op
                return
                    unless $opstate{$server_addr}{$channel}{state};


                # Refresh our configuration
                %config = read_config();

                # Build our list
                for my $name ( @names ) {
                    next if $name =~ /^@/;              # already an op
                    next if $name eq $server->{nick};   # of course we're in the channel!

                    next unless grep /^$name$/, keys %{$config{server}{$server_addr}{channel}{$channel}{ops}};

                    $opstate{$server_addr}{$channel}{noop}{$name}++;

                }

                # did we find any?
                if( keys %{ $opstate{$server_addr}{$channel}{noop} } ) {
                    # Start the cascading of providing retroactive op privs
                    my  $nick = (keys  %{ $opstate{$server_addr}{$channel}{noop} })[0];
                    delete $opstate{$server_addr}{$channel}{noop}{$nick};
                    print "$server_addr: Gave op to $nick in #$channel.\n";
                    $irc->yield( mode => "#$channel" => '+o' => $nick );

                }

            },


            # when someone joins a channel
            irc_join => sub {
                my ( $sender, $who, $where, $what ) = @_[ SENDER, ARG0 .. ARG2 ];
                # parse out the nick and channel
                my $nick = ( split /!/, $who )[0];
                my $channel = ref $where ? $where->[0] : $where;
                $channel =~ s/^#//;

                _inline_debug( 'irc_join', @_[ ARG0 .. $#_ ] );

                # See if we have op privileges before we go gallivanting about
                # attempting to give +op and ticking off the server

                if( $opstate{$server_addr}{$channel}{state} ) {

                    # give them op if they are in the (reread) config
                    %config = read_config();
                    if( exists $config{server}{$server_addr}{channel}{$channel}{ops}{$nick} ) {
                        print "$server_addr: Gave op to $nick in #$channel.\n";
                        $irc->yield( mode => "#$channel" => '+o' => $nick );
                    }

                }

            },


            irc_mode => sub {
                my ( $who, $where, $what, $towhom ) = @_[ ARG0 .. ARG3 ];
                my $nick = ( split /!/, $who )[0];
                my $channel = ref $where ? $where->[0] : $where;
                $channel =~ s/^#//;

                _inline_debug( 'irc_mode', @_[ ARG0 .. $#_ ] );

                if( defined $towhom ) {
                    if( $towhom eq $server->{nick} ) {
                        if( $what eq '+o' ) {
                            # I just received op privileges
                            $opstate{$server_addr}{$channel}{state} = 1;
                            print "$server_addr: Received operator privileges in #$channel\n";

                            # Do something about it

                            # Reset our list of known users that need op privs
                            %{$opstate{$server_addr}{$channel}{noop}} = ();

                            # Query the server for a new list
                            $irc->yield( names => "#$channel" );

                        }
                        elsif( $what eq '-o' ) {
                            $opstate{$server_addr}{$channel}{state} = 0;
                            print "$server_addr: Lost operator privileges in #$channel\n";

                        }

                    }
                    elsif( $what eq '+o' ) {
                        # someone got privileges (by either us or elsewhere, remove them
                        delete $opstate{$server_addr}{$channel}{noop}{$towhom}
                            if exists $opstate{$server_addr}{$channel}{noop}{$towhom};

                        # Use this as a hook to see if we have any others to bump
                        if( $opstate{$server_addr}{$channel}{state} ) {
                            if( keys %{ $opstate{$server_addr}{$channel}{noop} } ) {
                                # Start the cascading of providing retroactive op privs
                                my  $nick = (keys  %{ $opstate{$server_addr}{$channel}{noop} })[0];
                                delete $opstate{$server_addr}{$channel}{noop}{$nick};
                                print "$server_addr: Gave op to $nick in #$channel.\n";
                                $irc->yield( mode => "#$channel" => '+o' => $nick );

                            }

                        }

                    }

                }

            },


            irc_notice => sub {
                my ( $sender, $what, $message ) = @_[ ARG0 .. ARG2 ];
                my  $i = 0;

                _inline_debug( 'irc_mode', @_[ ARG0 .. $#_ ] );

                if( $sender =~ /NickServ/i && $message =~ /This nickname is registered/ ) {

                    # do we have a password for our nick for this server?
                    if( exists $config{server}{$server_addr}{password} ) {
                        # Register our nick
                        $irc->yield( privmsg => 'NickServ', "identify " .  $config{server}{$server_addr}{password} );
                        return;

                    }

                }

            },

        },
        heap => { irc  => $irc },
       );
}

$poe_kernel->run();

sub _start {
    my $heap = $_[HEAP];

    # retrieve our component's object from the heap where we stashed it
    my $irc = $heap->{irc};
    $irc->yield( register => 'all' );
    $irc->yield( connect  => {} );

    return;
}

# We registered for all events, this will produce some debug info.
sub _default {
    #_print_debug(@_)
}

############## HELPER SUBS ######################

sub read_config {
    my %h = Config::General->new('./radicalweed.conf')->getall;
    lock_hash %h;
    return %h;
}


sub _print_debug {
    my ( $event, $args ) = @_[ ARG0 .. $#_ ];

    # skip logging events we don't care about
    return 0 if grep /^$event$/, qw( irc_ping irc_372 );

    # format the rest
    my @output = ("$event: ");

    for my $arg (@$args) {
	if ( ref $arg eq 'ARRAY' ) {
	    push( @output, '[' . join( ', ', @$arg ) . ']' );
	}
	else {
	    push( @output, "'$arg'" );
	}
    }
    print join ' ', @output, "\n";
    return 0;
}

sub _inline_debug {
    my ( $event, @args ) = @_;

    return 0;   # disable debugging

    # skip logging events we don't care about
    return 0 if grep /^$event$/, qw( irc_ping irc_372 );

    # format the rest
    my @output = ("$event: ");

    for my $arg (@args) {
        if ( ref $arg eq 'ARRAY' ) {
            push( @output, '[' . join( ', ', @$arg ) . ']' );

        }
        else {
            push( @output, "'$arg'" );

        }

    }
    print join ' ', @output, "\n";
    return 0;

}
