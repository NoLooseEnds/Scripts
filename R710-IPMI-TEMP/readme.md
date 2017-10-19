# Howto: Setting the fan speed of the Dell R610/R710
Inspired by [this Reddit post](https://www.reddit.com/r/homelab/comments/72qust/r510_noise/dnkofsv/) by /u/whitekidney


1. Enable IPMI in iDrac
2. Install ipmitool on linux, win or mac os
3. Run the following command to issue IPMI commands `ipmitool -I lanplus -H <iDracip> -U root -P <rootpw> <command>`

**Enable manual/static fan speed:**

`raw 0x30 0x30 0x01 0x00`


**Set fan speed:**

(Use i.e http://www.hexadecimaldictionary.com/hexadecimal/0x14/ to calculate speed)

*3000 RPM*: `raw 0x30 0x30 0x02 0xff 0x10`

*2160 RPM*: `raw 0x30 0x30 0x02 0xff 0x0a`


**Disable / Return to automatic fan control:**

`raw 0x30 0x30 0x01 0x01`

**Other: List all output from IPMI**

`sdr elist all`

**Example of a command:**
`ipmitool -I lanplus -H 192.168.0.120 -U root -P calvin  raw 0x30 0x30 0x02 0xff 0x10`

# Safety BASH script
I made a BASH script to check the temperature, and if it's higher than XX (27 degrees C in my case) it sends a raw command to restore automatic fan control. 

Script [Reddit thread](https://www.reddit.com/r/homelab/comments/779cha/manual_fan_control_on_r610r710_including_script/)


*****
**Disclaimer:**

I'm by no means good at bash scripting or regex, etc. but it seems to work fine for me. 

TLDR; I take _NO_ responsibility if you mess up anything.