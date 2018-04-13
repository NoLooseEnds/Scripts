#!/usr/bin/env bash

# ----------------------------------------------------------------------------------
# Script for setting manual fan speed to 2160 RPM (on my R710)
#
# Requires ipmitool – apt-get install ipmitool
# Tested on Ubuntu 17.04
# ----------------------------------------------------------------------------------


# IPMI SETTINGS:
# Modify to suit your needs.
# DEFAULT IP: 192.168.0.120
IPMIHOST=10.0.100.20
IPMIUSER=root
IPMIPW=calvin

printf "Activating manual fan speeds! (2160 RPM)" | systemd-cat -t R710-IPMI-TEMP
echo "Activating manual fan speeds! (2160 RPM)"
ipmitool -I lanplus -H $IPMIHOST -U $IPMIUSER -P $IPMIPW raw 0x30 0x30 0x01 0x00
ipmitool -I lanplus -H $IPMIHOST -U $IPMIUSER -P $IPMIPW raw 0x30 0x30 0x02 0xff 0x09