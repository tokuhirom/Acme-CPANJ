package CPAN::Source::DarkPAN;
use strict;
use warnings;
use utf8;
use 5.010_001;

use Moo;

has directory => (
    is => 'ro',
);

has index => (
    is => 'ro',
    required => 1,
);

no Moo;

1;

