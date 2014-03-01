package CPANJ;
use strict;
use warnings;
use utf8;
use 5.010_001;

package CPANJ {
    use Furl;
    use Path::Tiny;
    use File::HomeDir;
    use IO::File::AtomicChange;
    # use Archive::Extract;
    use Smart::Args;
    use Archive::Any::Lite; # ISHIGAKI ware

    use Mouse;
    our $VERSION = "0.01";

    has test => (
        is => 'ro',
        isa => 'Bool',
        default => sub {
            # Test is no longer required by default... Maybe.
            0
        },
    );

    has max_workers => (
        is => 'rw',
        isa => 'Str',
    );

    has logger => (
        is => 'rw',
        default => sub { Log::Pony->new(color => 1, log_level => 'debug') },
    );

    has repositories => (
        is => 'rw',
        lazy => 1,
        default => sub {
            my $self = shift;

            +[
                CPANJ::Repository::Original->new(c => $self)
            ]
        },
    );

    has home_dir => (
        is => 'rw',
        lazy => 1,
        default => sub { Path::Tiny->new(File::HomeDir->my_home) },
    );

    has cpanj_dir => (
        is => 'rw',
        lazy => 1,
        default => sub {
            my $dir = shift->home_dir->child('.cpanj');
            $dir->mkpath;
            $dir;
        }
    );

    has workdir_base => (
        is => 'rw',
        lazy => 1,
        default => sub {
            my $self = shift;
            my $dir = $self->cpanj_dir->child('work-' . Time::HiRes::time());
            $dir->mkpath;
            $dir;
        },
    );

    has 'ua' => (
        is => 'rw',
        default => sub {
            Furl->new(agent => __PACKAGE__ . '/' . $VERSION);
        },
    );

    has archive_cache_dir => (
        is => 'rw',
        default => sub {
            my $self = shift;
            my $dir = $self->cpanj_dir->child('cache');
            $dir->mkpath;
            $dir;
        },
    );

    no Mouse;

    sub install {
        args my $self,
            my $package => {isa => 'Str'},
        ;

        my $tree = CPANJ::DependencyTree->new(
            c => $self,
        );
        $self->build_tree(tree => $tree, package => $package);
        use Data::Dumper; warn Dumper($tree);
    }

    # supports only module name for now.
    sub build_tree {
        args my $self,
            my $tree,
            my $package => { isa => 'Str' },
            my $version => { default => 0 },
        ;

        return if $package eq 'perl';

        if (eval("package Sandbox; use ${package} ${version}; 1;")) {
            $self->logger->info("%s %s is already installed", $package, $version);
            return;
        } else {
            $self->logger->info("Analyzing %s %s", $package, $version);
        }

        return if $tree->seen(package_name => $package);

        for my $repository (@{$self->repositories}) {
            my $dist = $repository->search_distribution_from_package_name(
                package_name => $package,
            );

            if ($dist) {
                return if $dist->name eq 'perl';

                my $meta = $self->fetch_meta(distribution => $dist, repository => $repository);
                if (!$meta || $meta->dynamic_config) {
                    # dynamic_config makes installation slow.
                    # It's really slow.
                    $self->logger->info("%s requires dynamic_config(version: %s, distfile: %s)", $package, $dist->version, $dist->distfile);

                    if ($meta) {
                        $self->install_configure_deps($meta);
                    }

                    my $workdir = $self->get_dist(
                        distribution => $dist,
                        repository => $repository,
                    );
                    $workdir->configure();
                    $meta = $workdir->load_mymeta();
                } else {
                    $self->logger->debug("%s doesn't require dynamic_config", $package);
                }

                my $prereqs = $meta->effective_prereqs->merged_requirements(
                    ['configure', 'build', 'runtime', ($self->test ? 'test' : ())],
                    ['requires', 'recommends'],
                )->as_string_hash;
                $tree->push_meta(distribution => $dist, meta => $meta);
                for my $package (sort keys %$prereqs) {
                    $self->build_tree(
                        tree => $tree,
                        package => $package,
                        version => $prereqs->{$package},
                    );
                }
                return;
            } else {
                # Try next repository
            }
        }
        die "SHOULD NOT REACH HERE";
    }

    sub fetch_meta {
        args my $self,
            my $distribution => { isa => 'CPANJ::Distribution' },
            my $repository,
        ;

        my $meta_url = $distribution->meta_url(repository => $repository);
        my $res = $self->http_get($meta_url);
        if ($res->is_success) {
            if ($res->content =~ /\A\s*{/) {
                CPAN::Meta->load_json_string($res->content);
            } else {
                CPAN::Meta->load_yaml_string($res->content);
            }
        } else {
            # Some distribution does not include META.yml in distribution.
            # e.g. XML::SAX::Base
            $self->logger->warn("Cannot fetch %s: %s", $meta_url, $res->status_line);
            return;
        }
    }

    sub get_dist {
        args my $self, my $distribution, my $repository;

        my $local_path = $self->archive_cache_dir->child(
            'authors/id',
            $distribution->distfile,
        );
        $local_path->parent->mkpath;

        unless (-f $local_path) {
            $self->logger->info("Downloading %s", $distribution->distfile);

            my $fh = IO::File::AtomicChange->new($local_path, 'w');
            my $res = $self->ua->request(
                url => $distribution->archive_url(repository => $repository),
                write_file => $fh,
            );
            $res->is_success or die;
            $fh->close;
        }

        local $Archive::Any::Lite::IGNORE_SYMLINK = 1; # for safety
        my $archive = Archive::Any::Lite->new($local_path);
        my $extract_dir = $self->workdir_base;
        my $workdir_dir;
        if ($archive->is_impolite) {
            $extract_dir = $extract_dir->child($distribution->dist_name . '-' . $distribution->version);
            $workdir_dir = $self->workdir_base->child($extract_dir->basename);
        } else {
            my $base = [File::Spec->splitdir([$archive->files]->[0])]->[0];
            $workdir_dir = $self->workdir_base->child($base);
        }
        if ($archive->is_naughty) {
            $self->error("%s is naughty.", $local_path);
            die "ABORT\n";
        }
        $archive->extract($extract_dir)
            or die $archive->error;
        unless (-d $workdir_dir) {
            # TODO bette diag
            die "Cannot extract to $workdir_dir";
        }
        return CPANJ::WorkDir->new(c => $self, directory => $workdir_dir);
    }

    sub install_configure_deps {
        my ($self, $meta) = @_;
        my $prereqs = $meta->effective_prereqs;
        my $reqs = $prereqs->requirements_for('configure', "requires");
        my @modules = sort $reqs->required_modules;
    }

    sub install_by_cpanm {
        my ($self, @modules) = @_;
        $self->run_cmd(['cpanm', '-l', 'local', @modules]);
    }

    sub run_cmd {
        my ($self, $cmd) = @_;
        $self->logger->info("%s", join(' ', @$cmd));
        system(@$cmd)==0 or die "ABORT\n";
    }

    sub http_get {
        my ($self, $url) = @_;
        $self->ua->get($url);
    }

    sub http_get_simple {
        my ($self, $url) = @_;
        my $res = $self->ua->get($url);
        if ($res->is_success) {
            return $res->content;
        } else {
            $self->logger->critical("%s: %s", $url, $res->status_line);
            die "ABORT\n";
        }
    }
}

package CPANJ::Index::MetaDB {
    use YAML::Tiny;
    use Smart::Args;

    use Mouse;

    has c => (
        is => 'rw',
        required => 1,
    );

    no Mouse;

    # http://cpanmetadb.plackperl.org/v1.0/package/ExtUtils::CBuilder

    # ---
    # distfile: A/AM/AMBS/ExtUtils/ExtUtils-CBuilder-0.280212.tar.gz
    # version: 0.280212

    sub search_distribution_from_package_name {
        args my $self, my $package_name => { isa => 'Str' };

        my $url = "http://cpanmetadb.plackperl.org/v1.0/package/${package_name}";
        my $res = $self->c->http_get($url);
        if ($res->is_success) {
            my $data = YAML::Tiny::Load($res->content);
            my $dist = CPANJ::Distribution->new(
                distfile => $data->{distfile},
                version  => $data->{version},
            );
            return $dist;
        } else {
            if ($res->status eq '404') {
                return undef;
            } else {
                $self->c->error("%s: %s", $url, $res->status_line);
                die "ABORT";
            }
        }
    }
}

package CPANJ::Distribution {
    use CPAN::DistnameInfo;
    use Smart::Args;

    use Mouse;

    has distfile => (
        is => 'ro',
        isa => 'Str',
        required => 1,
    );

    has version => (
        is => 'ro',
        isa => 'Str',
        required => 1,
    );

    has _distname_info => (
        is => 'ro',
        lazy => 1,
        default => sub { CPAN::DistnameInfo->new(shift->distfile) },
    );

    no  Mouse;

    sub name { shift->_distname_info->dist }

    # http://ftp.riken.jp/lang/CPAN/authors/id/L/LD/LDS/AcePerl-1.92.meta
    sub meta_url {
        args my $self, my $repository;
        my $d = $self->_distname_info;

        my $ext = $d->extension;
        my $metafile = ($self->distfile =~ s/$ext\z/meta/r);

        sprintf(
            "%s/authors/id/%s",
            $repository->mirror_uri,
            $metafile
        );
    }

    sub archive_url {
        args my $self, my $repository;

        sprintf(
            "%s/authors/id/%s",
            $repository->mirror_uri,
            $self->distfile
        );
    }
}

package CPANJ::DependencyTree {
    use Smart::Args;
    use Mouse;

    has c => (
        is => 'rw',
        required => 1,
        weak_ref => 1,
    );

    has _seen => (
        is => 'ro',
        default => sub { +{} },
    );

    has _metas => (
        is => 'ro',
        default => sub { +[] },
    );

    has _package_name2dist_name => (
        is => 'ro',
        isa => 'HashRef',
        default => sub { +{ } },
    );

    no Mouse;

    sub seen {
        args my $self, my $package_name;
        $self->_seen->{$package_name};
    }

    sub push_meta {
        args my $self, my $meta => { isa => 'CPAN::Meta' };
        push @{$self->{_metas}}, $meta;

        my $provides = $meta->provides;
        for my $package_name (keys %$provides) {
            $self->_seen->{$package_name}++;
        }
        # {
        #     'Module::Runtime' => {
        #         'version' => '0.014',
        #         'file'    => 'lib/Module/Runtime.pm'
        #     }
        # }

        for my $pkg (keys %{$meta->provides}) {
            $self->_package_name2dist_name->{$pkg} = $meta->name;
        }
    }

    sub leaves {
        args my $self;

        my @dist_names;
        my %seen;
        for my $meta (@{$self->_metas}) {
            push @dist_names, $meta->name;

            my $prereqs = $meta->effective_prereqs->merged_requirements(
                ['configure', 'build', 'runtime', ($self->c->test ? 'test' : ())],
                ['requires', 'recommends'],
            )->as_string_hash;
            for my $pkg (keys %$prereqs) {
                for my $provides_pkg (keys %{$meta->provides}) {
                    $seen{$self->_package_name2dist_name->{$provides_pkg}}++;
                }
            }
        }
        grep { !$seen{$_} } @dist_names;
    }
}

package CPANJ::WorkDir {
    use File::pushd;
    use Mouse;

    has c => (
        is => 'rw',
        required => 1,
        weak_ref => 1,
    );

    has directory => (
        is => 'ro',
        isa => 'Path::Tiny',
        required => 1,
    );

    no Mouse;

    sub configure {
        my $self = shift;

        my $pushd = pushd($self->directory);
        if (-f 'Build.PL') {
            system($^X, 'Build.PL')
                == 0 or die "ABORT\n";
        } elsif (-f 'Makefile.PL') {
            system($^X, 'Makefile.PL')
                == 0 or die "ABORT\n";
        } else {
            $self->c->logger->critical("There is no Build.PL or Makefile.PL: %s", $self->directory);
            die "ABORT\n";
        }
    }

    sub load_mymeta {
        my $self = shift;

        my $pushd = pushd($self->directory);
        if (-f 'MYMETA.json') {
            CPAN::Meta->load_file('MYMETA.json');
        } elsif (-f 'MYMETA.yml') {
            CPAN::Meta->load_file('MYMETA.yml');
        } else {
            die "There is no MYMETA.(json|yml)\n";
        }
    }
}

package CPANJ::Repository::Original {
    use URI;
    use URI::cpan;
    use CPAN::Meta;
    use Log::Pony;

    use Mouse;

    has c => (
        is => 'rw',
        required => 1,
        weak_ref => 1,
    );

    has index => (
        is => 'rw',
        lazy => 1,
        default => sub {
            my $self = shift;
            CPANJ::Index::MetaDB->new(c => $self->c)
        },
        handles => ['search_distribution_from_package_name'],
    );

    has mirror_uri => (
        is => 'rw',
        default => sub { 'http://ftp.riken.jp/lang/CPAN/' },
    );

    no Mouse;
}


1;
__END__

=head1 NOTES

=over 4

=item Some distribution doesn't have a META file in CPAN mirror.

http://ftp.riken.jp/lang/CPAN//authors/id/G/GR/GRANTM/XML-SAX-Base-1.08.meta does not exist.

=back
