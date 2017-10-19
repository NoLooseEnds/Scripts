#!/usr/bin/env bash

# Requires ipmitool – apt-get install ipmitool
# Tested on ubuntu

# IPMI
IPMIHOST=192.168.0.120
IPMIUSER=root
IPMIPW=calvin

# TEMPERATURE
MAXTEMP=27
TEMP=$(ipmitool -I lanplus -H $IPMIHOST -U $IPMIUSER -P $IPMIPW sdr type temperature |grep Ambient |grep -Po '\d{2}')


if [[ $TEMP > $MAXTEMP ]];
  then
    printf "Temperature is too high! ($TEMP C) Activating dynamic fan control!" | systemd-cat -t R710-IPMI-TEMP
    echo "Temperature is too high! ($TEMP C) Activating dynamic fan control!"
    ipmitool -I lanplus -H $IPMIHOST -U $IPMIUSER -P $IPMIPW raw 0x30 0x30 0x01 0x01
  else
    printf "Temperature is OK ($TEMP C)" | systemd-cat -t R710-IPMI-TEMP
    echo "Temperature is OK ($TEMP C)"
fi
