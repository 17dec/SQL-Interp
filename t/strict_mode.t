# Testing strict mode.

use strict;
use warnings;
use Test::More 'no_plan';
use SQL::Interp ':all';

eval { sql_interp_strict('WHERE x=', 5) };
like($@,qr/failed sql_interp_strict/,"basic strict mode test");



