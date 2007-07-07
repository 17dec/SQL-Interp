use Module::Build;

Module::Build->new(
    module_name => 'SQL::Interp',
    license => 'perl',
    requires => {
        DBI   => 1.00,
    },
    recommends => {
        Text::Balanced => '1.87',
        Filter::Simple => 0,
        Scalar::Util   => 0
    },
    dist_author => [ 'David Manura (http://math2.org/david/contact)' , 'Mark Stosberg <mark@summersault.com>' ],
)->create_build_script();
