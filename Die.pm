#!/usr/bin/perl -w
use strict;

package Die;

# Builds dice for games.

# Takes number of sides, defaults to 6.  Negative numbers will confuse rolls.
sub new {
  my $class = shift;
  my $self = {};
  bless $self, $class;

  $self->{sides} = shift || 6;

  return $self;
}

sub roll {
  my $self = shift;
  my $rand = rand;

  $rand = $rand * $self->{sides} + 1;  # a random number between 1 and sides
  $rand =~ s/\..*//;                   # truncate the decimal part
  return $self->{value} = $rand;
}

# One stop accessor.  Looks up value and sides.  Dies for others.

sub AUTOLOAD {
  my $self = shift;
  my $new_setting = shift;

  use vars qw($AUTOLOAD);
  my $var = $AUTOLOAD;    # starts out like Die::sides
  $var =~ s/^(.*):://;    # remove class name
  my $class = $1;

  if (defined $self->{$var}) {
    if (defined $new_setting) {
      $self->{$var} = $new_setting;
    }
    else {
      return $self->{$var};
    }
  }
  elsif ($var eq "DESTROY") {}
  else {
    die "Attempt to reference undefined attribute $var of class $class\n";
  }
}

1;
