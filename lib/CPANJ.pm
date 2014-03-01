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
    use Module::Metadata;

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

    our $CONTEXT;

    around 'new', sub {
        my $orig = shift;
        my $self = $orig->(@_);
        $CONTEXT = $self;
        return $self;
    };

    no Mouse;

    sub context { $CONTEXT }

    sub install {
        args my $self,
            my $package => {isa => 'Str'},
        ;

        my $tree = CPANJ::DependencyTree->new(
            c => $self,
        );
        $self->build_tree(tree => $tree, package => $package);
        # use Data::Dumper; warn Dumper($tree);
        warn join(", ", $tree->leaves);
    }

    sub is_installed {
        args my $self, my $package, my $version;
        my $module = Module::Metadata->new_from_module($package, collect_pod => 0);
        if ($module) {
            return version->new(eval { $module->version } || 0) >= version->parse($version);
        } else {
            return 0;
        }
    }

    # supports only module name for now.
    sub build_tree {
        args my $self,
            my $tree,
            my $package => { isa => 'Str' },
            my $version => { default => 0 },
        ;

        return if $package eq 'perl';

        if ($self->is_installed(package => $package, version => $version)) {
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

                my $meta = $dist->meta()
                    or die "Cannot fetch META information for ${package}";

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
        Carp::confess("Missing url") unless defined $url;
        warn CPANJ->context;
        CPANJ->context->logger->info("Getting %s", $url);
        CPANJ->context->ua->get($url);
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

package CPANJ::Distribution {
    use CPAN::DistnameInfo;
    use Smart::Args;
    use CPANJ::Functions;

    use Mouse;

    has uri => (
        is => 'ro',
        isa => 'URI::cpan',
        required => 1,
        handles => [qw(author)],
    );

    has mirror_uri => (
        is       => 'ro',
        isa      => 'Str',
        required => 1,
    );

    has meta => (
        is => 'ro',
        isa => 'CPAN::Meta',
        lazy => 1,
        builder => '_build_meta',
    );

    has workdir => (
        is => 'ro',
        lazy => 1,
        builder => '_build_workdir',
    );

    no Mouse;

    sub name { shift->uri->dist_name }

    sub _r_path {
        my $self = shift;
        my $path = $self->uri->path;
        $path =~ s{^/\w+/}{};
        $path;
    }

    sub _distname_info {
        my $self = shift;
        CPAN::DistnameInfo->new($self->_r_path);
    }

    # http://ftp.riken.jp/lang/CPAN/authors/id/L/LD/LDS/AcePerl-1.92.meta
    sub meta_url {
        my $self = shift;

        my $ext = $self->_distname_info->extension;
        return ($self->archive_url =~ s/$ext\z/meta/r);
    }

    sub archive_url {
        my $self = shift;

        my $mirror_uri = $self->mirror_uri;
        $mirror_uri =~ s!/\z!!;
        sprintf(
            "%s/%s",
            $mirror_uri, $self->pathname
        );
    }

    sub pathname {
        my $self = shift;

        sprintf(
            "authors/id/%s/%s/%s",
            substr($self->uri->author, 0, 1),
            substr($self->uri->author, 0, 2),
            $self->_r_path,
        );
    }

    sub _build_meta {
        my $self = shift;

        my $meta_url = $self->meta_url();
        my $res = CPANJ->context->http_get($meta_url);
        my $meta;
        if ($res->is_success) {
            if ($res->content =~ /\A\s*{/) {
                $meta = CPAN::Meta->load_json_string($res->content);
            } else {
                $meta = CPAN::Meta->load_yaml_string($res->content);
            }
        } else {
            # Some distribution does not include META.yml in distribution.
            # e.g. XML::SAX::Base
            $self->logger->warn("Cannot fetch %s: %s", $meta_url, $res->status_line);
            return;
        }

        if ($meta && !$meta->dynamic_config) {
            return $meta;
        } else {
            # dynamic_config makes installation slow.
            # It's really slow.
            logger->info("%s requires dynamic_config(version: %s)", $meta->name, $meta->version);

            if ($meta) {
                c->install_configure_deps($meta);
            }

            my $workdir = $self->workdir();
            $workdir->configure();
            return $workdir->load_mymeta();
        }
    }

    sub _build_workdir {
        my $self = shift;

        my $local_path = c->archive_cache_dir->child($self->pathname);
        $local_path->parent->mkpath;

        unless (-f $local_path) {
            $self->logger->info("Downloading %s", $self->pathname);

            my $fh = IO::File::AtomicChange->new($local_path, 'w');
            my $res = c->ua->request(
                url => $self->archive_url(),
                write_file => $fh,
            );
            $res->is_success or die;
            $fh->close;
        }

        local $Archive::Any::Lite::IGNORE_SYMLINK = 1; # for safety
        my $archive = Archive::Any::Lite->new($local_path);
        my $extract_dir = c->workdir_base;
        my $workdir_dir;
        if ($archive->is_impolite) {
            $extract_dir = $extract_dir->child($self->name . '-' . $self->version);
            $workdir_dir = c->workdir_base->child($extract_dir->basename);
        } else {
            my $base = [File::Spec->splitdir([$archive->files]->[0])]->[0];
            $workdir_dir = c->workdir_base->child($base);
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
            CPANJ->context->logger->critical("There is no Build.PL or Makefile.PL: %s", $self->directory);
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
    use CPAN::Common::Index::MetaDB;
    use Smart::Args;

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
            CPAN::Common::Index::MetaDB->new()
        },
    );

    has mirror_uri => (
        is => 'rw',
        default => sub { 'http://ftp.riken.jp/lang/CPAN/' },
    );

    no Mouse;

    sub search_distribution_from_package_name {
        args my $self, my $package_name;
        my $result = $self->index->search_packages({package => $package_name});
        if ($result) {
            return CPANJ::Distribution->new(
                uri        => URI->new($result->{uri}),
                mirror_uri => $self->mirror_uri,
            );
        } else {
            return undef;
        }
    }
}


1;
__END__

=head1 NOTES

=over 4

=item Some distribution doesn't have a META file in CPAN mirror.

http://ftp.riken.jp/lang/CPAN//authors/id/G/GR/GRANTM/XML-SAX-Base-1.08.meta does not exist.

=back
