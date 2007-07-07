use ExtUtils::MakeMaker;

WriteMakefile(
    NAME         => 'SQL::Interp',
    VERSION_FROM => 'lib/SQL/Interpolate.pm',
    PL_FILES     => {} # ignore Build.PL
);
