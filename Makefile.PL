use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME                => 'Sort::MonsterSort',
    AUTHOR              => 'Marvin Humphrey <marvin at rectangular dot com>',
    VERSION_FROM        => 'lib/Sort/MonsterSort.pm',
    ABSTRACT_FROM       => 'lib/Sort/MonsterSort.pm',
    PL_FILES            => {},
    PREREQ_PM => {
        'Test::More' => 0,
        'File::Temp' => 0,
    },
    dist                => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean               => { FILES => 'Sort-MonsterSort-*' },
);
