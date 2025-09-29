<div id="top"></div>

# Dell iDRAC fan controller Docker image
https://github.com/rpbush/Dell_iDRAC_fan_controller_Docker

<!-- TABLE OF CONTENTS -->
<details>
  <summary>Table of Contents</summary>
  <ol>
    <li><a href="#container-console-log-example">Container console log example</a></li>
    <li><a href="#usage">Usage</a></li>
    <li><a href="#parameters">Parameters</a></li>
    <li><a href="#proxmox-lxc">Proxmox LXC (Proxmox VE 9)</a></li>
    <li><a href="#contributing">Contributing</a></li>
  </ol>
</details>

## Container console log example

![image](https://user-images.githubusercontent.com/37409593/163174925-d3d20ed6-0f95-44e6-827d-368939435ba4.png)

<p align="right">(<a href="#top">back to top</a>)</p>

<!-- PREREQUISITES -->
## Prerequisites
### To access iDRAC over LAN (not needed in "local" mode) :

1. Log into your iDRAC web console

![001](https://user-images.githubusercontent.com/37409593/210168273-7d760e47-143e-4a6e-aca7-45b483024139.png)

2. In the left side menu, expand "iDRAC settings", click "Network" then click "IPMI Settings" link at the top of the web page.

![002](https://user-images.githubusercontent.com/37409593/210168249-994f29cc-ac9e-4667-84f7-07f6d9a87522.png)

3. Check the "Enable IPMI over LAN" checkbox then click "Apply" button.

![003](https://user-images.githubusercontent.com/37409593/210168248-a68982c4-9fe7-40e7-8b2c-b3f06fbfee62.png)

4. Test access to IPMI over LAN running the following commands :
```bash
apt -y install ipmitool
ipmitool -I lanplus \
  -H <iDRAC IP address> \
  -U <iDRAC username> \
  -P <iDRAC password> \
  sdr elist all
```

<p align="right">(<a href="#top">back to top</a>)</p>

<!-- USAGE -->
## Usage

1. with local iDRAC:

```bash
docker run -d \
  --name Dell_iDRAC_fan_controller \
  --restart=unless-stopped \
  -e IDRAC_HOST=local \
  -e CONTROL_METHOD=auto \
  -e FAN_SPEED=<decimal or hexadecimal fan speed> \
  -e CPU_TEMPERATURE_TRESHOLD=<decimal temperature treshold> \
  -e CHECK_INTERVAL=<seconds between each check> \
  --device=/dev/ipmi0:/dev/ipmi0:rw \
  rpbush/dell_idrac_fan_controller_docker
```

2. with LAN iDRAC:

```bash
docker run -d \
  --name Dell_iDRAC_fan_controller \
  --restart=unless-stopped \
  -e IDRAC_HOST=<iDRAC IP address> \
  -e IDRAC_USERNAME=<iDRAC username> \
  -e IDRAC_PASSWORD=<iDRAC password> \
  -e CONTROL_METHOD=auto \
  -e FAN_SPEED=<decimal or hexadecimal fan speed> \
  -e CPU_TEMPERATURE_TRESHOLD=<decimal temperature treshold> \
  -e CHECK_INTERVAL=<seconds between each check> \
  rpbush/dell_idrac_fan_controller_docker
```

`docker-compose.yml` examples:

1. to use with local iDRAC:

```yml
version: '3'

services:
  Dell_iDRAC_fan_controller:
    image: tigerblue77/dell_idrac_fan_controller:latest
    container_name: Dell_iDRAC_fan_controller
    restart: unless-stopped
    environment:
      - IDRAC_HOST=local
      - CONTROL_METHOD=auto
      - FAN_SPEED=<decimal or hexadecimal fan speed>
      - CPU_TEMPERATURE_TRESHOLD=<decimal temperature treshold>
      - CHECK_INTERVAL=<seconds between each check>
    devices:
      - /dev/ipmi0:/dev/ipmi0:rw
```

2. to use with LAN iDRAC:

```yml
version: '3'

services:
  Dell_iDRAC_fan_controller:
    image: tigerblue77/dell_idrac_fan_controller:latest
    container_name: Dell_iDRAC_fan_controller
    restart: unless-stopped
    environment:
      - IDRAC_HOST=<iDRAC IP address>
      - IDRAC_USERNAME=<iDRAC username>
      - IDRAC_PASSWORD=<iDRAC password>
      - CONTROL_METHOD=auto
      - FAN_SPEED=<decimal or hexadecimal fan speed>
      - CPU_TEMPERATURE_TRESHOLD=<decimal temperature treshold>
      - CHECK_INTERVAL=<seconds between each check>
```

<p align="right">(<a href="#top">back to top</a>)</p>

<!-- PARAMETERS -->
## Parameters

All parameters are optional as they have default values (including default iDRAC username and password).

- `IDRAC_HOST` parameter can be set to "local" or to your distant iDRAC's IP address. **Default** value is "local".
- `IDRAC_USERNAME` parameter is only necessary if you're adressing a distant iDRAC. **Default** value is "root".
- `IDRAC_PASSWORD` parameter is only necessary if you're adressing a distant iDRAC. **Default** value is "calvin".
- `CONTROL_METHOD` selects control API: `ipmi`, `redfish`, or `auto`. `auto` first tries legacy IPMI raw commands and falls back to Dell OEM Redfish actions compatible with iDRAC9 v7 (e.g., R740xd on 7.00.00.182). **Default** value is `auto`.
- `FAN_SPEED` parameter can be set as a decimal (from 0 to 100%) or hexadecimaladecimal value (from 0x00 to 0x64) you want to set the fans to. **Default** value is 5(%).
- `CPU_TEMPERATURE_TRESHOLD` parameter is the T°junction (junction temperature) threshold beyond which the Dell fan mode defined in your BIOS will become active again (to protect the server hardware against overheat). **Default** value is 50(°C).
- `CHECK_INTERVAL` parameter is the time (in seconds) between each temperature check and potential profile change. **Default** value is 60(s).

### Notes for iDRAC9 v7.00.00.182 (R740xd)
- Newer iDRAC9 firmwares may restrict IPMI raw fan control (0x30 0x30...). When `CONTROL_METHOD=auto`, the script will transparently use Redfish OEM actions if IPMI fails.
- Ensure Redfish is reachable and credentials are set (`IDRAC_HOST`, `IDRAC_USERNAME`, `IDRAC_PASSWORD`). The container includes `curl` and `jq` for Redfish interactions.

## Proxmox LXC

Tested on Proxmox VE 9. Run the provisioning script on the Proxmox host as root to create a Debian 12 LXC containing the controller as a systemd service.

1) Review and set variables then run:

```bash
cd /path/to/Dell_iDRAC_fan_controller_Docker
bash proxmox/create_idrac_fan_controller_lxc.sh \
  VMID=902 HOSTNAME=idrac-fanctl STORAGE=local-lvm BRIDGE=vmbr0 \
  IDRAC_HOST=<idrac-ip> IDRAC_USERNAME=<user> IDRAC_PASSWORD=<pass> \
  CONTROL_METHOD=auto FAN_SPEED=20 CPU_TEMPERATURE_TRESHOLD=60 CHECK_INTERVAL=30
```

The script will:
- Download a Debian 12 standard template if needed
- Create an unprivileged LXC with nesting enabled
- Install `ipmitool`, `curl`, `jq`
- Push `Dell_iDRAC_fan_controller.sh` and register a systemd service `idrac-fan-controller`

Optional: To map host `/dev/ipmi0` into the container for local IPMI access, rerun with `MAP_IPMI_DEVICE=1` and ensure the host has IPMI kernel modules loaded. Redfish over network works without device mapping.

<p align="right">(<a href="#top">back to top</a>)</p>

<!-- CONTRIBUTING -->
## Contributing

Contributions are what make the open source community such an amazing place to learn, inspire, and create. Any contributions you make are **greatly appreciated**.

If you have a suggestion that would make this better, please fork the repo and create a pull request. You can also simply open an issue with the tag "enhancement".
Don't forget to give the project a star! Thanks again!

1. Fork the Project
2. Create your Feature Branch (`git checkout -b feature/AmazingFeature`)
3. Commit your Changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the Branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

<p align="right">(<a href="#top">back to top</a>)</p>
