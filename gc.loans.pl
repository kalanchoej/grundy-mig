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
            $copy_barcode = sprintf("33577%09d", $copy_barcode)
                unless ($copy_barcode =~ /^33577/);
            my $args = {
                patron_barcode => $row->{PatronId},
                barcode => $copy_barcode,
                checkout_time => $row->{TransDate},
                due_date => $row->{DateDue},
                permit_override => 1
            };
            print Dumper $args;
            try {
                my $r = OpenSRF::AppSession->create('open-ils.circ')
                    ->request('open-ils.circ.checkout', $authtoken, $args)
                        ->gather(1);
                print Dumper $r;
            } catch Error with {
                my $err = shift;
                print Dumper $err;
            }
        } else {
            print $csv->error_diag() . " at input line $lines\n";
        }
    }
} until ($csv->eof());

close($fh);

