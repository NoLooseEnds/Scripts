# _**Notice:** This script is not maintained any more._ 

**_If you want a more advanced Perl script with more functionality, check out [@spacelama's fork](https://github.com/spacelama/Scripts)._**
  
  
  
*****
 
*****

*****

**Old README:**

# Safety BASH script
I made a BASH script to check the temperature, and if it's higher than XX (27 degrees C in my case) it sends a raw command to restore automatic fan control. 

I'm running this on an Ubuntu VM on ESXi (on the R710 box), but it should be able to run as long as you have ipmitools. It could be you need to modify the logging, to make it work with whatever your system use.

I run the script via CRON every 5 minutes from my Ubuntu Server VM running on ESXi.

`*/5 * * * * /bin/bash /path/to/script/R710-IPMITemp.sh > /dev/null 2>&1`

Notice that I use [healthchecks.io](https://healthchecks.io) in the script to notify if the temp goes to high (it would also trigger if the internet goes down for some reason). Remember to get your own check URL if you want it, or else just remove the curl command.

I'm also currently testing out [slacktee.sh](https://github.com/course-hero/slacktee) to get notifications in my slack channel.


The Scripts [Reddit thread](https://www.reddit.com/r/homelab/comments/779cha/manual_fan_control_on_r610r710_including_script/)

# Howto: Setting the fan speed of the Dell R610/R710

1. Enable IPMI in iDrac
2. Install ipmitool on linux, win or mac os
3. Run the following command to issue IPMI commands: 
`ipmitool -I lanplus -H <iDracip> -U root -P <rootpw> <command>`


**Enable manual/static fan speed:**

`raw 0x30 0x30 0x01 0x00`


**Set fan speed:**

(Use i.e http://www.hexadecimaldictionary.com/hexadecimal/0x14/ to calculate speed from decimal to hex)

*3000 RPM*: `raw 0x30 0x30 0x02 0xff 0x10`

*2160 RPM*: `raw 0x30 0x30 0x02 0xff 0x0a`

*1560 RPM*: `raw 0x30 0x30 0x02 0xff 0x09`

_Note: The RPM may differ from model to model_


**Disable / Return to automatic fan control:**

`raw 0x30 0x30 0x01 0x01`


**Other: List all output from IPMI**

`sdr elist all`


**Example of a command:**

`ipmitool -I lanplus -H 192.168.0.120 -U root -P calvin  raw 0x30 0x30 0x02 0xff 0x10`


*****

**Disclaimer**

I'm by no means good at IPMI, BASH scripting or regex, etc. but it seems to work fine for me. 

TLDR; I take _NO_ responsibility if you mess up anything.

*****

All of this was inspired by [this Reddit post](https://www.reddit.com/r/homelab/comments/72qust/r510_noise/dnkofsv/) by /u/whitekidney 
