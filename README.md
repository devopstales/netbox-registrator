# Netbox Registrator

This project aims to create hardware automatically into [Netbox](https://github.com/netbox-community/netbox) based on standard tools (dmidecode, lldpd, parsing /sys/, etc).

The goal is to generate an existing infrastructure on Netbox and have the ability to update it regularly by executing the agent.

# Features

* Read Configs from config file or enviroment variable
* Create servers through standard tools (`dmidecode`)
* Create physical, bonding and bridge network interfaces with IPs (IPv4 & IPv6)
  * Create IPMI interface if found
* Update existing `Device` and `Interface`
* Local inventory using `Modules` for CPU, GPU, RAM, physical disks, Raid Controller, SAS Controller
* PSUs creation and power consumption reporting (based on vendor's tools)

# Missing Features

* Generic ability to guess datacenters and rack location (Configure in config file)
* Create or get existing VLAN and associate it to interfaces
* Detect if server is a VM
  * Associate hypervisor devices to the virtualization cluster
  * Associate virtual machines to the hypervisor device
* Create chassis and blade through standard tools (`dmidecode`)
  * Handle blade moving (new slot, new chassis)
* Update existing `Device` and `Interface`
  * Handle changes in physical disk, RAM
* Automatic cabling (server's interface to switch's interface) using lldp

# Requirements

- Netbox >= 4.0
- jq
- ip
- ethtoop
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
