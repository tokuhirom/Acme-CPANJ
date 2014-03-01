use strict;
use warnings;
use utf8;
use Test::More;
use CPANJ;

# cpan:///distfile/AMBS/ExtUtils/ExtUtils-CBuilder-0.280212.tar.gz

my $dist = CPANJ::Distribution->new(
    uri => URI->new('cpan:///distfile/AMBS/ExtUtils/ExtUtils-CBuilder-0.280212.tar.gz'),
    mirror_uri => 'http://ftp.riken.jp/lang/CPAN/',
);
is $dist->archive_url, 'http://ftp.riken.jp/lang/CPAN/authors/id/A/AM/AMBS/ExtUtils/ExtUtils-CBuilder-0.280212.tar.gz';
is $dist->meta_url, 'http://ftp.riken.jp/lang/CPAN/authors/id/A/AM/AMBS/ExtUtils/ExtUtils-CBuilder-0.280212.meta';

done_testing;

