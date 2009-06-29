use Module::Build;

Module::Build->new(
    module_name => 'SQL::Interp',
    license => 'perl',
    requires => {
        DBI   => 1.00,
        # There were test failures on 5.5 and 5.6. Patches welcome to resolve them
        perl  => '5.8.0',
    },
    recommends => {
        Text::Balanced => '1.87',
        Filter::Simple => 0,
        Scalar::Util   => 0
    },
    create_makefile_pl  => 'traditional',
    dist_author => [ 'David Manura (http://math2.org/david/contact)' , 'Mark Stosberg <mark@summersault.com>' ],
)->create_build_script();
