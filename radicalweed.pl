#!/usr/bin/env perl
use strict;
use warnings;

chdir $ARGV[0] if @ARGV;

use local::lib './local_lib';
use POE qw(Component::IRC);
use Config::General;

my @channels = do {
    my %c = read_config();
    map "#$_", keys %c
  };

# We create a new PoCo-IRC object
my $irc = POE::Component::IRC->spawn(
    nick    => 'radicalweed',
    ircname => 'the SGN Op Bot - Solanum carolinense',
    server  => 'irc.perl.org',
  ) or die "Oh noooo! $!";

POE::Session->create(
    package_states => [ main => [qw( _start irc_001 irc_join )], ],
    heap           => { irc  => $irc },
);

$poe_kernel->run();

sub _start {
    my $heap = $_[HEAP];

    # retrieve our component's object from the heap where we stashed it
    my $irc = $heap->{irc};

    $irc->yield( register => 'all' );
    $irc->yield( connect  => {} );
    return;
}

sub irc_001 {
    my $sender = $_[SENDER];

    # Since this is an irc_* event, we can get the component's object by
    # accessing the heap of the sender. Then we register and connect to the
    # specified server.
    my $irc = $sender->get_heap();

    print "Connected to ", $irc->server_name(), "\n";

    # we join our channels
    $irc->yield( join => $_ ) for @channels;
    return;
}

sub irc_join {
    my ( $sender, $who, $where, $what ) = @_[ SENDER, ARG0 .. ARG2 ];
    my $nick = ( split /!/, $who )[0];
    my $channel = ref $where ? $where->[0] : $where;
    $channel =~ s/^#//;

    my %config = read_config();
    if( exists $config{$channel}{$nick} ) {
        $irc->yield( mode => "#$channel" => '+o' => $nick );
    }
}

sub read_config {
    return Config::General->new('./radicalweed.conf')->getall;
}

# sub irc_public {
#     my ( $sender, $who, $where, $what ) = @_[ SENDER, ARG0 .. ARG2 ];
#     my $nick = ( split /!/, $who )[0];
#     my $channel = $where->[0];

#     if ( my ($rot13) = $what =~ /^rot13 (.+)/ ) {
#         $rot13 =~ tr[a-zA-Z][n-za-mN-ZA-M];
#         $irc->yield( privmsg => $channel => "$nick: $rot13" );
#     }
#     return;
# }

# We registered for all events, this will produce some debug info.
sub _default {
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
