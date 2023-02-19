#!/usr/bin/perl
#
# abfuhrtermine-gvu-stp - fetch abfuhrtermine from GVU St. Pölten and provide as iCalendar.
#
# Klaus Maria Pfeiffer 2016 - 2022
# https://github.com/hoedlmoser/abfuhrtemine-gvu-stp
#

use strict;
use warnings;
use utf8;
binmode(STDOUT, ":utf8");

use HTML::TreeBuilder;
use POSIX qw(strftime);
use Data::Dumper;
use Getopt::Long;
use Digest::MD5 qw(md5 md5_hex md5_base64);
use Time::Local;
use Time::localtime;


my $opt_jahr = strftime("%Y", gmtime);
my ($opt_gemeinde, $opt_gemid, $opt_verbandid, $opt_haushalt, $opt_gebiet, $opt_liste, $opt_raw, $opt_text, $opt_debug);
GetOptions ('haushalt:s' => \$opt_haushalt, 
            'gebiet:i' => \$opt_gebiet,
            'gemeinde:s' => \$opt_gemeinde,
            'gemeindeid:i' => \$opt_gemid,
            'verbandid:s' => \$opt_verbandid,
            'jahr:i' => \$opt_jahr,
            'liste' => \$opt_liste,
            'raw' => \$opt_raw,
            'text' => \$opt_text,
            'debug' => \$opt_debug,
);
print "$opt_jahr $opt_gemid $opt_gemeinde $opt_gebiet $opt_haushalt\n" if $opt_debug;


my %umlaute = ("ä" => "ae", "Ä" => "Ae", "ü" => "ue", "Ü" => "Ue", "ö" => "oe", "Ö" => "Oe", "ß" => "ss" );
my $umlautkeys = join ("|", keys(%umlaute));


my %verbaende = (
  'St. Pölten Bezirk' => 'pl',
  'Tulln' => 'tu',
  'Lilienfeld' => 'lf',
  'Gänserndorf' => 'gf',
);
my %verbandHost = (
  'pl' => 'stpoeltenland',
  'tu' => 'tulln',
  'lf' => 'lilienfeld',
  'gf' => 'gaenserndorf',
);

my %entsorgungsgebiete = (
  "lf" => {
    "Lilienfeld, Marktl, Stangenthal" => 1,
    "Schrambach" => 2,
    "Abholtag Dienstag" => 1,
    "Abholtag Mittwoch" => 2,
    "St. Aegyd und Kernhof (nicht Container)" => 1,
    "Groß-Container St. Aegyd u. Säcke ab Gscheid bis Fadental u. Neuwald" => 2,
    "Traismauer, Wagram, Waldlesberg, Oberndorf, Stollhofen" => 1,
    "Frauendorf, Hilpersdorf, Gemeinlebarn" => 2,
    "Türnitz" => 1,
    "Lehenrotte, Freiland" => 2,
  },
  "tu" => {
  #  "Dschungeldorf" => 5,
    "Haushalte Zeiselmauer" => 1,
    "Haushalte Wolfpassing" => 2,
  },
);

my %entsorgungsfrequenz = (
  "lf" => {
    "Restmüll alle 2 Wochen" => 'm',
    "Restmüll alle 4 Wochen" => 'e',
  },
);


for my $verbandLong ( sort keys %verbaende ) {
  my $verbandShort = $verbaende{$verbandLong};
  print "$verbandLong, $verbandShort\n" if $opt_debug;
  if ((defined($opt_verbandid) && lc $opt_verbandid eq $verbandShort) || !defined($opt_verbandid)) {
    print "$verbandLong, \U$verbandShort\n" if $opt_liste;
    getGemeinde($verbandShort);
  }
}



sub getGemeinde {
  my ($vbid) = @_;

  my $url = "http://$verbandHost{$vbid}.umweltverbaende.at/?portal=verband&vb=$vbid&kat=32";
  print "$url\n" if $opt_debug;

  my $tree = HTML::TreeBuilder->new_from_url($url);

  foreach my $p ($tree->look_down(_tag => "option"))
  {
    my $gemeinde = $p->as_text;
    my $gemid = $p->attr('value');

    next if $gemeinde =~ /alle Gemeinden/;
    #print "$gemeinde $gemid\n" if $opt_debug;
    $gemeinde =~ s/($umlautkeys)/$umlaute{$1}/g;  
    print "$gemeinde $gemid\n" if $opt_debug;

    if (defined($opt_liste)) {
      print "  $gemeinde, $gemid\n";
    } elsif ((defined($opt_gemid) && $opt_gemid == $gemid) || (defined($opt_gemeinde) && $opt_gemeinde eq $gemeinde) || (!defined($opt_gemid) && !defined($opt_gemeinde))) {
      printiCal($vbid, $gemid, $gemeinde, $opt_jahr);
    }
  }
  $tree->delete;
}



sub printiCal {
  my ($vbid, $gemid, $gemeinde, $jahr) = @_;
  
  print "$gemeinde";

  $gemeinde =~ tr/ \./-/d;  
  my $iCalFile = "abfuhrtermine_${gemeinde}_${gemid}_${jahr}";
  print "\n$iCalFile\n" if $opt_debug;

  my $timestamp = strftime("%Y%m%dT%H%M%SZ", gmtime);

  my $url = "http://$verbandHost{$vbid}.umweltverbaende.at/?gem_nr=$gemid&jahr=$jahr&portal=verband&vb=$vbid&kat=32";
  print "$url\n" if $opt_debug;

  my $tree = HTML::TreeBuilder->new_from_url($url);

  my %abfuhr;
  my $maxeg = 0;

  open(my $fhRaw, '>:encoding(UTF-8)', $iCalFile . '.out') or die "could not open file '$iCalFile.out' $!" if $opt_raw;

  foreach my $p ($tree->look_down(_tag => "div", class => "tunterlegt"))
  {
    my ($abfuhrdate, $abfuhrtype);
    my $abfuhrinfo = $p->as_text;

    print "$abfuhrinfo\n" if $opt_debug;
    print $fhRaw "$abfuhrinfo\n" if $opt_raw;

    next if $abfuhrinfo =~ m/(Wohnhausanlagen|Windeltonne|Dschungeldorf)/;

    if ($abfuhrinfo =~ /(\d{2})\.(\d{2})\.(\d{4}).*? ([\w ]*?)\s*$/) {
      $abfuhrdate = "$3$2$1";
      my $abfuhrtimeend = timelocal(0, 0, 0, $1, $2 - 1, $3) + 24 * 60 * 60;
      my $abfuhrdateend = sprintf("%04d%02d%02d", localtime($abfuhrtimeend)->year() + 1900, localtime($abfuhrtimeend)->mon() + 1, localtime($abfuhrtimeend)->mday);
      $abfuhrtype = "$4";
      print "   -> $abfuhrdate $abfuhrdateend $abfuhrtype " if $opt_debug;
      $abfuhr{"$abfuhrdate"}{"$abfuhrtype"}{"st"} = 1;
      $abfuhr{"$abfuhrdate"}{"$abfuhrtype"}{"end"} = $abfuhrdateend;
    }

    my $eg = undef;
    if ($abfuhrinfo =~ /(Entsorgungsgebiet|Haushalte|Restmüll|Sprengel) (\d)/) {
      print "'$2'->" if $opt_debug;
      $eg = $2;
    }
    if ($abfuhrinfo =~ /Abfuhrgebiet (I*)/) {
      print "'$1'->" if $opt_debug;
      $eg = length($1);
    }
    if (defined($entsorgungsgebiete{"$vbid"})) {
      my $entsorgungsgebietekeys = join ("|", map(quotemeta,keys(%{$entsorgungsgebiete{"$vbid"}})));
      if ($abfuhrinfo =~ /($entsorgungsgebietekeys)/) {
        print "'$1'->" if $opt_debug;
        $eg = $entsorgungsgebiete{"$vbid"}{"$1"};
      }
    }
    if (defined($eg)) {
      if (!defined($abfuhr{"$abfuhrdate"}{"$abfuhrtype"}{"eg"}) || ($abfuhr{"$abfuhrdate"}{"$abfuhrtype"}{"eg"} !~ m/$eg/)) {
        $abfuhr{"$abfuhrdate"}{"$abfuhrtype"}{"eg"} .= "$eg";
      }
      $maxeg = $eg if ($eg > $maxeg);
      print "$eg " if $opt_debug;
      undef $eg;
    }

    my $ph = undef;
    if ($abfuhrinfo =~ /(Mehr|Ein)personenhaushalt/) {
      print "'$1'->" if $opt_debug;
      $ph = lc substr $1, 0, 1;
    }
    if (defined($entsorgungsfrequenz{"$vbid"})) {
      my $entsorgungsfrequenzkeys = join ("|", keys(%{$entsorgungsfrequenz{"$vbid"}}));
      if ($abfuhrinfo =~ /($entsorgungsfrequenzkeys)/) {
        print "'$1'->" if $opt_debug;
        $ph = $entsorgungsfrequenz{"$vbid"}{"$1"};
      }
    }
    if (defined($ph)) {
      if (!defined($abfuhr{"$abfuhrdate"}{"$abfuhrtype"}{"ph"}) || ($abfuhr{"$abfuhrdate"}{"$abfuhrtype"}{"ph"} !~ m/$ph/)) {
        $abfuhr{"$abfuhrdate"}{"$abfuhrtype"}{"ph"} .= $ph;
      }
      print "$ph " if $opt_debug;
    }

    print "\n" if $opt_debug;
  }

  close $fhRaw if $opt_raw;

  $tree->delete;

  print " -> $iCalFile.ics\n";

  open(my $fh, '>:encoding(UTF-8)', $iCalFile . '.ics') or die "could not open file '$iCalFile.ics' $!";
  open(my $fhText, '>:encoding(UTF-8)', $iCalFile . '.txt') or die "could not open file '$iCalFile.txt' $!" if $opt_text;
    
  print $fh "BEGIN:VCALENDAR\r\n";
  print $fh "VERSION:2.0\r\n";
  print $fh "PRODID:-//kmp.or.at//NONSGML abfuhrtermine v0.1//EN\r\n";

  foreach my $abfuhrdate (sort keys %abfuhr) {
    my $hashabfuhrtype = $abfuhr{$abfuhrdate};
    while ( my ($abfuhrtype, $hashabfuhr) = each(%$hashabfuhrtype) ) {
      if (((!defined($hashabfuhr->{'eg'})) || (!defined($opt_gebiet)) || ($hashabfuhr->{'eg'} =~ $opt_gebiet)) && ((!defined($hashabfuhr->{'ph'})) || (!defined($opt_haushalt)) || ($hashabfuhr->{'ph'} =~ $opt_haushalt))) {
        print $fh "BEGIN:VEVENT\r\n";
        print $fh "UID:" . md5_hex($gemid . $abfuhrdate . $abfuhrtype) . "\@abfuhrtermine.kmp.or.at\r\n";
        print $fh "DTSTAMP:$timestamp\r\n";
        print $fh "DTSTART;VALUE=DATE:$abfuhrdate\r\n";
	print $fhText "$abfuhrdate " if $opt_text;
        print $fh "DTEND;VALUE=DATE:$hashabfuhr->{'end'}\r\n";
        print $fh "SUMMARY:$abfuhrtype";
	print $fhText "$abfuhrtype" if $opt_text;
        if (defined($hashabfuhr->{'eg'}) && !defined($opt_gebiet)) {
          $hashabfuhr->{'eg'} = join '',sort split('',$hashabfuhr->{'eg'});
          if ($hashabfuhr->{'eg'} ne join '', (1 .. $maxeg)) {
            print $fh ' ' . join ' ', split('',$hashabfuhr->{'eg'});
            print $fhText ' ' . join ' ', split('',$hashabfuhr->{'eg'}) if $opt_text;
          }
        }
        if (defined($hashabfuhr->{'ph'}) && !defined($opt_haushalt)) {
          $hashabfuhr->{'ph'} = join '',sort split('',$hashabfuhr->{'ph'});
          if ($hashabfuhr->{'ph'} ne "em") {
            print $fh " $hashabfuhr->{'ph'}";
            print $fhText " $hashabfuhr->{'ph'}" if $opt_text;
          }
        }
        print $fh "\r\n";
        print $fh "STATUS:CONFIRMED\r\n";
        print $fh "TRANSP:TRANSPARENT\r\n";
        print $fh "BEGIN:VALARM\r\n";
        print $fh "TRIGGER:-PT8H\r\n";
        print $fh "ACTION:DISPLAY\r\n";
        print $fh "DESCRIPTION:Morgen ist $abfuhrtype-Abholung\r\n";
        print $fh "END:VALARM\r\n";
	print $fh "END:VEVENT\r\n";
	print $fhText "\n" if $opt_text;
      }
    }
  }
  print $fh "END:VCALENDAR\r\n";

  close $fh;
  close $fhText if $opt_text;
}

