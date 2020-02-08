#!/usr/bin/perl

use strict;
use warnings;
use List::MoreUtils qw( apply );
use File::Temp qw(tempfile);

my $static_speed_low=0x03;
my $static_speed_high=0x20;   # this is the speed value at 100% demand
                              # ie what we consider the point we don't
                              # really want to get hotter but still
                              # tolerate
my $ipmi_inlet_sensorname="Inlet Temp";

my $default_threshold=32;  # the ambient temperature we use above
                           # which we default back to letting the drac
                           # control the fans
my $base_temp     = 30;    # no fans when below this temp
my $desired_temp1 = 40;    # aim to keep the temperature below this
my $desired_temp2 = 50;    # really ramp up fans above this
my $desired_temp3 = 55;    # really ramp up fans above this
my $demand1       = 30;    # demand at temp1
my $demand2       = 100;   # demand at temp2
my $demand3       = 200;   # demand at temp3

# check inlet temp every minute, hddtemp every minute (but FIXME:
# ensure doesn't spinup spundown disks), and sensors every few seconds

my @ambient_ipmitemps=();
my @hddtemps=();
my @coretemps=();
my @cputemps=();

my $current_mode;
my $lastfan;

# returns undef if there are no inputs, and ignores inputs that are
# undef
sub average {
  my (@v) = (@_);

  my $div = 0;
  my $tot = 0;
  foreach my $v (@v) {
    if (defined $v) {
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
    system("ipmitool raw 0x30 0x30 0x01 0x01");
  }
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

  if (!defined $weighted_temp) {
    print "Error reading all temperatures! Fallback to idrac control\n";
    set_fans_default();
    return;
  }
  print "weighted_temp = $weighted_temp ; ambient_temp $ambient_temp\n";

  if (!defined $current_mode or $current_mode ne "set") {
    $current_mode="set";
    print "--> disable dynamic fan control\n";
    system("ipmitool raw 0x30 0x30 0x01 0x00");
  }

  # FIXME: probably want to take into account ambient temperature - if
  # the difference between weighted_temp and ambient_temp is small
  # because ambient_temp is large, then less need to run the fans
  # because there's still low power demands
  my $demand = 0; # want demand to be a reading from 0-100% of
                  # $static_speed_low - $static_speed_high
  if ($weighted_temp > $base_temp and
      $weighted_temp < $desired_temp1) {
    # slope m = (y2-y1)/(x2-x1)
    # y - y1 = (x-x1)(y2-y1)/(x2-x1)
    # y1 = 0 ; x1 = base_temp ; y2 = demand1 ; x2 = desired_temp1
    # x = weighted_temp
    $demand = 0 + ($weighted_temp - $base_temp) * ($demand1 - 0)/($desired_temp1 - $base_temp);
  } elsif ($weighted_temp >= $desired_temp2) {
    # y1 = demand1 ; x1 = desired_temp1 ; y2 = demand2 ; x2 = desired_temp2
    $demand = $demand2 + ($weighted_temp - $desired_temp2) * ($demand3 - $demand2)/($desired_temp3 - $desired_temp2);
  } elsif ($weighted_temp >= $desired_temp1) {
    # y1 = demand1 ; x1 = desired_temp1 ; y2 = demand2 ; x2 = desired_temp2
    $demand = $demand1 + ($weighted_temp - $desired_temp1) * ($demand2 - $demand1)/($desired_temp2 - $desired_temp1);
  }
  $demand = int($static_speed_low + $demand/100*($static_speed_high-$static_speed_low));
  if ($demand>255) {
    $demand=255;
  }
  # ramp down the fans quickly upon lack of demand, don't ramp them up
  # to tiny spikes of 1 fan unit.  FIXME: But should implement long
  # term smoothing of +/- 1 fan unit
  if (!defined $lastfan or $demand < $lastfan or $demand > $lastfan + 1) {
    $lastfan = $demand;
    $demand = sprintf("0x%x", $demand);
#    print "demand = $demand\n";
    print "--> ipmitool raw 0x30 0x30 0x02 0xff $demand\n";
    system("ipmitool raw 0x30 0x30 0x02 0xff $demand");
  } else {
    print "demand = $demand\n";
  }
}

my ($tempfh, $tempfilename) = tempfile("fan-speed-control.XXXXX");

$SIG{TERM} = $SIG{HUP} = $SIG{INT} = sub { my $signame = shift ; $SIG{$signame} = 'DEFAULT' ; print "Resetting fans back to default\n"; set_fans_default ; kill $signame, $$ };
END {
  my $exit = $?;
  unlink $tempfilename;
  print "Resetting fans back to default\n";
  set_fans_default;
  $? = $exit;
}

my $last_reset_hddtemps=time;
my $last_reset_ambient_ipmitemps=time;
while () {
  if (!@hddtemps) {
    # could just be a simple pipe, but hddtemp has a strong posibility
    # to be stuck in a D state, and hold STDERR open despite a kill
    # -9, so instead just send it to a tempfile, and read from that tempfile
    system("timeout -k 1 10 hddtemp /dev/sd? > $tempfilename");
    @hddtemps=`grep [0-9] < $tempfilename`;
  }
  if (!@ambient_ipmitemps) {
    @ambient_ipmitemps=`timeout -k 1 10 ipmitool sdr type temperature | grep "$ipmi_inlet_sensorname" | grep [0-9]`
  }
  @coretemps=`timeout -k 1 10 sensors | grep [0-9]`;
  @cputemps=grep {/^Package id/} @coretemps;
  @coretemps=grep {/^Core/} @coretemps;

  chomp @cputemps;
  chomp @coretemps;
  chomp @ambient_ipmitemps;
  chomp @hddtemps;

  @cputemps = apply { s/.*:  *([^ ]*)°C.*/$1/ } @cputemps;
  @coretemps = apply { s/.*:  *([^ ]*)°C.*/$1/ } @coretemps;
  @ambient_ipmitemps = apply { s/.*\| ([^ ]*) degrees C.*/$1/ } @ambient_ipmitemps;
  @hddtemps = apply { s/.*:  *([^ ]*)°C.*/$1/ } @hddtemps;
  #FIXME: it is more important to keep hdds cool than CPUs.  We should
  #put differnt offsets on them - possibly as easily as adding "10" to
  #hddtemp (but need to work out how to keep log output sane)

  print "\n";

  print "cputemps=", join (" ; ", @cputemps), "\n";
  print "coretemps=", join (" ; ", @coretemps), "\n";
  print "ambient_ipmitemps=", join (" ; ", @ambient_ipmitemps), "\n";
  print "hddtemps=", join (" ; ", @hddtemps), "\n";

  my $ambient_temp = average(@ambient_ipmitemps);
  # FIXME: hysteresis
  if ($ambient_temp > $default_threshold) {
    print "fallback because of high ambient temperature $ambient_temp > $default_threshold\n";
    set_fans_default();
  } else {
    set_fans_servo($ambient_temp, \@cputemps, \@coretemps, \@hddtemps);
  }

  # every 60 seconds, invalidate the cache of the slowly changing hdd
  # temperatures to allow them to be refreshed
  if (time - $last_reset_hddtemps > 60) {
    @hddtemps=();
  }
  # every 60 seconds, invalidate the cache of the slowly changing
  # ambient temperatures to allow them to be refreshed
  if (time - $last_reset_ambient_ipmitemps > 60) {
    @ambient_ipmitemps=();
  }
  sleep 3;
}
