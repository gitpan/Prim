#!/usr/bin/perl
$VERSION = "0.01";

use strict;

=head1 NAME

PrimServer - turns your script into a socket based prim server

=head1 SYNOPSIS

  use PrimServer;

  PrimServer->new('hello.somecompany.com',
                  'file.acl',
                  hello => { CODE => \&hello_sub,
                             DOC  => 'Greets you as you greeted it.'
                           },
  );

  # echos its name followed by its arguments
  sub hello_sub {
    return "hello_sub ", @_;
  }

See the source code file called 'server' for a more involved example.

=head1 DESCRIPTION

For a better example of how to use this module see the script called
server in the distribution directory.

If you want to serve objects, look at PrimObjectServer.pm instead
of this module.

A prim server is a participant in the Perl Remote Invocation of Methods
paradigm, which allows one perl script to run things inside another
perl interpreter either on the same box or remotely (remote prim
has not yet been implemented).

To reconstruct yourself as a prim server, call the PrimServer
constructor with the name you want to be known by and a hash containing
the external names of your exposed methods as keys and hashes with
CODE and DOC keys as values.  CODE's value must be a valid code reference.
DOC's value should be some useful description of what you take and
return, for the benefit of the caller.  The constructor never returns.
Any valid requests from clients are dispatched to the functions you named
by its internal infinite connection accepting loop.

It is a good idea to use dots in the name of your server (the first
argument to the constructor).  This avoids name conflicts.
I suggest you use the Java convention of ending the name with your
company's registered domain name.  What you put before that could
be for internal use.  For example the above server might register
as hello.europeansystems.somecompany.com.  The first part is the simple
name, the middle part contains company specific categories, the final
part is the company's registered domain.  When network discovery methods
are added, the dots will be used to help them.

The observant reader will have noticed by now that there are no remote
objects mentioned above.  If you need to serve objects, see
PrimObjectServer.pm.  This avoids the need for you to roll your own.

Keep in mind that you cannot use the names Prim_constructor or
_Prim_discover for function names in your API, since these are used on
the client side.  Other methods which perl invokes magically are also
unavailable as remote methods (since you and the client are using them
in their normal manner).

There is currently no security.  Anyone who can see your box can run
any method you name.  Of course, the method itself could have some
authentication.  In the future I would like to incorporate this into
the server.  You would either provide a more complex API structure
or a directory name where that information could be found.  I'm open
to suggestions.

=head1 INTERNALS

The server made on your behalf by this script uses the following scheme.
It binds a socket to an ephemeral port, writes that port number in
/tmp/name.prim (where name is the one you passed to new), and goes
into an infinite connection accepting loop.  For each connection a
new child is forked.  Requests are stateless, so after receiving a
caller request and sending the reply, the child server dies.
(PrimObjectServer.pm works differently.)

All requests and responses use the prim protocols.  There are described
in the protocols file in the distribution directory.  To sum up, they
are valid xml with the root tag of prim.  The ending </prim> tag
is used as a sentinal value.  All packets must be newline terminated.

=head1 BUGS

Though the connection loop forks, it does not time out.  A client
could fail to complete a valid request.  For honest clients, their own
time out should be enough to fix this, but nefarious clients could
use the lack of a time out to conduct a denial of service attack.

There is no way to shutdown a PrimServer gracefully.  That in turn means
that there is no way to deregister the server (by removing its /tmp prim
file), so clients will receive 'Connection refused' instead of
'No such server up at this time'.

At this point, due to the implementation of PrimClient.pm, only the localhost
can provide prim services.

=head1 AUTHOR

Phil Crow, philcrow2000@yahoo.com

=cut

package PrimServer;

use IO::Socket;

  use Data::Dumper;

my $xmlheader = "<?xml version='1.0' ?>";
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
  my $class     = shift;
  my $name      = shift;
  my $acl_file  = shift;
  my %api       = @_;

  my $self = {};

  bless $self, $class;

  # Walk the api checking for documentation strings?
  # No, we'll depend on people complaining when doc requests don't work.

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

  $service_name = $name;  # this variable is used in the cleaner routine
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

      if ($childpid) {
        next;
      }
      else {
        my $request;
        $client->autoflush(1);
        while (<$client>) {
          # print;
          chomp;
          $request .= $_;
          last if (m!</prim>!);
        }
        $self->{ACL} = build_acl($self->{ACL_FILE});

        # find host name, this may not be secure

        my $sockaddr = getsockname($client);
        my ($port, $address) = sockaddr_in($sockaddr);
        my ($hostname) = gethostbyaddr($address, AF_INET);

        my $answer = _process($self, $request, $hostname);
        print $client "$answer\n";
        exit 0;  # this closes the socket
      }
    }
  }

}

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
# These requests are referred to the _send_documentation subroutine.

# For the return value two forms are used:
#   1. for normal returns the form is
#      <prim><return_from name='method'><return_value>value</return_value>...
#      </return_from></prim>
#   2. for errors (method not found is the only one at preset)
#      <prim><error>text</error></prim>
sub _process {
  my $self     = shift;
  my $request  = shift;
  my $hostname = shift;

  # Begin crude parsing of xml input.  First grab the method name.

  if ($request =~ /<send_documentation/) {
    return send_documentation($self, $request, $hostname);
  }

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

  # If the method exists, call it.  If not, complain.

  if (defined $self->{API}{$method}{"CODE"}) {
    if (valid_acl($method, $hostname, $self->{ACL})) {
      eval { @retvals = $self->{API}{$method}{"CODE"}->(@args) };
      die $@ if ($@);
    }
    else {
      return "$xmlheader<prim><error>Access denied</error></prim>";
    }
  }
  else {
    return "$xmlheader<prim>"
         . "<error>'$method' not supported for client.</error></prim>";
  }

  # build reply

  my $retval = "$xmlheader<prim><return_from name='$method'>";
  foreach (@retvals) {
    $retval .= "<return_value>$_</return_value>";
  }
  $retval .= "</return_from></prim>";

  return $retval;
}

# The format (as shown above) is:
# <prim><send_documentation [name='function']/></prim>
# the name attribute is optional, if omitted you get everything.

sub send_documentation {
  my $self    = shift;
  my $request = shift;
  my $host    = shift;

  my $retval;

  unless (valid_acl("send_documentation", $host, $self->{ACL})) {
    return "<?xml version='1.0' ?><prim><error>Access denied.</error></prim>";
  }

  $request =~ s/^<\?xml.*\?>//;
  $request =~ s/<prim>\s*<send_documentation\s*//;
  $request =~ s!/></prim>!!;
  $request =~ s/name=//;
  $request =~ s/['"]//g;

  my @functions = split /,/, $request;

  $retval = "<?xml version='1.0' ?><prim><documentation>";

# Add acl verification here.

  if (@functions) {
    foreach my $function (@functions) {
      if (valid_acl($function, $host, $self->{ACL})) {
        $retval .= "<method>$function</method>"
                .  "<description>$self->{API}{$function}{'DOC'}</description>";
      }
    }
  }
  else {
    foreach my $function (keys %{$self->{API}}) {
      if (valid_acl($function, $host, $self->{ACL})) {
        $retval .= "<method>$function</method>"
              .  "<description>$self->{API}{$function}{'DOC'}</description>/n";
      }
    }
  }
  return "$retval</documentation></prim>";
}
#  my $method   = shift;
#  my $host     = shift;
#  my $acl_hash = shift;

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
