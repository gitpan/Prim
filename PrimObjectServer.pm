#!/usr/bin/perl
$VERSION = "0.01";

use strict;

=head1 NAME

PrimObjectServer - turns your script into a socket based object server

=head1 SYNOPSIS

  use PrimObject Server;
  use AnyClassYouNeed;

  sub wrapper_for_AnyClassYouNeed_new {
    return AnyClassYouNeed->new(@_);
  }

  sub helpful_non_object_function {
    # do something interesting to set $something_helpful
    return $something_helpful;
  }

  PrimObject->new('my.registered.name.company.com',
    'file.acl',
    make_object_you_need => { CODE => \&wrapper_for_AnyClassYouNeed_new,
                              DOC  => 'returns an AnyClassYouNeed object'
                            },
    helpful => { CODE => \&helpful_non_object_funtion,
                 DOC  => 'Gives you something helpful',
               }
  );

=head1 DESCRIPTION

For a more useful example look in objectserver in the distribution.

To use this class, first declare any functions you want to expose to your
caller (and any helper functions you don't want your caller to access
directly).  In particular, to expose an object to your caller, simply
write a wrapper function which returns whatever that class's constructor
returns.  (This class and its opposite number on the client side will
create the illusion that the caller is calling functions in the calling
interpreter.  Further, the methods in the server interpreter will think
the user is local.)

When you are ready to become a server, call new on this class with the
name you want your service to have, an access control file name (pass
undef if you don't want access controls), and an API hash in the form
shown.  Keys in the hash are the external names, values are hashes.
Those hashes have two keys (at present).  CODE must be a valid code
reference which the PrimObject will use as a callback.  DOC should tell
a caller what the function does and how to use it.  Try to be as helpful
as possible.

For additional examples see the following scripts:
trivialobjectserver and objectserver which rely on
trivialobjectclient and objectclient 

=head1 INTERNALS

The constructor of this class binds a socket to an ephemeral port,
records that port number in /tmp/your.name.prim, and begins an infinite
loop accepting connections.  For each connection a child is formed.
Typical clients use PrimObject.pm which maintains this connection until
the initial PrimObject goes out of scope or is otherwise destroyed.

All requests must be newline terminated prim requests (which is an
xml protocol).  </prim> is used as the end of request sentinel value.
Responses are formed in the same way, so the client can do the same thing.
See the protocols file in the distribution directory for more details.

=head1 BUGS

There are no timeouts.

=head2 EXPORT

None.

=head1 SEE ALSO

PrimServer.pm is the non-object version of this script.

=head1 AUTHOR

Phil Crow, philcrow2000@yahoo.com

=cut

package PrimObjectServer;

use IO::Socket;

my $xmlheader = "<?xml version='1.0' ?>";
my %objects;  # stores objects client has constructed
my $service_name; # stores service name so sig handler can clean (see cleaner)

=head1 new

Turns your script into a server.  Pass it two things:

=over 4

=item 1.

The name you want others to call your object.

=item 2.

A hash with your exposed function names as keys and code references to
implement those functions as values (the name of the key and the function
may differ).

=back

This function NEVER returns.  It goes into a standard forking accept
loop on the socket it creates.

=cut

sub new {
  my $class    = shift;
  my $name     = shift;
  my $acl_file = shift;
  my %api      = @_;

  my $self = {};

  bless $self, $class;

  # start server on ephemeral port

  my $server = IO::Socket::INET->new(
      Proto     => 'tcp',
      LocalPort => 0,             # kernel assigns one for us
      Listen    => SOMAXCONN,
      Reuse     => 1,
  ) or die "Can't start server on ephemeral port: $!\n";

  my $sockaddr      = getsockname $server;     # ask kernel what we got
  my ($port, $addr) = sockaddr_in($sockaddr);

  #  print "server accepting connections on port $port\n";
  if (open TMPFILE, ">/tmp/$name.prim") {
    print TMPFILE "port $port";
    # eventually we need to print other things here, either:
    #   1. the name of a config directory OR
    #   2. config information
    # I prefer number 1
  }
  close TMPFILE;

  $self->{NAME}     = $name;
  $self->{PORT}     = $port;
  $self->{SERVER}   = $server;
  $self->{API}      = \%api;
  $self->{ACL_FILE} = $acl_file;
  $self->{OBJECTS}  = {};

  $service_name = $name;  # this is used in cleaner below
  $SIG{INT}  = \&cleaner;
  $SIG{QUIT} = \&cleaner;
  $SIG{TERM} = \&cleaner;

  _accept_connections($self);  # never returns

  # never reached

  return $self;
}

# This routine is called for INT, QUIT, and TERM signals.
sub cleaner {
  unlink "/tmp/$service_name.prim";
  exit;
}

# _accept_connections is a standard infinite while loop accepting client
# connections.  It looks for a </call> ending tag on the socket.  On seeing
# that, it passes control to the _process function to make the function call.
# Note that there are no time outs so clients could grab a connection
# and fail to complete a request.  This could lead to a denial of service
# attack on the box.

{
  my $waitpid = 0;

  # collect deceased children
  sub REAPER {
    $waitpid   = wait;
    $SIG{CHLD} = \&REAPER;  # system V turns off the handler after one use
  }

  # This function never returns.  At some point in the future it may return
  # when the process is signaled to stop.

  sub _accept_connections {
    my $self = shift;
    my $server = $self->{SERVER};
    my $client;

    $SIG{CHLD} = \&REAPER;

    for ($waitpid = 0;
         $client  = $server->accept() || $waitpid;
         $waitpid = 0, close $client)
    {
      next if $waitpid and not $client;

      my $childpid = fork();

      if ($childpid) {            # parent goes back to listening
        next;                     # the socket is closed in the for statement
      }
      else {
        $client->autoflush(1);

        # Determine host, so we can enforce host acls.
        my $sockaddr = getsockname($client);
        my ($port, $address) = sockaddr_in($sockaddr);
        my ($hostname) = gethostbyaddr($address, AF_INET);

        # We do this for each child so everyone sees the acl that was
        # in place when their connection started.
        $self->{ACL} = build_acl($self->{ACL_FILE});

        SESSION:
        while (1) {               # connected clients stay connected
          my $request;
          while (<$client>) {     # read the request (must end with a newline)
            # print;
            chomp;
            $request .= $_;
            last if (m!</prim>!); # stop on closing prim tag
          }
          if ($request =~ m!<shutdown/>!) {
            close $client;
            exit 0;
          }
          my $answer = _process($self, $request, $hostname);
          print $client "$answer\n";
        } # end of while 1 which handles a client session

      } # end of else this is the child

    } # end of for loop which forks and collects children

  } # end of sub _accept_connections

} # end of scope containing $waitpid

# _process receives an xml request directly from the client.
# It parses this in the crudest possible way.  A real parser should be used.
# After extracting the caller's method request, it looks in the api hash
# to see if a code reference exists for the method.  If so, it invokes the
# callback, if not it generates a crude (and poorly formatted) error.
# In the callback case, it waits for the return value of the call back
# and packages it in xml.

# The current xml is as follows.  For the call:
# <prim><call_method name='name'><arg_list><arg>one</arg><arg>two</arg>...
# </arg_list></call_method></prim>

# To receive documentation:
# <prim><send_documentation [name='function']/></prim>
# the name attribute is optional, if omitted you get everything.
# These requests are refered to the _send_documentation subroutine.

# For the return value two forms are used:
#   1. for normal returns the form is
#      <prim><return_from name='method'><return_value>value</return_value>...
#      </return_from></prim>
#   2. for errors (method not found is the only one at preset)
#      <prim><error>text</error></prim>
sub _process {
  my $self    = shift;
  my $request = shift;
  my $host    = shift;

  if ($request =~ /<send_documentation/) {
    return send_documentation($self, $request, $host);
  }

  # Begin crude parsing of xml input.  First grab the method name.

  my $header  = $request;
     $header  =~ s/<arg_list>.*//gs;
  my $method  = $header;
     $method  =~ s/.*method name=['"]//;
     $method  =~ s/['"].*$//;

  # Now grab the argument list.

  my $arglist = $request;
     $arglist =~ s/.*<arg_list>//;
     $arglist =~ s!\s*</arg_list>.*!!;
     $arglist =~ s/<arg>//;
     $arglist =~ s/<.arg>$//;
  my @args = split /<.arg>\s*<arg>/, $arglist;
  my @retvals;

  # print "method: $method\n";
  # print "args: @args\n";

  # If the first arg is one of our managed objects, call the method against it.
  # Else, see if the method is one in our API hash.
  # If both fail, send a not supported message.

  if (defined $self->{OBJECTS}{$args[0]}) {
    no strict;
    my $objectref = shift @args;
    eval { @retvals = $self->{OBJECTS}{$objectref}->$method(@args) };
    if ($@) {
      return "$xmlheader<prim><error>$@</error></prim>";
    }
  }
  elsif (defined $self->{API}{$method}{"CODE"}) {
    if (valid_acl($method, $host, $self->{ACL})) {
      @retvals = $self->{API}{$method}{"CODE"}->(@args);
    }
    else {
      return "$xmlheader<prim><error>Access denied.</error></prim>";
    }
  }
  else {
    return "$xmlheader<prim>"
         . "<error>'$method' not supported for client</error></prim>";
  }

  my $retval = "$xmlheader<prim><return_from name='$method'>";
  foreach (@retvals) {
    my $tag;
    if (ref $_) {
      $self->{OBJECTS}{"$_"} = $_;
      $retval .= "<return_object>$_</return_object>";
    }
    else {
      $retval .= "<return_value>$_</return_value>";
    }
  }
  $retval .= "</return_from></prim>";

  return $retval;
}
sub send_documentation {
  my $self    = shift;
  my $request = shift;
  my $host    = shift;
 
  my $retval;

  unless (valid_acl("send_documentation", $host, $self->{ACL})) {
    return "<?xml version='1.0'?><prim><error>Access denied.</error></prim>";
  }

  $request =~ s/^<\?xml.*\?>//;
  $request =~ s/<prim>\s*<send_documentation\s*//;
  $request =~ s!/></prim>!!;
  $request =~ s/name=//;
  $request =~ s/['"]//g;
 
  my @functions = split /,/, $request;
 
  $retval = "<?xml version='1.0' ?><prim><documentation>";
 
  if (@functions) {
    foreach my $function (@functions) {
      $retval .= "<method>$function</method>"
              .  "<description>$self->{API}{$function}{'DOC'}</description>";
    }
  }
  else {
    foreach my $function (keys %{$self->{API}}) {
      $retval .= "<method>$function</method>"
              .  "<description>$self->{API}{$function}{'DOC'}</description>/n";
    } 
  }
  return "$retval</documentation></prim>";
}

sub valid_acl {
  my $method   = shift;
  my $host     = shift;
  my $acl_hash = shift;

  if (not defined $acl_hash) {  # server author wanted no security
    return 1;
  }

  # All methods are handled together.
  if (defined $acl_hash->{ALL})  {
    if ($acl_hash->{ALL} eq 'allow')                 { return 1; }
    else                                             { return 0; }
  }

  # All hosts are handled together for this method.
  elsif (defined $acl_hash->{$method}{ALL}) {
    if  (defined $acl_hash->{$method}{allow})        { return 1; }
    else                                             { return 0; }
  }

  # All hosts handled individually.
  elsif (defined $acl_hash->{$method}{allow}) {
    if  (defined $acl_hash->{$method}{$host})        { return 1; }
    else                                             { return 0; }
  }
  else {  # if its not allow, we deny
    if  (defined $acl_hash->{$method}{$host})        { return 0; }
    else                                             { return 1; }
  }
}

sub build_acl {
  my $file              = shift;
  my %acl_hash;
  my $all_can_happen    = 1;
  my $active_method     = "";
  my $active_allow_deny = "";

  if (not defined $file) { return undef; }

  open ACL, "$file" or die "Couldn't read ACL file $file\n";

  while (<ACL>) {
    next if (/^#/);     # skip comments which start with a pound sign
    next if (/^\s*$/);  # skip blank lines;
    chomp;
    if ($all_can_happen and /^ALL\s+(.*)/) {
      my $allow_deny = $1;
      $acl_hash{ALL} = $allow_deny;
      last;
    }
    $all_can_happen = 0;
    if (s/^h(ost)?://) {
      next unless $active_method;
      if (/ALL/) {
        $acl_hash{$active_method}{ALL} = 1;
        $active_method = "";
        $active_allow_deny = "";
      }
      else {
        $acl_hash{$active_method}{$_} = 1;
      }
    }
    else {  # no colon prefix, must be method name
      ($active_method, $active_allow_deny) = split;
      $acl_hash{$active_method}{$active_allow_deny} = 1;
    }
  }

  close ACL;

  return \%acl_hash;
}

1;

