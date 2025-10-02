# Netbox Registrator

This project aims to create hardware automatically into [Netbox](https://github.com/netbox-community/netbox) based on standard tools (dmidecode, lldpd, parsing /sys/, etc).

The goal is to generate an existing infrastructure on Netbox and have the ability to update it regularly by executing the agent.

# Features

* Create servers through standard tools (`dmidecode`)
* Create physical, bonding and bridge network interfaces with IPs (IPv4 & IPv6)
* Create IPMI interface if found
* Update existing `Device` and `Interface`
* Local inventory using `Modules` for CPU, RAM, physical disks

# Missing Features

* Read Configs from config file or wnviroment variable
* Generic ability to guess datacenters and rack location (Configure in config file)
* Detect if server is a VM
  * Associate hypervisor devices to the virtualization cluster
  * Associate virtual machines to the hypervisor device
* Create chassis and blade through standard tools (`dmidecode`)
  * Handle blade moving (new slot, new chassis)
* Local inventory using `Modules` for GPU, Raid Controller, SAS Controller
  * Correctly set RAM and physical disk sizes (BUG)
* Update existing `Device` and `Interface`
  * Handle changes in physical disk, RAM
* PSUs creation and power consumption reporting (based on vendor's tools)
* Automatic cabling (server's interface to switch's interface) using lldp

# Requirements

- Netbox >= 3.7
- ip
- ethtool
- dmidecode
- ipmitool
- lldpd
- smartmontools
- lsblk
- lshw

## Inventory Optional requirement
- hpassacli
- hpacucli
- storcli
- omreport
