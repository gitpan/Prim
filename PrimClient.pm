#!/usr/bin/perl
$VERSION = "0.01";

use strict;

=head1 NAME

PrimClient - a helper module for Prim.pm

=head1 SYNOPSIS

  my $back_end = PrimClient->new($host, $port);
  my @response = $back_end->call("method_name", "arg1", "arg2");

  print "@response\n";

=head1 DESCRIPTION

This is an internal object oriented module whose sole purpose is to
make it easier to write Prim.pm.  This module provides that actual
socket reads and writes for Prim.pm.  It must know the host and port
to begin the connection.  It invokes remote methods through its call
methods which is not an ideal user API.

In summary, this class does the heavy lifting.  But it is really
most useful as a helper.  If you want to reimplement it, you might
be better off to go directly to the protocols file in the distribution.

=head2 EXPORT

None.

=head1 AUTHOR

Phil Crow, philcrow2000@yahoo.com

=cut

use IO::Socket;

package PrimClient;

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

# Build the request.

  my $request = "<?xml version='1.0' ?><prim>"
              . "<call_method name='$method'> <arg_list>\n";

  foreach (@_) {
    $request .= "<arg>$_</arg>";
  }
  $request .= " </arg_list> </call_method></prim>\n";

# Send it, return the result

  return _send_and_receive_packet($self, $request);

}

# Give this routine a well formed prim packet.  It will send it to the
# back end server, wait for the reply, die on error or send you the
# unparsed prim packet.

sub _send_and_receive_packet {
  my $self                = shift;
  my $packet              = shift;
  my $preserving_newlines = shift;

# Hail the server.

  my $remote = IO::Socket::INET->new (
      Proto    => 'tcp',
      PeerAddr => $self->{HOST},
      PeerPort => $self->{PORT},
  ) or die "Couldn't connect to server: $!\n";

  $remote->autoflush(1);

  print $remote $packet;

# Normally a call to shutdown would be in order here, but the server is
# looking for the ending prim tag </prim>.  It uses that as a sentinel value.

  my $retval;
  while (<$remote>) {
    chomp unless ($preserving_newlines);
    $retval .= $_;
  }

  if ($retval =~ s/.*?error>//) {
    $retval =~ s/<.error>.*//;
    die "$retval\n";
  }

  close $remote;

  return $retval;
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
  my $xmlreply = _send_and_receive_packet($self, $request, "preserve_newlines");
  return $xmlreply;
}

1;

