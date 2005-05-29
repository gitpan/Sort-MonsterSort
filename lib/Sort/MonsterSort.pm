package Sort::MonsterSort;
use strict;
use warnings;

require 5.006_001;

our $VERSION = '0.01';

use File::Temp 'tempdir';
use Fcntl qw( :DEFAULT );
use Carp;

### Coding convention:
### Public methods use hash style parameters except when to do so would cause 
### a significant performance penalty.  The parameter names are prepended with
### a dash, e.g. '-foo'.  When it is necessary to modify a parameter value
### for use, it is copied into a similarly named variable without a dash: e.g.
### $self->{-working_dir} gets copied to $self->{workdir}.

### The maximum size that temp files are allowed to attain.
use constant MAX_FS => 2 ** 31; # 2 Gbytes;

##############################################################################
### Constructor
##############################################################################
sub new {
    my $class = shift;
    my $self = bless {}, ref($class) || $class;
    $self->_init_sort_monstersort(@_);
    return $self;
}

my %init_defaults = (
    -sortsub                => undef,
    -working_dir            => undef,
    -line_separator         => undef,
    -cache_size             => 10_000,
    ### The number of sortfiles at one level.  Can grow.  See further comments
    ### in _consolidate_one_level() 
    max_sortfiles           => 10,
    ### Flag indicating that the sorting process has finished.
    consolidation_complete  => 0,
    ### Keep track of position when reading back from tempfiles.
    outplaceholder          => 0,
    );

##############################################################################
### Initialize a Sort::MonsterSort object.
##############################################################################
sub _init_sort_monstersort {
    my $self = shift;
    %$self = (%init_defaults, %$self);
    while (@_) {
        my ($var, $val) = (shift, shift);
        croak("Illegal parameter: '$var'") 
            unless exists $init_defaults{$var};
        $self->{$var} = $val;
    }

    $self->{workdir} = $self->{-working_dir};
    unless (defined $self->{workdir}) {
        $self->{workdir} = tempdir( CLEANUP => 1 ); 
    }
    
    $self->{sortsub} = defined $self->{-sortsub} ?
        $self->{-sortsub} : sub { $a cmp $b };

    ### Items are stored in the input_cache until
    ### _write_input_cache_to_tempfile() is called.
    $self->{input_cache}  = [];
    ### A place for tempfile filehandles to accumulate. 
    $self->{sortfiles}    = [];
    $self->{sortfiles}[0] = [];
    ### A cache for sorted items read back from disk.
    $self->{outbuffer}    = [];
}

##############################################################################
### Feed one or more items to the MonsterSort object.
##############################################################################
sub feed {
    my $self = shift;
    push @{ $self->{input_cache} }, @_;
    return unless @{ $self->{input_cache} } >= $self->{-cache_size};
    $self->_write_input_cache_to_tempfile;
}

my %burp_defaults = (
    -outfile => 'sorted.txt',
    );

##############################################################################
### Retrieve items in sorted order.
##############################################################################
sub burp {
    my $self = shift;
    
    ### Digest everything that's been fed to the monster before burping.
    $self->_consolidate_sortfiles('final')
        unless $self->{consolidation_complete};
        
    ### If called with arguments, we must be printing everything to an
    ### outfile.
    if (@_) {
        my %args;
        while (@_) {
            my ($var, $val) = (shift, shift);
            croak("Illegal parameter: '$var'") 
                unless exists $burp_defaults{$var};
            $args{$var} = $val;
        }
        sysopen(OUTFILE, $args{-outfile}, O_CREAT | O_EXCL | O_WRONLY )
            or croak ("Couldn't open outfile '$args{-outfile}': $!");
        for my $source_fh (@{ $self->{sortfiles}[-1] }) {
            while (<$source_fh>) {
                print OUTFILE 
                    or croak("Couldn't print to '$args{-outfile}': $!");
            }
        }
        close OUTFILE or croak("Couldn't close '$args{-outfile}': $!");
    }
    ### If called without arguments, burp back one item at a time.
    else {
        ### While there's nothing in the output buffer...
        while (!@{ $self->{outbuffer} }) {
            my $outbuffer = $self->{outbuffer};
            ### Eject from the loop if there's no more data.
            return unless my $fh = $self->{sortfiles}[-1][0];

            seek($fh, $self->{outplaceholder}, 0);
            local $/ = $self->{-line_separator} 
                if defined $self->{-line_separator};
            for (1 .. $self->{-cache_size}) {
                if (my $entry = (<$fh>)) {
                    push @$outbuffer, $entry;
                }
                else {
                    close $fh or croak("Couldn't close file '$fh': $!");
                    shift @{ $self->{sortfiles}[-1] };
                    $self->{outplaceholder} = 0;
                    undef $fh;
                    last;
                }
            }
            $self->{outplaceholder} = tell $fh 
                if defined $fh;
        }

        ### Return a sorted item.  If there aren't any items left, the call
        ### terminates, resulting in a return value of undef.
        return shift @{ $self->{outbuffer} }
            if @{ $self->{outbuffer} };
    }
}

##############################################################################
### Flush the items in the input cache to a tempfile, sorting as we go.
##############################################################################
sub _write_input_cache_to_tempfile {
    my $self = shift;
    return unless @{ $self->{input_cache} };
    my $tmp = File::Temp->new(
        DIR => $self->{workdir},
        UNLINK => 1,
    );  
    push @{ $self->{sortfiles}[0] }, $tmp;
    if ($self->{-sortsub}) {
        my $sortsub = $self->{sortsub};
        for (sort $sortsub @{ $self->{input_cache} }) {
            print $tmp $_
                or croak("Print to $tmp failed: $!");
        }
    }
    else {
        for (sort @{ $self->{input_cache} }) {
            print $tmp $_
                or croak("Print to $tmp failed: $!");
        }
    }
    $self->{input_cache} = [];
    $self->_consolidate_sortfiles
        if @{ $self->{sortfiles}[0] } >= 10;
}       

##############################################################################
### Consolidate sortfiles by interleaving their contents.
##############################################################################
sub _consolidate_sortfiles {
    my $self = shift;
    my $final = shift || '';

    $self->_write_input_cache_to_tempfile;
    
    ### Higher levels of the sortfiles array have been through more
    ### stages of consolidation.  
    ###
    ### If this is the last sort, we need to end up with one final group of 
    ### sorted files (which, if concatenated, would create one giant 
    ### sortfile).
    ### 
    ### The final sort is available as an array of filehandles: 
    ### @{ $self->{sortfiles}[-1] }
    for my $input_level (0 .. $#{$self->{sortfiles} }) {
        if ($final) {
            $self->_consolidate_one_level($input_level);
        }
        elsif ( @{ $self->{sortfiles}[$input_level] } >
            $self->{max_sortfiles}) 
        {
            $self->_consolidate_one_level($input_level);
        }
    }
    $self->{consolidation_complete} = 1 if $final;
}

##############################################################################
### Do the hard work for _consolidate_sortfiles().
##############################################################################
sub _consolidate_one_level {
    my $self = shift;
    my $input_level = shift;
    
    my $sortsub = $self->{sortsub};
    local $/ = $self->{-line_separator} if $self->{-line_separator};
    
    ### Offload filehandles destined for consolidation onto a 
    ### lexically scoped array.  When it goes out of scope, the temp files
    ### are supposed to delete themselves (but don't, for some reason, so we
    ### close them explicitly).
    my $filehandles_to_sort = $self->{sortfiles}[$input_level];
    $self->{sortfiles}[$input_level] = [];
    
    ### Create a holder for the output filehandles if necessary.
    if (!defined $self->{sortfiles}[$input_level + 1]) {
        $self->{sortfiles}[$input_level + 1] = [];
    }
    
    my %in_buffers;
    my %bookmarks;
    my @outfiles;
    ### Get a new outfile
    my $outfile = File::Temp->new(
        DIR => $self->{workdir}, 
        UNLINK  => 1
        );
    push @outfiles, $outfile;
    
    my $num_filehandles = @$filehandles_to_sort;
    my $max_lines = int($self->{-cache_size} / $num_filehandles) || 1;

    $in_buffers{$_} = [] for (0 .. $#$filehandles_to_sort);
    $bookmarks{$_}  = 0  for (0 .. $#$filehandles_to_sort);
    
    while (%in_buffers) {
        ### Read $max_lines (typically 1000) entries per input file into 
        ### buffers. 
        foreach my $file_number (keys %in_buffers) {
            my $fh = $filehandles_to_sort->[$file_number];
            seek($fh, $bookmarks{$file_number}, 0);
            for (1 .. $max_lines) {
                if (my $entry = (<$fh>)) {
                    push @{ $in_buffers{$file_number} }, $entry;
                }
                else {
                    last;
                }
            }
            $bookmarks{$file_number} = tell $fh;
            ### We've attempted to fill the buffer.
            ### If there's nothing in the buffer, we've exhausted the source
            ### file, so make the buffer go away. 
            delete $in_buffers{$file_number} 
                unless @{ $in_buffers{$file_number} };
        }
    
        ### Get the lowest of all the last lines from the input_buffers.
        ### All items less than or equal to this value in sort order are 
        ### guaranteed to reside in the input_buffers, so we can safely 
        ### sort them.
        my @high_candidates;
        for (values %in_buffers) {
            push @high_candidates, $_->[-1] if defined $_->[-1];
        }
        @high_candidates = $self->{-sortsub} ?
                           (sort $sortsub @high_candidates) :
                           (sort @high_candidates); 
        my $highest_allowed = $high_candidates[0];
        
        my @batch;

        ### Capture a batch of items from the input_buffers.  All the items in
        ### the batch will be lower in sorted order than items yet to enter
        ### the buffer. 
        ### Note: The only difference between these two blocks is the
        ### performance-killing conditional in the first.
        if ($self->{-sortsub}) {
            foreach my $input_buffer (values %in_buffers) {
                LINE: while (my $line = shift @$input_buffer) {
                    ### If true, the item lies outside of the allowable
                    ### boundaries.  Put it back in the queue and skip to 
                    ### the next input_buffer.
                    if (
                        (sort $sortsub ($line, $highest_allowed))[0] eq $highest_allowed
                        and $line ne $highest_allowed) 
                    {
                        unshift @$input_buffer, $line;
                        last LINE;
                    }
                    push @batch, $line;
                }
            }
        }
        else {
            foreach my $input_buffer (values %in_buffers) {
                LINE: while (my $line = shift @$input_buffer) {
                    if ($line gt $highest_allowed) {
                        unshift @$input_buffer, $line;
                        last LINE;
                    }
                    push @batch, $line;
                }
            }
        }
        
        @batch = $self->{-sortsub} ? 
                 (sort $sortsub @batch) :
                 (sort @batch);
        my $write_buffer = join '', @batch;
        
        ### Start a new outfile if writing the contents of the buffer to the
        ### existing outfile would cause it to grow larger than the maximum
        ### allowed filesize.
        seek($outfile, 0, 2); # EOF
        my $filelength = tell $outfile;
        if ((length($write_buffer) + $filelength) > MAX_FS ) {
            undef $outfile;
            $outfile = File::Temp->new(
                DIR => $self->{workdir},
                UNLINK  => 1
                );
            push @outfiles, $outfile;
        }
        
        print $outfile $write_buffer;
    }
    
    ### Explicity close the filehandles that were consolidate; since they're
    ### tempfiles, they'll unlink themselves.
    close $_ for @$filehandles_to_sort;
    
    ### Add the filehandle for the outfile(s) to the next higher level of the
    ### sortfiles array.
    push @{ $self->{sortfiles}[$input_level + 1] }, 
        @outfiles;
    ### If there's more than one outfile, we're exceeding the 
    ### max filesize limit.  Increase the maximum number of files required 
    ### to trigger a sort, so that we don't sort endlessly.
    $self->{max_sortfiles} += ($#outfiles);
}

1;

__END__

=head1 NAME

Sort::MonsterSort - Sort huge collections

=head1 VERSION

0.01

=head1 WARNING

This is ALPHA release software.  The interface may change.

=head1 SYNOPSIS

    my $monster = Sort::MonsterSort->new;
    while (<HUGEFILE>) {
        $monster->feed( $_ );
    }
    $monster->burp( -outfile => "sorted.txt");;

=head1 DESCRIPTION

Use Sort::MonsterSort when you have a collection which is too large to sort
in-memory.

=head1 METHODS

=head2 new()

    my $sorter = sub { $Sort::MonsterSort::b <=> $Sort::MonsterSort::a }';
    my $monster = Sort::MonsterSort->new(
        -sortsub         => $sorter,          # default sort: standard lexical
        -working_dir     => $temp_directory,  # default: see below
        -line_separator  => $special_string,  # default: "\n"
        -cache_size      => 100_000,          # default: 10_000;
        );

Create a Sort::MonsterSort object.

=over

=item -sortsub

A sorting subroutine.  Avoid using a sortsub if you can -- MonsterSort is
faster if it can use standard lexical sorting.  Be advised that you MUST use
$Sort::MonsterSort::a and $Sort::MonsterSort::b instead of $a and $b in your
sub.  

=item -working_dir

The directory where the temporary sortfiles will reside.  By default, this
directory is generated using L<File::Temp|File::Temp>'s tempdir() command.

=item -line_separator

The delimiter which terminates every item.  MonsterSort leaves it up to you to
tack the right line_separator onto each item (feeding MonsterSort is analogous
to print()ing to a self-sorting filehandle).  See the perlvar documentation
for $/.

=item -cache_size

The size of MonsterSort's cache, in sortable items.  Set this as high as you
can for faster performance.

=back

=head2 feed()

    $monster->feed( @items );

Feed a list of sortable items to your Sort::MonsterSort object.  Periodic
pauses occur normally during feeding as MonsterSort digests what it has been fed so far.

=head2 burp()

    while (my $stuff = $monster->burp) {
        chomp $stuff;
        &do_stuff_with( $stuff );
    }
    # or...
    $monster->burp( -outfile => 'sorted.txt' );

If you call burp() with no arguments, it returns items one by one in sorted
order.  It may take a little while for the first item to appear.

If you call burp with the parameter -outfile specified, it will write all
items to that outfile in sorted order.

=head1 DISCUSSION

=head2 The monstersort algorithm

Cache sortable items in memory.  Every X items, sort the cache and empty it
into a temporary sortfile.  As sortfiles accumulate, consolidate them
periodically by interleaving their contents into larger sortfiles.  Use
caching during the interleaving process to minimize disk I/O.  Complete the
sort by emptying the cache then interleaving the contents of all existing
sortfiles.

=head1 BUGS

Please report any bugs or feature requests to
C<bug-sort-monstersort@rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Sort-MonsterSort>.

=head1 AUTHOR

Marvin Humphrey E<lt>marvin at rectangular dot comE<gt>
L<http://www.rectangular.com>

=head1 COPYRIGHT

Copyright (c) 2005 Marvin Humphrey.  All rights reserved.
This module is free software.  It may be used, redistributed and/or 
modified under the same terms as Perl itself.

=cut

