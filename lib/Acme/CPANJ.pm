package Acme::CPANJ;
use 5.008005;
use strict;
use warnings;

our $VERSION = "0.01";

1;
__END__

=encoding utf-8

=head1 NAME

Acme::CPANJ - It's new $module

=head1 SYNOPSIS

    use Acme::CPANJ;

=head1 DESCRIPTION

Acme::CPANJ is cpanm + parallel execution.

This module aggregates module dependencies in parallel. And then, aggregate/install cpan modules.

For now, cpanj does not supports DarkPAN.

It's silly hack.

=head1 LICENSE

Copyright (C) Tokuhiro Matsuno.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 AUTHOR

Tokuhiro Matsuno E<lt>tokuhirom@gmail.comE<gt>

=cut

