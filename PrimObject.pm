#!/usr/bin/perl
$VERSION = "0.01";

use strict;

use IO::Socket;

=head1 NAME

PrimObject - Perl Remote Invocation of Methods object client class

=head1 SYNOPSIS

  use PrimObject;

  my $perl_bean_server = PrimObject->Prim_constructor("name" [, "server"]);
  my $remote_object = $perl_bean_server->make_object(1, 2, 3);
  my @answer = $remote_object->method(2);
  print "@answer\n";

=head1 DESCRIPTION

This class is a prim (Perl Remote Invocation of Methods) client.  You can
use it to avoid learning and using the xml based prim protocols yourself
(though you are welcome to do that).

First, you must make a client by calling Prim_constructor on this class.
Supply the registered name of the service you want to contact.  You may
now call any regular method exposed by the server.  If any of those
generates objects, you call it in the same way storing the return.  This
class gives you a blessed reference which will behave just like the object
the server constructed for you.  When you call methods on it, this class
repackages them as prim calls, passes them to the server (which breaks
them apart into method name an arguments, and calls the method of the object),
waits for the reply, parses it and passes it back to you.

=head1 INTERNALS

This client uses prim protocols (which are valid xml) to send your requests
to the server.  It initiates a connection to an prim object server
(usually implemented via PrimObjectServer, clever naming huh?) in the
constructor.  It does this using the helper class PrimObjectClient.pm.
That connection is maintained until the original instance of this class
is ready for destruction and garbage collection.  At that point the
server is notified that you are finished.

=head1 BUGS

There are no timeouts.

=head2 EXPORT

This is currently an object oriented module with no exports.  This may change.

=head1 AUTHOR

Phil Crow, philcrow2000@yahoo.com

=head1 SEE ALSO

The files objectclient and client in the distribution have examples of
using this module and its cousin Prim.pm.

=cut

use PrimObjectClient;

package PrimObject;

=head1 new

This constructor takes the name of a service and optionally a server
(at some point in the future, leaving out the server will cause discovery
across the network, currently the server ignores the server name and uses
localhost in all cases).  It then locates the port number of the needed
service.  (At present it looks for a file in the /tmp directory called
name.prim where name is the one passed in.  This is handled by the _discover
method which can and should be replaced with a more sophisticated scheme.)

Having located the machine and port number for the service, new builds
a PrimClient object, stores it in a typical hash, blesses a reference to
that hash, and returns the reference to the caller.

=cut

sub Prim_constructor {
  my $class  = shift;
  my $name   = shift;
  my $server = shift;

  my $self   = {};
  bless $self, $class;

  my ($ip, $port) = _Prim_discover($name, $server);

  my $prim_client = PrimObjectClient->new($ip, $port);

  $self->{PRIMCLIENT} = $prim_client;

  return $self;
}

# Attempts to locate the service you want by name.
# Begins by contacting the primd server on the current box.  If that fails,
# scans /tmp directory for files called name.prim.  If it fails it dies
# with the message Couldn't fine $name $server.

sub _Prim_discover {
  my $name   = shift;
  my $server = shift || 'localhost';

  # Try the local primd server.

  PRIMD_ATTEMPT:
  {
    my $remote = IO::Socket::INET->new (
       Proto    => 'tcp',
       PeerAddr => $server,
       PeerPort => 5368,
    ) or last PRIMD_ATTEMPT;

    $remote->autoflush(1);
                          
    # Send the request.
                           
    print $remote "<?xml version='1.0' ?><prim><lookup name='$name'/></prim>";
    shutdown $remote, 1;  # done writing

    my $primd_result;
    while (<$remote>) {
      chomp;
      $primd_result .= $_;
    }

    $primd_result =~ /<host>(.*)<.host>.*<port>\s*(\d+)/;
    my $hostprimd = $1;
    my $portprimd = $2;
    $hostprimd =~ s/\s*//g;

    if ($hostprimd and $portprimd) {
      return $server, $portprimd;   # primd currently returns 127.0.0.1 as host
#      return $hostprimd, $portprimd;
    }
  }

  # We failed with primd, so we continue with our own disk reading.
  # (This is pointless at present since this is the same code that
  # that primd just tried, but it shows how a two stage approach could
  # be implemented.)

  my $death_wail = "Couldn't find $name $server.\n";
  my $port;

  open PRIMFILE, "/tmp/$name.prim" or die "Couldn't read /tmp/$name.prim\n";

  while (<PRIMFILE>) {
    if (/^\s*port\s+(\d+)/) {
      $port = $1;
      last;
    }
  }

  close PRIMFILE;

  if ($port) { return ("127.0.0.1", $port); }
  else       { die $death_wail;             }
}

sub send_documentation {
  my $self = shift;
 
  my $safety_counter = 0;
  my %retval;
  my $docs = $self->{PRIMCLIENT}->send_documentation(@_);

  $docs =~ s/.*<documentation>//;
  $docs =~ s/<.documentation>.*//;
 
  while ($docs !~ /^\s*$/) {
    $docs =~ s/^\s*<method>(.*?)<.method>\s*<description>(.*?)<.description>//s;    my $method = $1;
    my $description = $2;
    $retval{$method} = $description;
    last if ($safety_counter++ > @_);
  }

  return %retval;
}

# DESTROY is defined with an empty body to keep AUTOLOAD from catching it.
# We don't need any particular destruction action.

sub DESTROY { }

# AUTOLOAD is used for remote method dispatch.  Any call that ends up here
# is passed along to our PrimClient object to become a remote method call.

# PrimClient needs to pass us the xml return value.  We need to parse it.

sub AUTOLOAD {
  my $self = shift;
  my $method = $PrimObject::AUTOLOAD;   # hard coding Prim is wrong XXX
  $method =~ s/.*:://;

  my $response;

  if ($self->{OBJECT}) {
    $response = $self->{PRIMCLIENT}->call($method, $self->{OBJECT}, @_);
  }
  else {
    $response = $self->{PRIMCLIENT}->call($method, @_);
  }
  my @responses;

  $response =~ s/.*<return_from name.*?>//;
  $response =~ s/<.return_from>.*//;

  while ($response =~ s/^\s*<return_(object|value)>\s*//) {
    my $type = $1;
    $response =~ s/\s*(.*?)<.return_$type>//;
    my $value = $1;
    if ($type eq 'object') {
      my $new_object = {};
      $new_object->{PRIMCLIENT} = $self->{PRIMCLIENT};
      $new_object->{OBJECT}     = $value;
      bless $new_object, "PrimObject";  #  hard coding is wrong XXX

      push @responses, $new_object;
    }
    else {
      push @responses, $value;
    }
  }

  return wantarray ? @responses : $responses[0];
}

1;
