#!/usr/bin/perl

use strict;
use warnings;
use List::MoreUtils qw( apply );
use File::Temp qw(tempfile);

my $static_speed_low=0x02;
my $static_speed_high=0x12;   # this is the speed value at 100% demand
                              # ie what we consider the point we don't
                              # really want to get hotter but still
                              # tolerate
my $ipmi_inlet_sensorname="Inlet Temp";

my $default_threshold=32;  # the ambient temperature we use above
                           # which we default back to letting the drac
                           # control the fans
my $base_temp     = 30;    # no fans when below this temp
my $desired_temp1 = 40;    # aim to keep the temperature below this
my $desired_temp2 = 45;    # really ramp up fans above this
my $desired_temp3 = 55;    # really ramp up fans above this
my $demand1       = 5;     # prescaled (not taking into effect static_speed_low/high) demand at temp1
my $demand2       = 40;    # prescaled (not taking into effect static_speed_low/high) demand at temp2
my $demand3       = 200;   # prescaled (not taking into effect static_speed_low/high) demand at temp3

my $hysteresis    = 2;     # don't ramp up velocity unless demand
                           # difference is greater than this.  Ramp
                           # down ASAP however, to bias quietness, and
                           # thus end up removing noise changes for
                           # just small changes in computing

# check inlet temp every minute, hddtemp every minute (but FIXME:
# ensure doesn't spinup spundown disks), and sensors every few seconds

# background information:
# https://www.dell.com/community/PowerEdge-Hardware-General/T130-Fan-Speed-Algorithm/td-p/5052692
# https://serverfault.com/questions/715387/how-do-i-stop-dell-r730xd-fans-from-going-full-speed-when-broadcom-qlogic-netxtr/733064#733064
# could monitor H710 temperature with sudo env /opt/MegaRAID/MegaCli/MegaCli64 -AdpAllInfo -aALL | grep -i temperature

my @ambient_ipmitemps=();
my @hddtemps=();
my @coretemps=();
my @cputemps=();

my $current_mode;
my $lastfan;

my $quiet=0;          # whether to print stats at all
my $print_stats = 1;  # whether to print stats this run

sub is_num {
  my ($val) = @_;
  if ( $val =~ /^[-+]?(\d*\.?\d+|\d+\.?\d*)+$/ ) {
    return 1;
  }
  print "is_num($val)=0\n"; # should probably warn about failures to parse values, but if you don't care about a particular error, perhaps add this clause: if !$quiet;
  return 0;
}

# returns undef if there are no inputs, and ignores inputs that are
# undef
sub average {
  my (@v) = (@_);

  my $div = 0;
  my $tot = 0;
  foreach my $v (@v) {
    if (defined $v && is_num($v)) {
      $tot += $v;
      $div++;
    }
  }
  my $avg=undef;
  if ($div > 0) {
    $avg = sprintf "%.2f", $tot/$div;
  }
  return $avg;
}

# returns undef if there are no inputs, and ignores inputs that are
# undef
sub max {
  my (@v) = (@_);
  my $max=undef;
  foreach my $v (@v) {
    if (defined $v) {
      if (!defined $max or $v > $max) {
        $max = $v;
      }
    }
  }
  return $max;
}

sub set_fans_default {
  if (!defined $current_mode or $current_mode ne "default") {
    $current_mode="default";
    $lastfan=undef;
    print "--> enable dynamic fan control\n";
    foreach my $attempt (1..10) {
      system("ipmitool raw 0x30 0x30 0x01 0x01") == 0 and return 1;
      sleep 1;
      print "  Retrying dynamic control $attempt\n";
    }
    print "Retries of dynamic control all failed\n";
    return 0;
  }
  return 1;
}

sub set_fans_servo {
  my ($ambient_temp, $_cputemps, $_coretemps, $_hddtemps) = (@_);
  my (@cputemps)  = @$_cputemps;
  my (@coretemps) = @$_coretemps;
  my (@hddtemps)  = @$_hddtemps;

  # two thirds weighted CPU temps vs hdd temps, but if the HDD temps
  # creep above this value, use them exclusively (more important to
  # keep them cool than the CPUs)
  my $weighted_temp = max(average(
                                  average(@cputemps), average(@coretemps), average(@hddtemps)),
                          average(@hddtemps));

  if ((!defined $weighted_temp) or ($weighted_temp == 0)) {
    print "Error reading all temperatures! Fallback to idrac control\n";
    set_fans_default();
    return;
  }
  print "weighted_temp = $weighted_temp ; ambient_temp $ambient_temp\n" if $print_stats;

  if ((!defined $current_mode) or ($current_mode ne "set")) {
    print "--> disable dynamic fan control\n";
    system("ipmitool raw 0x30 0x30 0x01 0x00") == 0 or return 0;
    # if this fails, want to return telling caller not to think weve
    # made a change
    $current_mode="set";
  }

  # FIXME: probably want to take into account ambient temperature - if
  # the difference between weighted_temp and ambient_temp is small
  # because ambient_temp is large, then less need to run the fans
  # because there's still low power demands
  my $demand = 0; # sort of starts off with a range roughly 0-255,
                  # which we multiply later to be ranged roughly
                  # between 0-100% of
                  # ($static_speed_low - $static_speed_high)
  if (($weighted_temp > $base_temp) and
      ($weighted_temp < $desired_temp1)) {
    # slope m = (y2-y1)/(x2-x1)
    # y - y1 = (x-x1)(y2-y1)/(x2-x1)
    # y1 = 0 ; x1 = base_temp ; y2 = demand1 ; x2 = desired_temp1
    # x = weighted_temp
    $demand = 0        + ($weighted_temp - $base_temp    ) * ($demand1 - 0       )/($desired_temp1 - $base_temp    );
  } elsif (($weighted_temp >= $desired_temp1) and
           ($weighted_temp < $desired_temp2)) {
    # y1 = demand1 ; x1 = desired_temp1 ; y2 = demand2 ; x2 = desired_temp2
    $demand = $demand1 + ($weighted_temp - $desired_temp1) * ($demand2 - $demand1)/($desired_temp2 - $desired_temp1);
  } elsif ($weighted_temp >= $desired_temp2) {
    # y1 = demand2 ; x1 = desired_temp2 ; y2 = demand3 ; x2 = desired_temp3
    # demand will increase above $demand3 for temps above $desired_temp3, linearly, until we cap it below
    $demand = $demand2 + ($weighted_temp - $desired_temp2) * ($demand3 - $demand2)/($desired_temp3 - $desired_temp2);
  } else {
    # the only possibility left is $weighted_temp < $base_temp
    # which we've already decided is demand=0
  }
  printf "demand(%0.2f)", $demand if $print_stats;
  $demand = int($static_speed_low + $demand/100*($static_speed_high-$static_speed_low));
  if ($demand>255) {
    $demand=255;
  }
  printf " -> %i\n", $demand if $print_stats;
  # ramp down the fans quickly upon lack of demand, don't ramp them up
  # to tiny spikes of 1 fan unit.  FIXME: But should implement long
  # term smoothing of +/- 1 fan unit
  if (!defined $lastfan or $demand < $lastfan or $demand > $lastfan + $hysteresis) {
    $lastfan = $demand;
    $demand = sprintf("0x%x", $demand);
#    print "demand = $demand\n";
    print "--> ipmitool raw 0x30 0x30 0x02 0xff $demand\n";
    system("ipmitool raw 0x30 0x30 0x02 0xff $demand") == 0 or return 0;
    # if this fails, want to return telling caller not to think weve
    # made a change
  }
  return 1;
}

my ($tempfh, $tempfilename) = tempfile("fan-speed-control.XXXXX", TMPDIR => 1);

$SIG{TERM} = $SIG{HUP} = $SIG{INT} = sub { my $signame = shift ; $SIG{$signame} = 'DEFAULT' ; print "Resetting fans back to default\n"; set_fans_default ; kill $signame, $$ };
END {
  my $exit = $?;
  unlink $tempfilename;
  print "Resetting fans back to default\n";
  set_fans_default;
  $? = $exit;
}

if (defined $ARGV[0] && $ARGV[0] eq "-q") {
  $quiet=1;
  $print_stats=0;
}

my $last_reset_hddtemps=time;
my $last_reset_ambient_ipmitemps=time;
my $ambient_temp=20;
while () {
  if (!@hddtemps) {
    # could just be a simple pipe, but hddtemp has a strong posibility
    # to be stuck in a D state, and hold STDERR open despite a kill
    # -9, so instead just send it to a tempfile, and read from that tempfile
    system("timeout -k 1 20 hddtemp /dev/sd? /dev/nvme?n? | grep -v 'not available' > $tempfilename");
    @hddtemps=`cat < $tempfilename`;
  }
  if (!@ambient_ipmitemps) {
    @ambient_ipmitemps=`timeout -k 1 20 ipmitool sdr type temperature | grep "$ipmi_inlet_sensorname" | grep [0-9] || echo " | $ambient_temp degrees C"` # ipmitool often fails - just keep using the previous result til it succeeds
  }
  @coretemps=`timeout -k 1 20 sensors | grep [0-9]`;
  @cputemps=grep {/^Package id/} @coretemps;
  @coretemps=grep {/^Core/} @coretemps;
  # filter in numbers only and remove all extraneous output, and some
  # devices permanently return a *temperature* of 255, so filter them
  # out too.
  @hddtemps=grep {/[0-9]/ && !/255/} @hddtemps;

  chomp @cputemps;
  chomp @coretemps;
  chomp @ambient_ipmitemps;
  chomp @hddtemps;

  # apply from List::MoreUtils

  # "..?C" refers to single octet ascii degree symbol that old
  # versions used to output, and 2 octet unicode degree symbol
  @cputemps = apply { s/.*:  *([-+0-9.]+)..?C\b.*/$1/ } @cputemps;
  @coretemps = apply { s/.*:  *([-+0-9.]+)..?C\b.*/$1/ } @coretemps;
  @ambient_ipmitemps = apply { s/.*\| ([^ ]*) degrees C.*/$1/ } @ambient_ipmitemps;
  @hddtemps = apply { s/.*:  *([-+0-9.]+)..?C\b.*/$1/ } @hddtemps;
  #FIXME: it is more important to keep hdds cool than CPUs.  We should
  #put differnt offsets on them - possibly as easily as adding "10" to
  #hddtemp (but need to work out how to keep log output sane)

  print "\n" if $print_stats;

  print "cputemps=", join (" ; ", @cputemps), "\n" if $print_stats;
  print "coretemps=", join (" ; ", @coretemps), "\n" if $print_stats;
  print "ambient_ipmitemps=", join (" ; ", @ambient_ipmitemps), "\n" if $print_stats;
  print "hddtemps=", join (" ; ", @hddtemps), "\n" if $print_stats;

  $ambient_temp = average(@ambient_ipmitemps);
  # FIXME: hysteresis
  if ($ambient_temp > $default_threshold) {
    print "fallback because of high ambient temperature $ambient_temp > $default_threshold\n";
    if (!set_fans_default()) {
      # return for next loop without resetting timers and delta change if that fails
      next;
    }
  } else {
    if (!set_fans_servo($ambient_temp, \@cputemps, \@coretemps, \@hddtemps)) {
      # return for next loop without resetting timers and delta change if that fails
      next;
    }
  }

  $print_stats = 0;
  # every 20 minutes (enough to establish spin-down), invalidate the
  # cache of the slowly changing hdd temperatures to allow them to be
  # refreshed
  if (time - $last_reset_hddtemps > 1200) {
    @hddtemps=();
    $last_reset_hddtemps=time;
  }
  # every 60 seconds, invalidate the cache of the slowly changing
  # ambient temperatures to allow them to be refreshed
  if (time - $last_reset_ambient_ipmitemps > 60) {
    @ambient_ipmitemps=();
    $current_mode="reset"; # just in case the RAC has rebooted, it
                           # will go back into default control, so
                           # make sure we set it appropriately once
                           # per minute
    $last_reset_ambient_ipmitemps=time;
    $print_stats = 1 if !$quiet;
  }
  sleep 3;
}
