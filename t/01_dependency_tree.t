use strict;
use warnings;
use utf8;
use Test::More;
use CPANJ;

my $c = CPANJ->new();

my $tree = CPANJ::DependencyTree->new(c => $c);
$tree->push_meta(meta => CPAN::Meta->new(+{
    version => '0.01',
    name => 'a',
    provides => {
        'X' => {
            version => 0.01,
            file => 'lib/X.pm',
        },
    },
    prereqs => {
        'runtime' => {
            requires => {
                'Y' => '0.01',
            }
        },
    },
}));
$tree->push_meta(meta => CPAN::Meta->new(+{
    version => '0.01',
    name => 'b',
    provides => {
        'Y' => {
            version => 0.01,
            file => 'lib/Y.pm',
        },
    },
    prereqs => {
        'runtime' => {
            requires => {
                'Z' => '0.01',
            }
        },
    },
}));
$tree->push_meta(meta => CPAN::Meta->new(+{
    version => '0.01',
    name => 'c',
    provides => {
        'Z' => {
            version => 0.01,
            file => 'lib/Z.pm',
        },
    },
}));
my @leaves = $tree->leaves;
is join(' ', @leaves), 'c';

done_testing;

