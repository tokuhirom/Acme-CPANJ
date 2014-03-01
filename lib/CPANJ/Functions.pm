package CPANJ::Functions;
use strict;
use warnings;
use utf8;
use parent qw(Exporter);

our @EXPORT = qw(logger c);

sub c() { CPANJ->context }
sub logger() { c->logger }

1;

