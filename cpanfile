my $distmeta = {
  authors => ['Nicolas Mendoza <mendoza@pvv.ntnu.no>'],
  resources => {
    license => ['http://dev.perl.org/licenses/'],
    bugtracker  => {
      web    => 'https://github.com/nicomen/mojo-useragent-cached/issues',
    },
    repository  => {
      url  => 'git://github.com/nicomen/mojo-useragent-cached.git',
      web  => 'http://github.com/nicomen/mojo-useragent-cached',
      type => 'git',
    },
  },
  prereqs => {
    runtime => {
      requires => {
        'Algorithm::LCSS' => 0,
        'CHI' => 0,
        'Data::Serializer' => 0,
        'Devel::StackTrace' => 0,
        'English' => 0,
        'File::Basename' => 0,
        'File::Path' => 0,
        'File::Spec' => 0,
        'List::Util', '1.29' => 0,
        'Mojolicious', '7.15' => 0,
        'POSIX' => 0,
        'Readonly' => 0,
        'String::Truncate' => 0,
        'Time::HiRes' => 0,
        'perl' => '5.010001',
      },
    },
    configure => {
      requires => {
        'ExtUtils::MakeMaker' => '6.59',
      },
    },
    build => {
      requires => {
        'Module::Install' => 0,
      },
    },
    test => {
      requires => {
        'IO::Compress::Gzip' => 0,
        'Test::More' => 0,
        'Time::HiRes' => 0,
      },
    },
  },    
};
