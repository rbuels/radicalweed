#!/usr/bin/env perl
use strict;
use warnings;

chdir $ARGV[0] if @ARGV;

use local::lib './local_lib';
use POE qw(Component::IRC);
use Config::General;
use Hash::Util qw/ lock_hash /;
#use DB_File::Lock;

my %config = read_config();
while( my ($server_addr,$server) = each %{$config{server}} ) {

    print "setting up $server_addr...\n";

    # We create a new PoCo-IRC object
    my $irc = POE::Component::IRC->spawn(
        nick    => $server->{nick},
        ircname => $server->{description},
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

                # we join our channels
                $irc->yield( join => "#$_" ) for keys %{ $server->{channel} };
            },
            # when someone joins a channel
            irc_join => sub {
                my ( $sender, $who, $where, $what ) = @_[ SENDER, ARG0 .. ARG2 ];
                # parse out the nick and channel
                my $nick = ( split /!/, $who )[0];
                my $channel = ref $where ? $where->[0] : $where;
                $channel =~ s/^#//;

                # give them op if they are in the (reread) config
                my %config = read_config();
                if( exists $config{server}{$server_addr}{channel}{$channel}{ops}{$nick} ) {
                    print "$server_addr: Gave op to $nick in #$channel.\n";
                    $irc->yield( mode => "#$channel" => '+o' => $nick );
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
    my %h = Config::General->new('./radicalweed2.conf')->getall;
    lock_hash %h;
    return %h;
}


sub _print_debug {
    my ( $event, $args ) = @_[ ARG0 .. $#_ ];
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
