requires 'perl', '5.008001';
requires 'CPAN::Common::Index';
requires 'URI::cpan';
requires 'ExtUtils::MakeMaker';
requires 'Module::Build';
requires 'Log::Pony';
requires 'File::Which';
requires 'App::cpanminus';
requires 'File::HomeDir';
requires 'Path::Tiny';
requires 'Smart::Args';
requires 'CPAN::DistnameInfo';
requires 'lib::core::only';
requires 'Archive::Any::Lite';
requires 'Parallel::Fork::BossWorkerAsync';

on 'test' => sub {
    requires 'Test::More', '0.98';
};

