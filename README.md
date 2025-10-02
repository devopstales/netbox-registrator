# Netbox Registrator

This project aims to create hardware automatically into [Netbox](https://github.com/netbox-community/netbox) based on standard tools (dmidecode, lldpd, parsing /sys/, etc).

The goal is to generate an existing infrastructure on Netbox and have the ability to update it regularly by executing the agent.

# Features

* Create servers through standard tools (`dmidecode`)
* Create physical, bonding and bridge network interfaces with IPs (IPv4 & IPv6)
* Create IPMI interface if found
* Update existing `Device` and `Interface`
* Local inventory using `Modules` for RAM

# Requirements

- Netbox >= 3.7
- ip
- ethtool
- dmidecode
- ipmitool
- lldpd
- lshw