# test various aspects of the distribution

#!/usr/bin/env perl -T

use strict;
use warnings;

use Test::More tests => 1;

# list of all modules
my @modules = (
    'SQL::Interp',
    'DBIx::Interp',
);

my %version_exist;
for my $module (@modules) {
    eval "require $module";
    next if $@;
    my $version = $module->VERSION;
    $version_exist{$version} = 1;
}

ok(scalar keys %version_exist == scalar @modules, 'module versions match');

