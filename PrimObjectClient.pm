#!/usr/bin/perl
$VERSION = "0.01";

use strict;

=head1 NAME

PrimObjectClient - a helper module for PrimObject.pm

=head1 SYNOPSIS

  use PrimObjectClient;

  # Initiates connection to server.
  my $tcp_client = PrimObjectClient->new('host', $port_number);

  # Calls method in the server.
  print $tcp_client->call("method", @arguments);

  # First, send docs for method and method2.
  print $tcp_client->send_documentation("method", "method2");

  # Now, send all docs.
  print $tcp_client->send_documentation();

=head1 DESCRIPTION

This class is a helper provided to make implementing object receiving
prim clients easier.  Scripts should usually instantiate a PrimObject
instead of coming directly here.  If you want to reimplement this module,
you may be better off going directly to the protocols file in the
distribution.

This class provides a single continuous tcp connected session to a server
whose host and port you pass to the constructor.  Each call is packaged
as a proper prim message and sent to the server.  The response is
checked for errors.  Such errors cause this class issue a die, if you
don't want to die, use eval to trap these fatal errors.  If the response
is not an error, it is passed unaltered (still in xml) to the caller.
Documentation requests are handled separately, but in the same manner.

=head2 EXPORT

None.

=head1 AUTHOR

Phil Crow, philcrow2000@yahoo.com

=cut

use IO::Socket;

package PrimObjectClient;

=head1 new

This constructor merely stores the host and port information it receives
in a hash, and returns a blessed reference to it.

=cut

sub new {
  my $class = shift;
  my $host  = shift || 'localhost';
  my $port  = shift || 9000;

  my $self        = {};
  $self->{HOST}   = $host;
  $self->{PORT}   = $port;

# Hail the server.

  my $remote = IO::Socket::INET->new (
      Proto    => 'tcp',
      PeerAddr => $self->{HOST},
      PeerPort => $self->{PORT},
  ) or die "Couldn't connect to server: $!\n";

  $remote->autoflush(1);

  $self->{REMOTE} = $remote;

  return bless $self, $class;
}

=head1 call

Initiates a connection to the server specified in the constructor.
Sends a properly formatted xml request for that server to run the method
passed as the first argument by the caller with the remaining arguments
passed through the server's function.

Takes a method name and a list of arguments to that method.

Returns a list of the return values produced by the server.

Handles all xml details.

This routine should have a timeout.

=cut

sub call {
  my $self   = shift;
  my $method = shift;
  my $remote = $self->{REMOTE};

# Build the request.

  my $request = "<?xml version='1.0' ?><prim>"
              . "<call_method name='$method'> <arg_list>\n";

  foreach (@_) {
    $request .= "<arg>$_</arg>";
  }
  $request .= " </arg_list> </call_method></prim>\n";

# Send the request, return the result.

  return _send_and_receive_packet($self, $request);

}

sub _send_and_receive_packet {
  my $self                = shift;
  my $packet              = shift;
  my $preserving_newlines = shift;
  my $remote              = $self->{REMOTE};

  print $remote $packet;

  my $received;
  while (<$remote>) {
    chomp unless ($preserving_newlines);
    $received .= $_;
    last if (m!</prim>!);
  }

  if ($received =~ s/.*?error>//) {
    $received =~ s/<.error>.*//;
    die "$received\n";
  }

  return $received;
}

sub send_documentation {
  my $self = shift;
  my $request;
 
  if (@_) {  # user wants specific routines
    my $names = join ",", @_;
    $request = "<?xml version='1.0' ?>"
             . "<prim><send_documentation name='$names'/></prim>\n";
  }
  else {  # user wants everything
    $request = "<?xml version='1.0' ?><prim><send_documentation/></prim>\n";
  }
  my $xmlreply = _send_and_receive_packet($self, $request, "preserve_newlines");  return $xmlreply;
}

sub DESTROY {
  my $self   = shift;
  my $remote = $self->{REMOTE};

  print $remote "<?xml version='1.0' ?><prim><shutdown/></prim>\n";
  close $remote;
}

1;

