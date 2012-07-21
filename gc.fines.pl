#!/usr/bin/perl

use warnings;
use strict;

use Text::CSV;
use Data::Dumper;
use OpenILS::Utils::Cronscript;
use OpenSRF::AppSession;
use OpenSRF::EX qw(:try);
use Encode;

my $csv = Text::CSV->new({ allow_loose_quotes => 1, allow_loose_escapes => 1 });

my $lines = 0;

my ($fh, $row);
open($fh, "<:utf8",$ARGV[0]) or die("She kinnae do't, Cap'n!");

my $script = OpenILS::Utils::Cronscript->new;
my $authtoken = $script->authenticate(
    {
        username => 'grundycirc',
        password => 'asdlkf74dfs',
        workstation => 'GCPL-Migration'
    }
);

do {
    $lines++;
    if ($lines == 1) {
        # The input file has a single line at the top describing the
        # file contents.
        $row = $csv->getline($fh);
    } elsif ($lines == 2) {
        $row = $csv->getline($fh);
        $csv->column_names(@{$row});
    } elsif ($lines > 2) {
        $row = $csv->getline_hr($fh);
        if (defined($row)) {
            my $copy_barcode = $row->{CopyID};
            $copy_barcode =~ s/ *//g;
            if ($copy_barcode) {
                $copy_barcode = sprintf("33577%09d", $copy_barcode)
                    unless ($copy_barcode =~ /^33577/);
            }
            my $note = $row->{FineNote} . "\n";
            $note .= $row->{Title} . "\n" if ($row->{Title}
                                          && $row->{Title} !~ /^ *$/);
            $note .= $row->{Author} . "\n" if ($row->{Author}
                                           && $row->{Author} !~ /^ *$/);
            $note .= $row->{CallNumber} . "\n" if ($row->{CallNumber}
                                               && $row->{CallNumber} !~ /^ *$/);
            $note .= $row->{Isbn} . "\n" if ($row->{Isbn}
                                                 && $row->{Isbn} !~ /^ *$/);
            print $copy_barcode . "\n";
            print $note;
            print $row->{OutstandingFine} . "\n\n";
        } else {
            print $csv->error_diag() . " at input line $lines\n";
        }
    }
} until ($csv->eof());

close($fh);

