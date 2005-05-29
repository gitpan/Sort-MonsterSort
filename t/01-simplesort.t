use strict;
use warnings;

use Test::More qw( no_plan ); 
use File::Spec;

use lib 'lib';
use Sort::MonsterSort;

my @letters = map { "$_\n" } ( 'a' .. 'z' );
my @reversed_letters = reverse @letters;

my $monster = Sort::MonsterSort->new;
my $sort_output = &reverse_letter_test($monster);
is_deeply($sort_output, \@letters, "sort z .. a as a .. z");
undef $monster;

$monster = Sort::MonsterSort->new(
    -sortsub => sub { $Sort::MonsterSort::a cmp $Sort::MonsterSort::b }
);
$sort_output = &reverse_letter_test($monster);
is_deeply($sort_output, \@letters, "... with explicit sortsub");
undef $monster;

$monster = Sort::MonsterSort->new(
    -working_dir => File::Spec->curdir,
);
$sort_output = &reverse_letter_test($monster);
is_deeply($sort_output, \@letters, "... with a different working directory");
undef $monster;

$monster = Sort::MonsterSort->new(
    -cache_size => 2,
);
$sort_output = &reverse_letter_test($monster);
is_deeply($sort_output, \@letters, "... with an absurdly low cache setting");
undef $monster;

sub reverse_letter_test {
    my $monst = shift;
    $monst->feed( $_ ) for @reversed_letters;

    my @sorted;
    while( my $stuff = $monst->burp ) {
        push @sorted, $stuff;
    }
    return \@sorted;
}