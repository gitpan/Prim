#!/usr/bin/perl
use strict;

package Multiplier;

# Constructs a simple object which has one attribute.                           
sub new {
  my $class = shift;
  my $number = shift || 2;

  my $self = {};
  bless $self, $class;

  $self->{NUMBER} = $number;
  return $self;
}

# Takes a number, multiplies it by the attribute in the object, returns result. 
sub multiply {
  my $self          = shift;
  my $second_number = shift;
  return $self->{NUMBER} * $second_number;
}

1;
