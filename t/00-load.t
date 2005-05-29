use Test::More tests => 1;

use lib 'lib';

BEGIN {
use_ok( 'Sort::MonsterSort' );
}

diag( "Testing Sort::MonsterSort $Sort::MonsterSort::VERSION, Perl 5.008005, /usr/local/bin/perl" );
