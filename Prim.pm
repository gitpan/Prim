#!/usr/bin/perl
$VERSION = "0.01";

use strict;

use IO::Socket;

=head1 NAME

Prim - Perl Remote Invocation of Methods (RMI and EJB's for Perl, sort of)

=head1 SYNOPSIS

  use Prim;

  my $hello_obj = Prim->Prim_constructor($service_name, $optional_server_name);
  my @response = $hello_obj->remote_method("arg1", "arg2");

=head1 DESCRIPTION

This module provides the following deception to the caller.
The caller makes a Prim object giving only the registered name of a service
(and possibly a server name).  With the returned object, the caller
calls functions on the remote service through the local object.  The
remote_method can be any method the server exposes in its API.  The
arguments can be anything except references (the server wouldn't be
able to dereference them).

The constructor has a long name to avoid a conflicts with remote method names.
Remote servers cannot use the names Prim_constructor or _Prim_discover
for remote calls.  Other methods which perl invokes magically are also
unavailable as remote methods.

=head1 SUMMARY of INTERNALS

Prim uses AUTOLOAD to pretend to provide the caller's requested method.
Inside AUTOLOAD it calls the call method of its PrimClient object, which
in turn packs the call in xml, connects to the server, delivers the
message, waits for the xml reply, unpacks it into a perl list, and finally
hands it back to AUTOLOAD.  AUTOLOAD delivers that list to the caller
as if it were locally produced.

=head2 EXPORT

This is currently an object oriented module with no exports.

=head1 BUGS

There are no timeouts.

=head1 AUTHOR

Phil Crow, philcrow2000@yahoo.com

=head1 SEE ALSO

The files called client and objectclient in the distribution are examples
of using this and its cousin PrimObject.pm.

=cut

use PrimClient;

package Prim;

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

  my $prim_client = PrimClient->new($ip, $port);

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
       PeerAddr => "$server:5368",
#       PeerPort => 5368,
    ) or last PRIMD_ATTEMPT;

    $remote->autoflush(1);
                          
    # Send the request.
                           
    print $remote "<?xml version='1.0' ?><prim><lookup name='$name'/></prim>\n";
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
      return $server, $portprimd;      # primd always returns loopback as host
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
    $docs =~ s/^\s*<method>(.*?)<.method>\s*<description>(.*?)<.description>//s;
    my $method = $1;
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
  my $method = $Prim::AUTOLOAD;   # hard coding Prim is wrong XXX
  $method =~ s/.*:://;

  my $response;

  $response = $self->{PRIMCLIENT}->call($method, @_);
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
      bless $new_object, "Prim";  #  hard coding is wrong XXX

      push @responses, $new_object;
    }
    else {
      push @responses, $value;
    }
  }

  return wantarray ? @responses : $responses[0];
}

1;
