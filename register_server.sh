#!/bin/bash

# Netbox API Automation Script - FIXED VERSION with MAC Address Objects and Interface Hierarchy
# Usage: ./register_server.sh [OPTIONS]

set -euo pipefail

# Configuration - Update these values for your environment
NETBOX_URL="https://netbox.mydomain.intra"           # Your Netbox URL
API_TOKEN="0123456789abcdef0123456789abcdef01234567" # Generate in Netbox: User -> API Tokens
DEFAULT_SITE="office"                                # Must exist in Netbox
DEFAULT_ROLE="server"                                # Must exist in Netbox
DEFAULT_STATUS="active"                              # Options: active, staged, failed, inventory, decommissioning
DEFAULT_DEVICE_TYPE=""                               # Optional: specify default device type

# Default values (can be overridden by command line)
declare -a cpu_module_types=()
declare -a cpu_module_bays=()
declare -a cpu_modules=()
declare -a memory_module_types=()   # For ModuleType creation
declare -a memory_module_bays=()    # For ModuleBay creation  
declare -a memory_modules=()        # For Module creation
declare -a disk_module_types=()
declare -a disk_module_bays=()
declare -a disk_modules=()

DEVICE_NAME=$(hostname -f)
DEVICE_TYPE=""
SERIAL=""
ASSET_TAG=""
COMMENTS=""
CUSTOM_FIELDS=""
AUTO_DETECT=true  # Set to false to disable auto-detection
DRY_RUN=false     # Set to true for dry-run mode
DEBUG=false       # Set to true for debug output

# Function to display usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Register or update a server in NetBox with automatic device type detection and interface creation.

OPTIONS:
    -n, --name NAME          Device name (required, defaults to hostname if not provided)
    -t, --type TYPE          Device type (overrides auto-detection)
    --no-auto-detect         Disable automatic device type detection
    -s, --serial SERIAL      Serial number (auto-detected if not provided)
    -a, --asset-tag TAG      Asset tag
    -c, --comments TEXT      Comments
    -f, --custom-fields JSON Custom fields in JSON format
    --dry-run                Test mode: show what would be done without making changes
    --debug                  Enable debug output with detailed API responses
    -h, --help               Show this help message
EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--name)
            DEVICE_NAME="$2"
            shift 2
            ;;
        -t|--type)
            DEVICE_TYPE="$2"
            AUTO_DETECT=false
            shift 2
            ;;
        --no-auto-detect)
            AUTO_DETECT=false
            shift
            ;;
        -s|--serial)
            SERIAL="$2"
            shift 2
            ;;
        -a|--asset-tag)
            ASSET_TAG="$2"
            shift 2
            ;;
        -c|--comments)
            COMMENTS="$2"
            shift 2
            ;;
        -f|--custom-fields)
            CUSTOM_FIELDS="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --debug)
            DEBUG=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

#######################################################################################
# Function Helpers
#######################################################################################

# Debug function
_debug_print() {
    if [[ "$DEBUG" == true ]]; then
        echo "DEBUG: $*" >&2
    fi
}

# Make API requests
_api_request() {
    local method="$1"
    local endpoint="$2"
    local parameter="$3"
    local data="$4"

    local end_url
    if [[ -n "$parameter" ]]; then
        end_url="$NETBOX_URL/api/$endpoint/$parameter"
    else
        end_url="$NETBOX_URL/api/$endpoint/"
    fi

    if [[ -n "$data" ]]; then
        _debug_print "API Request: $method $end_url"
        _debug_print "API Payload: $data"
        local response
        response=$(curl -sS -X "$method" \
             -H "Authorization: Token $API_TOKEN" \
             -H "Content-Type: application/json" \
             -H "Accept: application/json" \
             -d "$data" \
             "$end_url")
        _debug_print "API Response: $response"
        echo "$response"
    else
        _debug_print "API Request: $method $end_url"
        local response
        response=$(curl -sS -X "$method" \
             -H "Authorization: Token $API_TOKEN" \
             -H "Content-Type: application/json" \
             -H "Accept: application/json" \
             "$end_url")
        _debug_print "API Response: $response"
        echo "$response"
    fi
}

_trim() {
    local var="$*"
    # Remove leading and trailing whitespace
    var="${var#"${var%%[![:space:]]*}"}"   # Remove leading
    var="${var%"${var##*[![:space:]]}"}"   # Remove trailing
    printf '%s' "$var"
}

#######################################################################################
## Manufacturer
#######################################################################################

_ensure_manufacturer() {
    local name="$1"
    # Trim and escape for URL
    local safe_name
    safe_name=$(printf '%s' "$name" | jq -sRr 'split("\n") | .[0] | gsub(" "; "%20")')
    
    # Check if manufacturer exists
    local resp
    resp=$(_api_request "GET" "dcim/manufacturers" "?name=$safe_name" "")
    local count
    count=$(echo "$resp" | jq -r '.count // 0')
    
    if [[ "$count" -eq 0 ]]; then
        _debug_print "Creating manufacturer: $name"
        local payload="{\"name\":\"$name\",\"slug\":\"$(echo "$name" | tr '[:upper:]' '[:lower:]' | tr -s ' ' '-' | tr -d "'")\"}"
        _api_request "POST" "dcim/manufacturers" "" "$payload" >/dev/null
    else
        _debug_print "Manufacturer exists: $name"
    fi
}

#######################################################################################
## Device
#######################################################################################

_check_device_exists() {
    local device_name="$1"
    local response
    response=$(_api_request "GET" "dcim/devices" "?name=$device_name" "")
    echo "$response" | jq -r '.results[0].id // empty'
}

# Create device payload helper
_create_device_payload() {
    local is_update="$1"
    local json_data="{"
    json_data="${json_data}\"name\":\"$DEVICE_NAME\","
    json_data="${json_data}\"device_type\":$DEVICE_TYPE_ID,"
    json_data="${json_data}\"site\":$SITE_ID,"
    json_data="${json_data}\"role\":$ROLE_ID,"
    json_data="${json_data}\"status\":\"$DEFAULT_STATUS\","

    if [[ -n "$SERIAL" ]]; then
        json_data="${json_data}\"serial\":\"$SERIAL\","
    fi

    if [[ -n "$ASSET_TAG" ]]; then
        json_data="${json_data}\"asset_tag\":\"$ASSET_TAG\","
    fi

    json_data="${json_data}\"comments\":\"$COMMENTS_PAYLOAD\""

    if [[ "$is_update" == "true" ]]; then
        json_data="${json_data},\"id\":$EXISTING_DEVICE_ID"
    fi

    json_data="${json_data}}"
    echo "$json_data"
}


#######################################################################################
## Device Type
#######################################################################################

# Function to detect device type automatically
_detect_device_type() {
    _debug_print "Starting device type detection..."
    
    if command -v dmidecode >/dev/null 2>&1 && [[ $EUID -eq 0 ]]; then
        if PRODUCT_NAME=$(dmidecode -s system-product-name 2>/dev/null | tr -d '\0'); then
            if [[ -n "$PRODUCT_NAME" && "$PRODUCT_NAME" != "To be filled by O.E.M." && "$PRODUCT_NAME" != "None" ]]; then
                echo "$PRODUCT_NAME"
                return 0
            fi
        fi
    fi
    
    if [[ -f "/sys/class/dmi/id/product_name" ]]; then
        PRODUCT_NAME=$(cat /sys/class/dmi/id/product_name 2>/dev/null)
        if [[ -n "$PRODUCT_NAME" && "$PRODUCT_NAME" != "To be filled by O.E.M." && "$PRODUCT_NAME" != "None" ]]; then
            echo "$PRODUCT_NAME"
            return 0
        fi
    fi
    
    echo "Generic Server"
    return 1
}

# Function to detect serial number automatically
_detect_serial() {
    if command -v dmidecode >/dev/null 2>&1 && [[ $EUID -eq 0 ]]; then
        if SERIAL_NUM=$(dmidecode -s system-serial-number 2>/dev/null | tr -d '\0'); then
            if [[ -n "$SERIAL_NUM" && "$SERIAL_NUM" != "To be filled by O.E.M." && "$SERIAL_NUM" != "None" ]]; then
                echo "$SERIAL_NUM"
                return 0
            fi
        fi
    fi
    
    if [[ -f "/sys/class/dmi/id/product_serial" ]]; then
        SERIAL_NUM=$(cat /sys/class/dmi/id/product_serial 2>/dev/null)
        if [[ -n "$SERIAL_NUM" && "$SERIAL_NUM" != "To be filled by O.E.M." && "$SERIAL_NUM" != "None" ]]; then
            echo "$SERIAL_NUM"
            return 0
        fi
    fi
    
    return 1
}

_get_site_id() {
    local site_name="$1"
    local response
    response=$(_api_request "GET" "dcim/sites" "?sluge=$site_name" "")
    local site_id
    site_id=$(echo "$response" | jq -r '.results[0].id // empty')
    if [[ -z "$site_id" ]]; then
        echo "Error: Site '$site_name' not found in Netbox" >&2
        exit 1
    fi
    echo "$site_id"
}

_get_role_id() {
    local role_name="$1"
    local response
    response=$(_api_request "GET" "dcim/device-roles" "?name=$role_name" "")
    local role_id
    role_id=$(echo "$response" | jq -r '.results[0].id // empty')
    if [[ -z "$role_id" ]]; then
        local role_payload
        local slug=$(echo "$role_name" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]-')
        role_payload=$(jq -n --arg name "$role_name" --arg slug "$slug" --arg color "0080ff" '{name: $name, slug: $slug, color: $color, vm_role: false}')
        local create_response
        create_response=$(_api_request "POST" "dcim/device-roles" "" "$role_payload")
        role_id=$(echo "$create_response" | jq -r '.id')
        if [[ -z "$role_id" ]]; then
            echo "Error: Failed to create device role '$role_name'" >&2
            exit 1
        fi
    fi
    echo "$role_id"
}

_get_device_type_id() {
    local type_name="$1"
    local response
    response=$(_api_request "GET" "dcim/device-types" "" "")
    local type_id
    type_id=$(echo "$response" | jq -r --arg model "$type_name" '.results[] | select(.model == $model) | .id | tostring | . // empty' | head -n1)
    if [[ -z "$type_id" ]] && [[ "$type_name" == *"+" ]]; then
        local stripped_name="${type_name%+}"
        type_id=$(echo "$response" | jq -r --arg model "$stripped_name" '.results[] | select(.model == $model) | .id | tostring | . // empty' | head -n1)
    fi
    if [[ -z "$type_id" ]]; then
        echo "Error: Device type '$type_name' not found in Netbox" >&2
        exit 1
    fi
    echo "$type_id"
}

#######################################################################################
# Network Detection
#######################################################################################

# Function to detect network interfaces and their hierarchy
_detect_network_interfaces() {
    _debug_print "Detecting network interfaces..."
    
    if command -v ip >/dev/null 2>&1; then
        # Get all interfaces except loopback
        ip -br link show | awk '$1 != "lo" && $1 !~ /^docker/ && $1 !~ /^veth/ && $1 !~ /^br-/ && $1 !~ /^virbr/ {print $1}'
    elif [[ -d "/sys/class/net" ]]; then
        for interface in /sys/class/net/*; do
            interface_name=$(basename "$interface")
            if [[ "$interface_name" != "lo" ]] && [[ "$interface_name" != docker* ]] && [[ "$interface_name" != veth* ]] && [[ "$interface_name" != br-* ]] && [[ "$interface_name" != virbr* ]]; then
                echo "$interface_name"
            fi
        done
    fi
}

# Function to get interface speed
_get_interface_speed() {
    local interface="$1"
    if [[ -f "/sys/class/net/$interface/speed" ]]; then
        speed=$(cat "/sys/class/net/$interface/speed" 2>/dev/null)
        if [[ "$speed" != "-1" ]] && [[ "$speed" != "" ]] && [[ "$speed" =~ ^[0-9]+$ ]]; then
            echo "$speed"
        fi
    fi
}

# Function to get interface MTU
_get_interface_mtu() {
    local interface="$1"
    if [[ -f "/sys/class/net/$interface/mtu" ]]; then
        mtu=$(cat "/sys/class/net/$interface/mtu" 2>/dev/null)
        if [[ -n "$mtu" ]] && [[ "$mtu" =~ ^[0-9]+$ ]]; then
            echo "$mtu"
        fi
    fi
}

# Function to determine interface type
_get_interface_type() {
    local interface="$1"
    local speed="$2"
    
    if [[ "$interface" == bond* ]]; then
        echo "lag"
        return
    fi
    
    if [[ "$interface" == *"br"* ]] || [[ "$interface" == vmbr* ]]; then
        echo "bridge"
        return
    fi
    
    if [[ -n "$speed" ]]; then
        if [[ "$speed" -eq 10 ]]; then
            echo "10base-t"
        elif [[ "$speed" -eq 100 ]]; then
            echo "100base-tx"
        elif [[ "$speed" -eq 1000 ]]; then
            echo "1000base-t"
        elif [[ "$speed" -eq 10000 ]]; then
            echo "10gbase-t"
        elif [[ "$speed" -eq 25000 ]]; then
            echo "25gbase-x-sfp28"
        elif [[ "$speed" -eq 40000 ]]; then
            echo "40gbase-x-qsfpp"
        elif [[ "$speed" -eq 100000 ]]; then
            echo "100gbase-x-qsfp28"
        else
            echo "other"
        fi
        return
    fi

    if [[ "$interface" == eth* ]] || [[ "$interface" == en* ]] || [[ "$interface" == em* ]]; then
        echo "1000base-t"
    elif [[ "$interface" == wlan* ]] || [[ "$interface" == wlp* ]] || [[ "$interface" == wifi* ]]; then
        echo "ieee802.11a"
    else
        echo "other"
    fi
}

# Function to get interface MAC address (prefer permanent address when available)
_get_interface_mac() {
    local interface="$1"
    
    # Try to get permanent MAC address first using 'ip' command
    if command -v ip >/dev/null 2>&1; then
        permaddr=$(ip link show "$interface" 2>/dev/null | grep -o 'permaddr [0-9a-fA-F:]\{17\}' | cut -d' ' -f2 | head -n1)
        if [[ -n "$permaddr" ]]; then
            # Validate permanent MAC address format
            if [[ "$permaddr" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
                _debug_print "Found permanent MAC address for $interface: $permaddr"
                echo "$permaddr"
                return
            fi
        fi
    fi
    
    # Fallback to regular MAC address if no permanent address found
    if [[ -f "/sys/class/net/$interface/address" ]]; then
        mac=$(cat "/sys/class/net/$interface/address" 2>/dev/null)
        if [[ "$mac" != "00:00:00:00:00:00" ]] && [[ -n "$mac" ]]; then
            # Validate MAC address format
            if [[ "$mac" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
                echo "$mac"
            else
                _debug_print "Invalid MAC format for $interface: $mac"
            fi
        fi
    fi
}

# Function to get interface master (for bonding/bridging)
_get_interface_master() {
    local interface="$1"
    
    if command -v ip >/dev/null 2>&1; then
        # Check if interface has a master
        master=$(ip link show "$interface" 2>/dev/null | grep -o 'master [^[:space:]]\+' | cut -d' ' -f2 | head -n1)
        if [[ -n "$master" ]]; then
            echo "$master"
            return
        fi
    fi
    
    # Fallback to sysfs
    if [[ -L "/sys/class/net/$interface/master" ]]; then
        master_name=$(basename "$(readlink "/sys/class/net/$interface/master" 2>/dev/null)")
        if [[ -n "$master_name" ]]; then
            echo "$master_name"
            return
        fi
    fi
    
    echo ""
}

# Get IPv4 addresses assigned to an interface (excluding loopback/link-local)
_get_interface_ipv4_addresses() {
    local interface="$1"
    local output=""
    local exit_code=0

    _debug_print "Attempting to get IPv4 addresses for interface: $interface"

    # Use timeout to prevent hanging
    if command -v timeout >/dev/null 2>&1 && command -v ip >/dev/null 2>&1; then
        _debug_print "Executing with timeout: timeout 10 ip -4 addr show dev \"$interface\" scope global"
        output=$(timeout 10 ip -4 addr show dev "$interface" scope global 2>&1) || exit_code=$?
    elif command -v ip >/dev/null 2>&1; then
        _debug_print "Executing without timeout: ip -4 addr show dev \"$interface\" scope global"
        output=$(ip -4 addr show dev "$interface" scope global 2>&1) || exit_code=$?
    else
        _debug_print "ERROR: 'ip' command not found."
        echo ""
        return 1
    fi

    # Check for timeout or command failure
    if [[ $exit_code -eq 124 ]]; then
        _debug_print "ERROR: Command 'ip -4 addr show dev $interface scope global' timed out after 10 seconds."
        echo ""
        return 1
    elif [[ $exit_code -ne 0 ]]; then
        _debug_print "ERROR: Command 'ip -4 addr show dev $interface scope global' failed with exit code $exit_code. Output: $output"
        echo ""
        return 1
    fi

    _debug_print "Raw IPv4 output for $interface:\n$output"

    # Process the output to extract the first IP address and its prefix
    if [[ -n "$output" ]]; then
        local ip_prefix
        ip_prefix=$(echo "$output" | awk '/inet / {print $2}' | head -n 1)
        if [[ -n "$ip_prefix" ]]; then
            _debug_print "Parsed IPv4 address/prefix for $interface: $ip_prefix"
            echo "$ip_prefix"
            return 0
        else
            _debug_print "No valid IPv4 address/prefix found in output for $interface."
        fi
    else
        _debug_print "No output received from 'ip -4 addr show dev $interface scope global'."
    fi
    echo ""
    return 1
}

# Get IPv6 addresses assigned to an interface (excluding link-local, loopback, temporary)
_get_interface_ipv6_addresses() {
    local interface="$1"
    local output=""
    local exit_code=0

    _debug_print "Attempting to get IPv6 addresses for interface: $interface"

    # Use timeout to prevent hanging
    if command -v timeout >/dev/null 2>&1 && command -v ip >/dev/null 2>&1; then
        _debug_print "Executing with timeout: timeout 10 ip -6 addr show dev \"$interface\" scope global -tentative -dadfailed -deprecated"
        output=$(timeout 10 ip -6 addr show dev "$interface" scope global -tentative -dadfailed -deprecated 2>&1) || exit_code=$?
    elif command -v ip >/dev/null 2>&1; then
        _debug_print "Executing without timeout: ip -6 addr show dev \"$interface\" scope global -tentative -dadfailed -deprecated"
        output=$(ip -6 addr show dev "$interface" scope global -tentative -dadfailed -deprecated 2>&1) || exit_code=$?
    else
        _debug_print "ERROR: 'ip' command not found."
        echo ""
        return 1
    fi

    # Check for timeout or command failure
    if [[ $exit_code -eq 124 ]]; then
        _debug_print "ERROR: Command 'ip -6 addr show dev $interface ...' timed out after 10 seconds."
        echo ""
        return 1
    elif [[ $exit_code -ne 0 ]]; then
        _debug_print "ERROR: Command 'ip -6 addr show dev $interface ...' failed with exit code $exit_code. Output: $output"
        echo ""
        return 1
    fi

    _debug_print "Raw IPv6 output for $interface:\n$output"

    # Process the output to extract the first IP address and its prefix
    if [[ -n "$output" ]]; then
        local ip_prefix
        ip_prefix=$(echo "$output" | grep -v "temporary\|mngtmpaddr" | awk '/inet6 / {print $2}' | grep -E '^[0-9a-fA-F]*:[0-9a-fA-F:]+' | head -n1)
        if [[ -n "$ip_prefix" ]]; then
            _debug_print "Parsed IPv6 address/prefix for $interface: $ip_prefix"
            echo "$ip_prefix"
            return 0
        else
            _debug_print "No valid IPv6 address/prefix found in output for $interface."
        fi
    else
        _debug_print "No output received from 'ip -6 addr show dev $interface ...'."
    fi
    echo ""
    return 1
}

_get_ipv4() {
    local interface_name="$1"
    local ipv4_addr

    _debug_print "Calling _get_interface_ipv4_addresses for $interface_name"
    ipv4_addr=$(_get_interface_ipv4_addresses "$interface_name") || _debug_print "_get_interface_ipv4_addresses returned non-zero or empty"
    _debug_print "Finished _get_interface_ipv4_addresses for $interface_name. Result: '${ipv4_addr:-<empty>}'"

    if [[ -n "$ipv4_addr" ]]; then
        echo $ipv4_addr
    else
        _debug_print "No IPv4 address detected for $interface_name"
    fi
}

_get_ipv6() {
    local interface_name="$1"
    local ipv6_addr

    _debug_print "Calling _get_interface_ipv6_addresses for $interface_name"
    ipv6_addr=$(_get_interface_ipv6_addresses "$interface_name") || _debug_print "_get_interface_ipv6_addresses returned non-zero or empty"
    _debug_print "Finished _get_interface_ipv6_addresses for $interface_name. Result: '${ipv6_addr:-<empty>}'"

    if [[ -n "$ipv6_addr" ]]; then
      echo $ipv6_addr
    else
        _debug_print "No IPv6 address detected for $interface_name"
    fi
}

#######################################################################################
# Interface
#######################################################################################

_get_interface_details() {
    local device_id="$1"
    local response
    response=$(_api_request "GET" "dcim/interfaces" "?device_id=$device_id" "")
    echo "$response"
}

create_or_update_interface() {
    local device_id="$1"
    local interface_name="$2"
    local mac_address="$3"
    local interface_type="$4"
    local speed="$5"
    local mtu="$6"
    local parent_interface_id=""

    # Get existing interface details
    local existing_interface_info
    existing_interface_info=$(_get_interface_details "$device_id")
    
    # Get interface details from NetBox
    local interface_id
    interface_id=$(echo "$existing_interface_info" | jq -r --arg name "$interface_name" '.results[] | select(.name == $name) | .id // empty')

    # Determine parent interface based on system master interface detection
    local master_interface=$(_get_interface_master "$interface_name")
    if [[ -n "$master_interface" ]]; then
        # Find the parent interface ID in NetBox
        parent_interface_id=$(echo "$existing_interface_info" | jq -r --arg parent_name "$master_interface" '.results[] | select(.name == $parent_name) | .id // empty')
    fi

    # Build interface payload with hierarchy support
    local interface_payload="{\"device\":$device_id,\"name\":\"$interface_name\",\"type\":\"$interface_type\""
    if [[ -n "$speed" ]]; then
        interface_payload="$interface_payload,\"speed\":$speed"
    fi
    if [[ -n "$mtu" ]]; then
        interface_payload="$interface_payload,\"mtu\":$mtu"
    fi
    
    # Add parent interface if it exists
    if [[ -n "$parent_interface_id" ]]; then
        interface_payload="$interface_payload,\"lag\":$parent_interface_id"
    fi
    
    interface_payload="$interface_payload}"

    # Create Interface or Update Interface
    if [[ -n "$interface_id" ]]; then
        _debug_print "Update interface: $interface_payload"
        if [[ "$DRY_RUN" == true ]]; then
            echo "  Interface '$interface_name' would be updated (type: $interface_type${speed:+, Speed: ${speed}Mbps}${mtu:+, MTU: $mtu}${parent_interface_id:+, Parent: $parent_interface_id})"
        else
            local update_response
            update_response=$(_api_request "PATCH" "dcim/interfaces/$interface_id" "" "$interface_payload")
            
            if echo "$update_response" | jq -e '.id' >/dev/null 2>&1; then
                echo "  Updated interface: $interface_name (ID: $interface_id)"
            else
                echo "  Warning: Failed to update interface $interface_name" >&2
                _debug_print "Full response: $update_response"
            fi
        fi
    else
        _debug_print "Create interface: $interface_payload"
        if [[ "$DRY_RUN" == true ]]; then
            echo "  Interface '$interface_name' would be created (type: $interface_type${speed:+, Speed: ${speed}Mbps}${mtu:+, MTU: $mtu}${parent_interface_id:+, Parent: $parent_interface_id})"
        else
            local create_response
            create_response=$(_api_request "POST" "dcim/interfaces" "" "$interface_payload")

            if echo "$create_response" | jq -e '.id' >/dev/null 2>&1; then
                local new_interface_id
                new_interface_id=$(echo "$create_response" | jq -r '.id')
                echo "  Created interface: $interface_name (ID: $new_interface_id)"
            else
                echo "  Warning: Failed to create interface $interface_name" >&2
                _debug_print "Full response: $create_response"
            fi
        fi
    fi
}

#######################################################################################
# MAC Address
#######################################################################################

# Function to get all MAC addresses for the device
_get_device_mac_addresses() {
    local device_id="$1"
    local response
    response=$(_api_request "GET" "dcim/mac-addresses" "?device_id=$device_id" "")
    echo "$response"
}

# Check if a MAC address object with this specific MAC exists anywhere
_check_mac_address_exists() {
    local mac_address="$1"
    # Normalize MAC address to lowercase for API query consistency
    local normalized_mac=$(echo "$mac_address" | tr '[:upper:]' '[:lower:]')
    local response
    # Correct API parameter: mac_address=
    response=$(_api_request "GET" "dcim/mac-addresses" "?mac_address=$normalized_mac" "")

    response_num=$(echo "$response" | jq '.count' )

    # Extract the ID if the MAC address object exists
    local mac_id
    mac_id=$(echo "$response" | jq --arg mac "$mac_address" '.results[] | select(.mac_address | ascii_downcase == ($mac | ascii_downcase)) | .id // empty')

    # Verify the MAC address in the response matches the requested one (defense against API quirks)
    if [[ -n "$mac_id" ]]; then
        local response_mac
        response_mac=$(echo "$response" | jq -r ".results[0].mac_address // \"\"")
        # Compare normalized versions
        if [[ "${response_mac,,}" != "$normalized_mac" ]]; then
            _debug_print "WARNING: API returned MAC address object ID $mac_id with MAC '$response_mac' instead of requested '$normalized_mac'. This indicates an API inconsistency. Treating as if MAC does not exist."
            echo ""
            return
        fi
    fi

    echo "$mac_id"
}

# Check if a MAC address object with this MAC is already assigned to the specified interface
_check_mac_assigned_to_interface() {
    local mac_address="$1"
    local interface_id="$2"
    # Normalize MAC address to lowercase for API query consistency
    local normalized_mac=$(echo "$mac_address" | tr '[:upper:]' '[:lower:]')
    local response
    # Query all MAC addresses assigned to the interface
    response=$(_api_request "GET" "dcim/mac-addresses" "?assigned_object_id=$interface_id" "")

    # Check if any of the returned MAC addresses match the one we're looking for (case-insensitive)
    local found_id
    found_id=$(echo "$response" | jq -r --arg target_mac "$normalized_mac" '.results[] | select((.mac_address | ascii_downcase) == $target_mac) | .id // empty' | head -n1)

    echo "$found_id"
}

# Check if any MAC address is assigned to a specific interface
_check_mac_assigned_to_interface_any() {
    local interface_id="$1"
    local response
    # Query all MAC addresses assigned to the interface
    response=$(_api_request "GET" "dcim/mac-addresses" "?assigned_object_id=$interface_id" "")

    # Return the first MAC address ID found for this interface
    local found_id
    found_id=$(echo "$response" | jq -r '.results[0].id // empty' | head -n1)

    echo "$found_id"
}

# Check if MAC address is assigned to any interface on the device (excluding the target interface)
_check_mac_assigned_to_other_interface() {
    local mac_address="$1"
    local device_id="$2"
    local target_interface_id="$3"
    # Normalize MAC address to lowercase for API query consistency
    local normalized_mac=$(echo "$mac_address" | tr '[:upper:]' '[:lower:]')
    
    local response
    response=$(_api_request "GET" "dcim/mac-addresses" "?device_id=$device_id" "")
    
    # Find MAC addresses that match the target MAC but are assigned to different interfaces
    local found_id
    found_id=$(echo "$response" | jq -r --arg target_mac "$normalized_mac" --arg target_id "$target_interface_id" '
        .results[] | 
        select((.mac_address | ascii_downcase) == $target_mac and (.assigned_object_id | tostring) != $target_id) | 
        .id // empty' | head -n1)

    echo "$found_id"
}

# Clean up ALL MAC addresses for the device before reassigning them
_cleanup_all_device_mac_addresses() {
    local device_id="$1"
    
    local all_mac_addresses
    all_mac_addresses=$(_get_device_mac_addresses "$device_id")
    
    # Get all MAC addresses for this device
    local mac_ids_to_cleanup
    mac_ids_to_cleanup=$(echo "$all_mac_addresses" | jq -r '.results[].id // empty')
    
    if [[ -n "$mac_ids_to_cleanup" ]]; then
        for mac_id in $mac_ids_to_cleanup; do
            if [[ "$DRY_RUN" == true ]]; then
                echo "  MAC address object $mac_id would be unassigned from device (cleanup phase)"
            else
                # Unassign the MAC address from any interface
                local update_payload="{\"assigned_object_type\":null,\"assigned_object_id\":null}"
                local update_response
                update_response=$(_api_request "PATCH" "dcim/mac-addresses/$mac_id" "" "$update_payload")
                if echo "$update_response" | jq -e '.id' >/dev/null 2>&1; then
                    _debug_print "Unassigned MAC address object (ID: $mac_id) from device during cleanup"
                else
                    echo "  Warning: Failed to unassign MAC address object (ID: $mac_id) during cleanup" >&2
                fi
            fi
        done
    fi
}

# Determine interface priority based on NetBox interface attributes
_get_interface_priority() {
    local interface_type="$1"
    local interface_name="$2"
    
    # Prioritize based on interface type and hierarchy
    # Bridge interfaces (like vmbr0) are typically top-level
    if [[ "$interface_type" == "bridge" ]] || [[ "$interface_name" == vmbr* ]]; then
        echo 100  # Bridge interfaces get highest priority
    elif [[ "$interface_type" == "lag" ]] || [[ "$interface_name" == bond* ]]; then
        echo 90   # LAG interfaces get second priority
    else
        echo 10    # Physical interfaces get lowest priority
    fi
}

#######################################################################################
# MAC Address Assignment
#######################################################################################

# Create or update MAC address object and assign it to an interface
create_or_update_mac_address_object() {
    local mac_address="$1"
    local interface_name="$2"
    local device_id="$3"
    local interface_type="$4"

    # Get interface details from NetBox
    local existing_interface_info
    existing_interface_info=$(_get_interface_details "$device_id")
    local interface_id
    interface_id=$(echo "$existing_interface_info" | jq -r --arg name "$interface_name" '.results[] | select(.name == $name) | .id // empty')

    if [[ -z "$interface_id" ]]; then
        _debug_print "Interface '$interface_name' not found for device ID $device_id"
        return 1
    fi

    # Normalize MAC address to lowercase for consistent API interaction
    local normalized_mac=$(echo "$mac_address" | tr '[:upper:]' '[:lower:]')

    # Check if MAC address object already exists
    local existing_mac_id
    existing_mac_id=$(_check_mac_address_exists "$mac_address")

    # Check if MAC is already assigned to the correct interface
    if [[ -n "$existing_mac_id" ]]; then
        local assigned_to_interface_id
        assigned_to_interface_id=$(_check_mac_assigned_to_interface "$mac_address" "$interface_id")
        
        if [[ -n "$assigned_to_interface_id" ]]; then
            _debug_print "MAC address $normalized_mac is already correctly assigned to interface ID $interface_id ($interface_name) (MAC object ID: $assigned_to_interface_id)"
            echo "  MAC address $normalized_mac is already correctly assigned to interface '$interface_name' (ID: $interface_id)"
            return 0
        fi
    fi

    # If MAC exists but is assigned to another interface, we need to check priority
    if [[ -n "$existing_mac_id" ]]; then
        # Get the interface that currently has this MAC
        local current_mac_details
        current_mac_details=$(_api_request "GET" "dcim/mac-addresses/$existing_mac_id" "" "")
        local current_interface_id
        current_interface_id=$(echo "$current_mac_details" | jq -r '.assigned_object_id // empty')
        
        if [[ -n "$current_interface_id" ]]; then
            # Get the name and type of the current interface
            local current_interface_name
            current_interface_name=$(echo "$existing_interface_info" | jq -r --arg id "$current_interface_id" '.results[] | select(.id == ($id | tonumber)) | .name // empty')
            
            if [[ -n "$current_interface_name" ]]; then
                local current_interface_type
                current_interface_type=$(echo "$existing_interface_info" | jq -r --arg id "$current_interface_id" '.results[] | select(.id == ($id | tonumber)) | .type // empty')
                
                # Get priorities
                local current_priority
                local new_priority
                current_priority=$(_get_interface_priority "$current_interface_type" "$current_interface_name")
                new_priority=$(_get_interface_priority "$interface_type" "$interface_name")
                
                # Only reassign if new interface has higher priority
                if [[ "$new_priority" -gt "$current_priority" ]]; then
                    if [[ "$DRY_RUN" == true ]]; then
                        echo "  MAC address object $existing_mac_id would be reassigned from interface '$current_interface_name' (priority: $current_priority) to interface '$interface_name' (priority: $new_priority)"
                    else
                        # Update the existing MAC object to assign it to the higher priority interface
                        local update_payload="{\"assigned_object_type\":\"dcim.interface\",\"assigned_object_id\":$interface_id}"
                        local update_response
                        update_response=$(_api_request "PATCH" "dcim/mac-addresses/$existing_mac_id" "" "$update_payload")

                        if echo "$update_response" | jq -e '.id' >/dev/null 2>&1; then
                            echo "  Reassigned MAC address object (ID: $existing_mac_id) for $normalized_mac from '$current_interface_name' to '$interface_name' (higher priority: $new_priority > $current_priority)"
                            return 0
                        else
                            echo "  Warning: Failed to reassign MAC address object for $normalized_mac" >&2
                            _debug_print "Response: $update_response"
                            return 1
                        fi
                    fi
                    return 0
                else
                    # Current interface has higher or equal priority, keep it there
                    _debug_print "MAC address $normalized_mac remains on higher priority interface '$current_interface_name' (priority: $current_priority >= $new_priority)"
                    echo "  MAC address $normalized_mac remains on interface '$current_interface_name' (higher priority: $current_priority >= $new_priority)"
                    return 0
                fi
            fi
        fi
    fi

    # If MAC doesn't exist or current interface has higher priority, create new or skip
    if [[ -z "$existing_mac_id" ]]; then
        # Create new MAC address object
        local mac_payload="{\"mac_address\":\"$normalized_mac\",\"assigned_object_type\":\"dcim.interface\",\"assigned_object_id\":$interface_id}"

        # Create MAC Address Object
        if [[ "$DRY_RUN" == true ]]; then
            echo "  MAC address object for $normalized_mac would be created and linked to interface '$interface_name' (ID: $interface_id)"
            return 0
        else
            _debug_print "Creating MAC address object with payload: $mac_payload"
            local create_response
            create_response=$(_api_request "POST" "dcim/mac-addresses" "" "$mac_payload")

            if echo "$create_response" | jq -e '.id' >/dev/null 2>&1; then
                local new_mac_id
                new_mac_id=$(echo "$create_response" | jq -r '.id')
                echo "  Created MAC address object (ID: $new_mac_id) for $normalized_mac and assigned to interface '$interface_name' (ID: $interface_id)"
                return 0
            else
                echo "  Warning: Failed to create MAC address object for $normalized_mac" >&2
                _debug_print "Response: $create_response"
                return 1
            fi
        fi
    else
        # MAC exists but we're not reassigning it (lower priority)
        _debug_print "MAC address $normalized_mac remains on current interface (lower priority interface '$interface_name' skipped)"
        return 0
    fi
}

#######################################################################################
# IPMI
#######################################################################################

# Function to create IP address in NetBox
create_ip_address() {
    local ip_address="$1"
    local interface_id="$2"
    
    # Check if IP address already exists
    local existing_ip_id
    existing_ip_id=$(_api_request "GET" "ipam/ip-addresses" "?address=$ip_address" "" | jq -r '.results[0].id // empty')
    
    if [[ -n "$existing_ip_id" ]]; then
        echo "  IP address $ip_address already exists (ID: $existing_ip_id)"
        # Check if it's assigned to the correct interface
        local current_assignment
        current_assignment=$(_api_request "GET" "ipam/ip-addresses/$existing_ip_id" "" "" | jq -r '.assigned_object_id // empty')
        if [[ "$current_assignment" != "$interface_id" ]]; then
            if [[ "$DRY_RUN" == true ]]; then
                echo "  IP address $ip_address would be reassigned from interface $current_assignment to $interface_id"
            else
                local update_payload="{\"assigned_object_type\":\"dcim.interface\",\"assigned_object_id\":$interface_id}"
                local update_response
                update_response=$(_api_request "PATCH" "ipam/ip-addresses/$existing_ip_id" "" "$update_payload")
                if echo "$update_response" | jq -e '.id' >/dev/null 2>&1; then
                    echo "  Reassigned IP address $ip_address to interface ID $interface_id"
                else
                    echo "  Warning: Failed to reassign IP address $ip_address" >&2
                fi
            fi
        fi
        return 0
    fi
    
    # Create IP address object
    local ip_payload="{\"address\":\"$ip_address\",\"assigned_object_type\":\"dcim.interface\",\"assigned_object_id\":$interface_id}"
    
    if [[ "$DRY_RUN" == true ]]; then
        echo "  IP address $ip_address would be created and assigned to interface ID $interface_id"
        return 0
    else
        _debug_print "Creating IP address with payload: $ip_payload"
        local create_response
        create_response=$(_api_request "POST" "ipam/ip-addresses" "" "$ip_payload")
        
        if echo "$create_response" | jq -e '.id' >/dev/null 2>&1; then
            local new_ip_id
            new_ip_id=$(echo "$create_response" | jq -r '.id')
            echo "  Created IP address (ID: $new_ip_id) for $ip_address and assigned to interface ID $interface_id"
            return 0
        else
            echo "  Warning: Failed to create IP address for $ip_address" >&2
            _debug_print "Response: $create_response"
            return 1
        fi
    fi
}

#######################################################################################
# IPAM Detection
#######################################################################################

_ipam_test() {
    if ! command -v ipmitool >/dev/null 2>&1; then
        _debug_print "ipmitool not found, skipping IPMI detection."
        return 1
    else
        return 0
    fi
}

_has_ipmi_interface() {
    if _ipam_test; then
        if ! ipmitool mc info >/dev/null 2>&1; then
            _debug_print "IPMI interface not available or not accessible."
            return 1
        fi
    fi
    return 0
}

create_ipmi_interface() {
    local device_id="$1"

    echo ""
    echo "Detecting IMPI interface..."
    # Run ipmitool and capture output
    local output
    local ipmi_ip
    local ipmi_mac

    output=$(ipmitool lan print 1 2>/dev/null)
    ipmi_ip=$(echo "$output" | awk -F': ' '/^IP Address[[:space:]]*:/ {print $2; exit}')
    ipmi_mac=$(echo "$output" | awk -F': ' '/^MAC Address[[:space:]]*:/ {print $2; exit}')

    # test console port on device
    if _has_ipmi_interface; then
        # Display information
        cat << EOF
  Interface: IPAM
  Type:      other
  MAC:       $ipmi_mac
  IPv4:      $ipmi_ip
  -------------------------
EOF

        # Create missing console ports
        create_or_update_interface "$device_id" "IPMI" "$ipmi_mac" "other" "" ""
        echo ""
        echo "  IPMI interface created."

        # Create Mac address
        if [[ -n "$ipmi_mac" ]]; then
            echo "  MAC Address found: $ipmi_mac"
            create_or_update_mac_address_object "$ipmi_mac" "IPMI" "$device_id" "other"
        else
            echo "  No MAC Address detected for IPMI"
        fi

        # Create IP address
        if [[ -n "$ipmi_ip" ]]; then
            echo "  IPv4 Address found: $ipmi_ip"
            create_ip_address "$ipmi_ip" "$(_get_interface_details "$device_id" | jq -r --arg name "IPMI" '.results[] | select(.name == $name) | .id // empty')"
        else
            echo "  No IPv4 Address detected for IPMI"
        fi

    fi
}

#######################################################################################
# CPU
#######################################################################################

_gather_cpu_for_netbox() {
    local device_id="$1"
    cpu_module_types=()
    cpu_module_bays=()
    cpu_modules=()

    if ! command -v dmidecode &> /dev/null; then
        echo "Error: dmidecode not installed" >&2
        return 1
    fi

    local dmidecode_cmd="dmidecode -t processor"
    [[ $EUID -ne 0 ]] && command -v sudo &>/dev/null && sudo -n true &>/dev/null && dmidecode_cmd="sudo dmidecode -t processor"
    
    local output
    output=$(eval "$dmidecode_cmd" 2>/dev/null) || {
        echo "Error: dmidecode failed" >&2
        return 1
    }
    [[ -z "$output" ]] && { echo "Error: No CPU data" >&2; return 1; }

    local socket_designation manufacturer version core_count thread_count current_speed
    local in_processor=false

    while IFS= read -r line; do
        line=$(echo "$line" | sed 's/^[[:space:]]*//')
        
        if [[ "$line" == "Processor Information" ]]; then
            socket_designation=""; manufacturer=""; version=""; core_count=""; thread_count=""; current_speed=""
            in_processor=true
            continue
        elif [[ -z "$line" ]] && [[ "$in_processor" == true ]]; then
            _process_cpu_device "$device_id" "$socket_designation" "$manufacturer" "$version" "$core_count" "$thread_count" "$current_speed"
            in_processor=false
        elif [[ "$in_processor" == true ]] && [[ -n "$line" ]]; then
            case "$line" in
                "Socket Designation:"*)  socket_designation="$(_trim "${line#*: }")" ;;
                "Manufacturer:"*)        manufacturer="$(_trim "${line#*: }")" ;;
                "Version:"*)             version="$(_trim "${line#*: }")" ;;
                "Core Count:"*)          core_count="$(_trim "${line#*: }")" ;;
                "Thread Count:"*)        thread_count="$(_trim "${line#*: }")" ;;
                "Current Speed:"*)       current_speed="$(_trim "${line#*: }")" ;;
            esac
        fi
    done <<< "$output"

    if [[ "$in_processor" == true ]]; then
        _process_cpu_device "$device_id" "$socket_designation" "$manufacturer" "$version" "$core_count" "$thread_count" "$current_speed"
    fi
}

_process_cpu_device() {
    local device_id="$1" socket="$2" manufacturer="$3" version="$4" cores="$5" threads="$6" speed="$7"

    # Skip empty or disabled CPUs
    [[ -z "$socket" ]] || [[ "$version" == *"Not Specified"* ]] || [[ "$version" == *"Not Installed"* ]] && return 0

    # Ensure manufacturer exists
    _ensure_manufacturer "$manufacturer"

    # Escape strings for JSON
    socket="${socket//\"/\\\"}"
    manufacturer="${manufacturer//\"/\\\"}"
    version="${version//\"/\\\"}"

    # Parse numeric values
    local core_count=${cores:-0}
    local thread_count=${threads:-$core_count}
    local clock_speed=0
    if [[ -n "$speed" ]]; then
        clock_speed=$(echo "$speed" | sed 's/[^0-9.]*//g')
        # Convert MHz to GHz if needed
        if (( $(echo "$clock_speed > 10000" | bc -l 2>/dev/null || echo "0") )); then
            clock_speed=$(echo "scale=2; $clock_speed / 1000" | bc -l 2>/dev/null)
        fi
    fi

    # CPU model name
    local cpu_model="$version"
    [[ "$cpu_model" == *"CPU"* ]] || [[ "$cpu_model" == *"Processor"* ]] || cpu_model="$socket"

    # 1. MODULE TYPE (CPU template) - using profile ID 1
    local module_type_json="{"
    module_type_json+="\"profile\":1,"
    module_type_json+="\"manufacturer\":{\"name\":\"$manufacturer\"},"
    module_type_json+="\"model\":\"$cpu_model\","
    module_type_json+="\"part_number\":\"$cpu_model\","
    module_type_json+="\"cores\":$core_count,"
    module_type_json+="\"threads\":$thread_count,"
    module_type_json+="\"clock_speed\":$clock_speed,"
    module_type_json+="\"socket\":\"$socket\""
    module_type_json+="}"
    cpu_module_types+=("$module_type_json")

    # 2. MODULE BAY (CPU socket on device)
    local bay_json="{\"device\":$device_id,\"name\":\"$socket\",\"description\":\"CPU Socket\",\"label\":\"CPU\"}"
    cpu_module_bays+=("$bay_json")

    # 3. MODULE (installed CPU instance) - NOTE: We'll fix the payload later using bay ID
    local module_json="{\"device\":$device_id,\"module_bay\":{\"name\":\"$socket\"},\"module_type\":{\"manufacturer\":{\"name\":\"$manufacturer\"},\"model\":\"$cpu_model\"}}"
    cpu_modules+=("$module_json")
}

_create_cpu_module_in_netbox() {
    local device_id="$1"
    declare -A cpu_module_type_map
    declare -A cpu_module_bay_id_map

    echo "Detecting CPU Items..."
    _gather_cpu_for_netbox "$device_id" || return 1

    echo "  Creating CPU modules in NetBox for device ID: $device_id"

    # 1. Create ModuleTypes (deduplicated)
    for mt_json in "${cpu_module_types[@]}"; do
        local manuf=$(echo "$mt_json" | jq -r '.manufacturer.name // empty')
        local model=$(echo "$mt_json" | jq -r '.model // empty')
        local key="${manuf}_${model}"
        
        if [[ -n "$manuf" ]] && [[ -n "$model" ]] && [[ -z "${cpu_module_type_map[$key]:-}" ]]; then
            local encoded_manuf encoded_model
            encoded_manuf=$(printf '%s' "$manuf" | jq -sRr 'split("\n") | .[0] | @uri')
            encoded_model=$(printf '%s' "$model" | jq -sRr 'split("\n") | .[0] | @uri')
            local exists_resp
            exists_resp=$(_api_request "GET" "dcim/module-types" "?manufacturer=$encoded_manuf&model=$encoded_model" "")
            local count
            count=$(echo "$exists_resp" | jq -r '.count // 0')
            if [[ "$count" -eq 0 ]]; then
                _debug_print "Creating CPU ModuleType: $manuf / $model"
                _api_request "POST" "dcim/module-types" "" "$mt_json" >/dev/null
            else
                _debug_print "CPU ModuleType already exists: $manuf / $model"
            fi
            cpu_module_type_map["$key"]=1
        fi
    done

    # 2. Create ModuleBays AND store IDs (with proper URL encoding)
    for bay_json in "${cpu_module_bays[@]}"; do
        local bay_name
        bay_name=$(echo "$bay_json" | jq -r '.name // empty')
        if [[ -n "$bay_name" ]]; then
            # Properly URL encode the bay name for GET requests
            local encoded_bay_name
            encoded_bay_name=$(printf '%s' "$bay_name" | jq -sRr 'split("\n") | .[0] | @uri')
            local bay_exists
            bay_exists=$(_api_request "GET" "dcim/module-bays" "?device_id=$device_id&name=$encoded_bay_name" "")
            local bay_count
            bay_count=$(echo "$bay_exists" | jq -r '.count // 0')
            if [[ "$bay_count" -eq 0 ]]; then
                echo "  Creating CPU ModuleBay: $bay_name"
                local bay_resp
                bay_resp=$(_api_request "POST" "dcim/module-bays" "" "$bay_json")
                local bay_id
                bay_id=$(echo "${bay_resp%???}" | jq -r '.id // empty' 2>/dev/null || echo "")
                if [[ -n "$bay_id" ]]; then
                    cpu_module_bay_id_map["$bay_name"]="$bay_id"
                    _debug_print "Created CPU ModuleBay $bay_name with ID: $bay_id"
                else
                    _debug_print "ERROR: Failed to get ID for new CPU ModuleBay: $bay_name"
                fi
            else
                echo "  CPU ModuleBay already exists: $bay_name"
                local bay_id
                bay_id=$(echo "$bay_exists" | jq -r '.results[0].id // empty')
                if [[ -n "$bay_id" ]]; then
                    cpu_module_bay_id_map["$bay_name"]="$bay_id"
                    _debug_print "Existing CPU ModuleBay $bay_name has ID: $bay_id"
                else
                    _debug_print "ERROR: Failed to get ID for existing CPU ModuleBay: $bay_name"
                fi
            fi
        fi
    done

    # 3. Create Modules using ModuleBay IDs
    for mod_json in "${cpu_modules[@]}"; do
        local mod_bay_name
        mod_bay_name=$(echo "$mod_json" | jq -r '.module_bay.name // empty')
        if [[ -n "$mod_bay_name" ]]; then
            if [[ -n "${cpu_module_bay_id_map[$mod_bay_name]:-}" ]]; then
                local bay_id="${cpu_module_bay_id_map[$mod_bay_name]}"
                # Check if module exists using ModuleBay ID
                local mod_exists
                mod_exists=$(_api_request "GET" "dcim/modules" "?device_id=$device_id&module_bay_id=$bay_id" "")
                local mod_count
                mod_count=$(echo "$mod_exists" | jq -r '.count // 0')
                
                if [[ "$mod_count" -eq 0 ]]; then
                    # Fix payload to use bay ID instead of name
                    local fixed_mod_json
                    fixed_mod_json=$(echo "$mod_json" | jq --arg id "$bay_id" '.module_bay = ($id | tonumber)' 2>/dev/null || echo "$mod_json")
                    echo "Creating CPU Module in bay: $mod_bay_name"
                    _api_request "POST" "dcim/modules" "" "$fixed_mod_json" >/dev/null
                else
                    echo "CPU Module already exists in bay: $mod_bay_name"
                fi
            else
                _debug_print "ERROR: No CPU ModuleBay ID found for: $mod_bay_name"
            fi
        fi
    done

    echo "CPU module sync completed."
}

#######################################################################################
# Memory
#######################################################################################

_gather_memory_for_netbox() {
    local device_id="$1"  # NetBox device ID or name

    # Clear global arrays
    memory_module_types=()
    memory_module_bays=()
    memory_modules=()

    # ... [dmidecode execution logic - same as before] ...
    if ! command -v dmidecode &> /dev/null; then
        echo "Error: dmidecode not installed" >&2
        return 1
    fi

    local dmidecode_cmd="dmidecode -t 17"
    [[ $EUID -ne 0 ]] && command -v sudo &>/dev/null && sudo -n true &>/dev/null && dmidecode_cmd="sudo dmidecode -t 17"
    
    local output
    output=$(eval "$dmidecode_cmd" 2>/dev/null) || {
        echo "Error: dmidecode failed" >&2
        return 1
    }
    [[ -z "$output" ]] && { echo "Error: No memory data" >&2; return 1; }

    local size type speed manufacturer part_number serial locator bank_locator
    local in_device=false

    while IFS= read -r line; do
        line=$(echo "$line" | sed 's/^[[:space:]]*//')
        
        if [[ "$line" == "Memory Device" ]]; then
            size=""; type=""; speed=""; manufacturer=""; part_number=""; serial=""; locator=""; bank_locator=""
            in_device=true
            continue
        elif [[ -z "$line" ]] && [[ "$in_device" == true ]]; then
            _process_memory_device "$device_id" "$size" "$type" "$speed" "$manufacturer" "$part_number" "$serial" "$locator" "$bank_locator"
            in_device=false
        elif [[ "$in_device" == true ]] && [[ -n "$line" ]]; then
            case "$line" in
                "Size:"*)           size="$(_trim "${line#*: }")" ;;
                "Type:"*)           type="$(_trim "${line#*: }")" ;;
                "Speed:"*)          speed="$(_trim "${line#*: }")" ;;
                "Manufacturer:"*)   manufacturer="$(_trim "${line#*: }")" ;;
                "Part Number:"*)    part_number="$(_trim "${line#*: }")" ;;
                "Serial Number:"*)  serial="$(_trim "${line#*: }")" ;;
                "Locator:"*)        locator="$(_trim "${line#*: }")" ;;
                "Bank Locator:"*)   bank_locator="$(_trim "${line#*: }")" ;;
            esac
        fi
    done <<< "$output"

    # Handle last device
    if [[ "$in_device" == true ]]; then
        _process_memory_device "$device_id" "$size" "$type" "$speed" "$manufacturer" "$part_number" "$serial" "$locator" "$bank_locator"
    else
        _debug_print "No device found"
    fi
}

_process_memory_device() {
    local device_id="$1" size="$2" type="$3" speed="$4" manufacturer="$5" part_number="$6" serial="$7" locator="$8" bank_locator="$9"

    # Skip empty slots
    [[ -z "$size" ]] || [[ "$size" == "No Module Installed"* ]] && return 0

    # Ensure manufacturer exists
    _ensure_manufacturer "$manufacturer"

    # Escape values for JSON (only for string fields)
    manufacturer="${manufacturer//\"/\\\"}"
    part_number="${part_number//\"/\\\"}"
    serial="${serial//\"/\\\"}"
    locator="${locator//\"/\\\"}"
    bank_locator="${bank_locator//\"/\\\"}"

    # === Parse profile properties ===
    # Extract size as integer (from "16 GB" → 16)
    local size_gb
    size_gb=$(echo "$size" | sed 's/[^0-9]*//g')
    [[ -z "$size_gb" ]] && size_gb=0

    # Map memory type to profile enum
    local mem_class
    case "$type" in
        *DDR5*|DDR5) mem_class="DDR5" ;;
        *DDR4*|DDR4) mem_class="DDR4" ;;
        *DDR3*|DDR3) mem_class="DDR3" ;;
        *) mem_class="DDR3" ;;  # fallback
    esac

    # Extract speed as integer (from "1600 MT/s" → 1600)
    local speed_mts
    speed_mts=$(echo "$speed" | sed 's/[^0-9]*//g')
    [[ -z "$speed_mts" ]] && speed_mts=0

    # ECC detection (optional - default false)
    # For now, we'll set to false, but you can enhance this later
    local ecc="false"

    # 1. MODULE TYPE (reusable template) - PROFILE PROPERTIES AT TOP LEVEL
    local module_type_json="{"
    module_type_json+="\"profile\":5,"
    module_type_json+="\"manufacturer\":{\"name\":\"$manufacturer\"},"
    module_type_json+="\"model\":\"$part_number\","
    module_type_json+="\"part_number\":\"$part_number\","
    module_type_json+="\"size\":$size_gb,"
    module_type_json+="\"class\":\"$mem_class\","
    module_type_json+="\"data_rate\":$speed_mts,"
    module_type_json+="\"ecc\":$ecc"
    module_type_json+="}"
    memory_module_types+=("$module_type_json")

    # 2. MODULE BAY (slot on device)
    local bay_description="$bank_locator"
    [[ -n "$bank_locator" ]] && bay_description="Bank: $bank_locator"
    local bay_json="{\"device\":$device_id,\"name\":\"$locator\",\"description\":\"$bay_description\",\"label\":\"RAM\"}"
    memory_module_bays+=("$bay_json")

    # 3. MODULE (installed instance)
    local module_json="{\"device\":$device_id,\"module_bay\":{\"name\":\"$locator\"},\"module_type\":{\"manufacturer\":{\"name\":\"$manufacturer\"},\"model\":\"$part_number\"}"
    [[ -n "$serial" ]] && module_json+=",\"serial\":\"$serial\""
    module_json+="}"
    memory_modules+=("$module_json")
}

_create_memory_module_in_netbox() {
    local device_id="$1"
    echo "Detecting Memory Items..."
    _gather_memory_for_netbox "$device_id" || return 1
    _debug_print "Memory Modules: ${memory_modules[@]}"

    _debug_print "Creating memory module in NetBox for device ID: $device_id"

    # 1. Create ModuleTypes (idempotent: check if exists first)
    for mt_json in "${memory_module_types[@]}"; do
        local manuf=$(echo "$mt_json" | jq -r '.manufacturer.name // empty')
        local model=$(echo "$mt_json" | jq -r '.model // empty')
        
        if [[ -n "$manuf" ]] && [[ -n "$model" ]]; then
            local encoded_manuf encoded_model
            encoded_manuf=$(printf '%s' "$manuf" | jq -sRr 'split("\n") | .[0] | @uri')
            encoded_model=$(printf '%s' "$model" | jq -sRr 'split("\n") | .[0] | @uri')
            local exists_resp
            exists_resp=$(_api_request "GET" "dcim/module-types" "?manufacturer=$encoded_manuf&model=$encoded_model" "")
            local count
            count=$(echo "$exists_resp" | jq -r '.count // 0')
            
            if [[ "$count" -eq 0 ]]; then
                _debug_print "Creating ModuleType: $manuf / $model"
                _api_request "POST" "dcim/module-types" "" "$mt_json" >/dev/null
            else
                _debug_print "ModuleType already exists: $manuf / $model"
            fi
        fi
    done

    # 2. Create ModuleBays AND store their IDs
    declare -A memory_module_bay_id_map
    for bay_json in "${memory_module_bays[@]}"; do
        local bay_name
        bay_name=$(echo "$bay_json" | jq -r '.name // empty')
        if [[ -n "$bay_name" ]]; then
            local bay_exists
            bay_exists=$(_api_request "GET" "dcim/module-bays" "?device_id=$device_id&name=$bay_name" "")
            local bay_count
            bay_count=$(echo "$bay_exists" | jq -r '.count // 0')
            
            if [[ "$bay_count" -eq 0 ]]; then
                echo "  Creating ModuleBay: $bay_name"
                local bay_resp
                bay_resp=$(_api_request "POST" "dcim/module-bays" "" "$bay_json")
                # Extract ID from response (handles curl + HTTP code)
                local bay_id
                if [[ "$bay_resp" == *"id"* ]]; then
                    bay_id=$(echo "$bay_resp" | sed 's/.*\([0-9][0-9]*\)$/\1/' | jq -r '.id // empty')
                else
                    bay_id=$(echo "${bay_resp%???}" | jq -r '.id // empty')
                fi
                if [[ -n "$bay_id" ]]; then
                    memory_module_bay_id_map["$bay_name"]="$bay_id"
                    _debug_print "Created ModuleBay $bay_name with ID: $bay_id"
                else
                    _debug_print "ERROR: Failed to get ID for new ModuleBay: $bay_name"
                fi
            else
                echo "ModuleBay already exists: $bay_name"
                local bay_id
                bay_id=$(echo "$bay_exists" | jq -r '.results[0].id // empty')
                if [[ -n "$bay_id" ]]; then
                    memory_module_bay_id_map["$bay_name"]="$bay_id"
                    _debug_print "Existing ModuleBay $bay_name has ID: $bay_id"
                else
                    _debug_print "ERROR: Failed to get ID for existing ModuleBay: $bay_name"
                fi
            fi
        fi
    done

    # 3. Create Modules
    for mod_json in "${memory_modules[@]}"; do
        local mod_bay_name
        mod_bay_name=$(echo "$mod_json" | jq -r '.module_bay.name // empty')
        if [[ -n "$mod_bay_name" ]]; then
            if [[ -n "${memory_module_bay_id_map[$mod_bay_name]}" ]]; then
                local bay_id="${memory_module_bay_id_map[$mod_bay_name]}"
                local mod_exists
                mod_exists=$(_api_request "GET" "dcim/modules" "?device_id=$device_id&module_bay_id=$bay_id" "")
                local mod_count
                mod_count=$(echo "$mod_exists" | jq -r '.count // 0')
                
                if [[ "$mod_count" -eq 0 ]]; then
                    echo "  Creating Module in bay: $mod_bay_name"
                    _api_request "POST" "dcim/modules" "" "$mod_json" >/dev/null
                else
                    echo "  Module already exists in bay: $mod_bay_name"
                fi
            else
                _debug_print "ERROR: No ModuleBay ID found for: $mod_bay_name"
            fi
        fi
    done

    echo "Memory module sync completed."
}


#######################################################################################
# Disks
#######################################################################################

_gather_disks_for_netbox() {
    local device_id="$1"
    disk_module_types=()
    disk_module_bays=()
    disk_modules=()

    echo "Detecting Hard Disks..."

    if ! command -v smartctl &> /dev/null; then
        _debug_print "ERROR: smartmontools not installed (required for disk inventory)"
        return 1
    fi

    # Get list of physical disks
    local disks
    disks=$(lsblk -d -n -o NAME 2>/dev/null | grep -E '^[a-z]+[0-9]*$')
    _debug_print "Found disk devices: $(echo "$disks" | tr '\n' ' ')"

    if [[ -z "$disks" ]]; then
        _debug_print "No disks found by lsblk"
        return 0
    fi

    local disk_count=0
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        ((disk_count++))
        _debug_print "Processing disk: /dev/$name"

        # Get SMART info - your controller works with direct access!
        local smart_info
        smart_info=$(smartctl -i "/dev/$name" 2>/dev/null)
        
        if [[ -z "$smart_info" ]] || [[ "$smart_info" == *"Read Device Identity failed"* ]]; then
            _debug_print "ERROR: smartctl failed for /dev/$name"
            continue
        fi

        _debug_print "SMART data length: $(echo "$smart_info" | wc -c) bytes"

        # Extract fields from SMART data - USE EXACT FIELD NAMES FROM YOUR OUTPUT
        local model serial interface rpm size_gb

        # Model - EXACT field name from your output: "Device Model:"
        model=$(echo "$smart_info" | grep "^Device Model:" | sed 's/Device Model:[[:space:]]*//')
        _debug_print "Extracted model: '$model'"
        [[ -z "$model" ]] && model="Unknown"

        # Serial - EXACT field name: "Serial Number:"
        serial=$(echo "$smart_info" | grep "^Serial Number:" | sed 's/Serial Number:[[:space:]]*//')
        _debug_print "Extracted serial: '$serial'"

        # Interface - your drives show "SATA Version is:" but they're SAS drives
        # Since you have LSI MegaRAID, assume SAS for enterprise drives
        interface="SAS"
        if [[ "$model" == *"SSD"* ]] || [[ "$model" == *"EVO"* ]]; then
            interface="SATA"
        fi
        _debug_print "Detected interface: '$interface'"

        # RPM - EXACT field name: "Rotation Rate:"
        rpm=0
        local rotation_line
        rotation_line=$(echo "$smart_info" | grep "^Rotation Rate:")
        if [[ -n "$rotation_line" ]]; then
            if [[ "$rotation_line" == *"solid state"* ]]; then
                rpm=0
            else
                rpm=$(echo "$rotation_line" | grep -o '[0-9]*' | head -1)
            fi
        elif [[ "$model" == *"SSD"* ]] || [[ "$model" == *"EVO"* ]]; then
            rpm=0
        else
            rpm=7200  # Default for your enterprise drives
        fi
        _debug_print "Final RPM: $rpm"

        # Size in GB (from lsblk) - fix the command and whitespace
        size_gb=0
        local size_str
        size_str=$(lsblk -d -n -o SIZE "/dev/$name" 2>/dev/null | tr -d ' ')
        _debug_print "Raw size from lsblk: '$size_str'"
        if [[ -n "$size_str" ]] && [[ "$size_str" =~ ^([0-9.]+)([KMGT])$ ]]; then
            local num="${BASH_REMATCH[1]}"
            local unit="${BASH_REMATCH[2]}"
            case "$unit" in
                K) size_gb=$(echo "scale=0; $num / 1024 / 1024" | bc -l 2>/dev/null || echo "0") ;;
                M) size_gb=$(echo "scale=0; $num / 1024" | bc -l 2>/dev/null || echo "0") ;;
                G) size_gb=$(echo "scale=0; $num" | bc -l 2>/dev/null || echo "0") ;;
                T) size_gb=$(echo "scale=0; $num * 1024" | bc -l 2>/dev/null || echo "0") ;;
            esac
        fi
        size_gb=${size_gb:-0}  # Ensure it's always a number
        _debug_print "Final size in GB: $size_gb"

        if [[ "$model" == "Unknown" ]]; then
            _debug_print "Skipping disk with unknown model"
            continue
        fi

        _debug_print "Successfully processed disk: $name -> $model ($size_gb GB, $interface, $rpm RPM)"
        _process_disk_device "$device_id" "$name" "$model" "$size_gb" "$interface" "$serial" "$rpm" ""
    done <<< "$disks"

    _debug_print "Total disks processed: $disk_count"
    _debug_print "Disk module types to create: ${#disk_module_types[@]}"
    _debug_print "Disk module bays to create: ${#disk_module_bays[@]}"
    _debug_print "Disk modules to create: ${#disk_modules[@]}"
}

_get_disk_manufacturer() {
    local disk_name="$1"
    local model="$2"
    
    # Method 1: Try /sys/block/*/device/vendor (most reliable)
    local vendor
    vendor=$(cat "/sys/block/$disk_name/device/vendor" 2>/dev/null | _trim)
    if [[ -n "$vendor" ]] && [[ "$vendor" != "ATA" ]] && [[ "$vendor" != "INTEL" ]]; then
        echo "$vendor"
        return 0
    fi

    # Method 2: Try SMART "Vendor" field
    local smart_vendor
    smart_vendor=$(smartctl -i "/dev/$disk_name" 2>/dev/null | grep -i "^Vendor:" | sed 's/Vendor:[[:space:]]*//' | _trim)
    if [[ -n "$smart_vendor" ]]; then
        echo "$smart_vendor"
        return 0
    fi

    # Method 3: Fallback to model-based detection (your current logic)
    if [[ "$model" == *"Samsung"* ]] || [[ "$model" == *"SAMSUNG"* ]]; then
        echo "Samsung"
    elif [[ "$model" == *"Seagate"* ]] || [[ "$model" == *"SEAGATE"* ]] || [[ "$model" == ST* ]] || [[ "$model" == *"ST"* ]]; then
        echo "Seagate"
    elif [[ "$model" == *"Western Digital"* ]] || [[ "$model" == *"WDC"* ]] || [[ "$model" == *"WD"* ]]; then
        echo "Western Digital"
    elif [[ "$model" == *"Toshiba"* ]] || [[ "$model" == *"TOSHIBA"* ]]; then
        echo "Toshiba"
    elif [[ "$model" == *"Intel"* ]] || [[ "$model" == *"INTEL"* ]]; then
        echo "Intel"
    elif [[ "$model" == *"Micron"* ]] || [[ "$model" == *"MICRON"* ]]; then
        echo "Micron"
    elif [[ "$model" == *"HGST"* ]] || [[ "$model" == *"Hitachi"* ]] || [[ "$model" == *"HITACHI"* ]]; then
        echo "HGST"
    else
        echo "Unknown"
    fi
}

_process_disk_device() {
    local device_id="$1" name="$2" model="$3" size_gb="$4" interface="$5" serial="$6" rpm="$7" form_factor="$8"

    # Get manufacturer directly from system
    local manufacturer
    manufacturer=$(_get_disk_manufacturer "$name" "$model")
    _ensure_manufacturer "$manufacturer"

    # Map interface to profile "type" field
    local disk_type="HDD"
    if [[ $rpm -eq 0 ]]; then
        disk_type="SSD"
    elif [[ "$interface" == "NVME" ]]; then
        disk_type="NVME"
    else
        disk_type="HDD"
    fi

    # Escape strings for JSON (but don't trim model/serial!)
    name="${name//\"/\\\"}"
    model="${model//\"/\\\"}"
    serial="${serial//\"/\\\"}"
    manufacturer="${manufacturer//\"/\\\"}"

    # Ensure size_gb and rpm are numbers (default to 0 if empty)
    size_gb=${size_gb:-0}
    rpm=${rpm:-0}

    # 1. MODULE TYPE (disk template) - using profile ID 4 with correct field names
    local module_type_json="{"
    module_type_json+="\"profile\":4,"
    module_type_json+="\"manufacturer\":{\"name\":\"$manufacturer\"},"
    module_type_json+="\"model\":\"$model\","
    module_type_json+="\"part_number\":\"$model\","
    module_type_json+="\"size\":$size_gb,"          # ← matches profile field "size"
    module_type_json+="\"speed\":$rpm,"            # ← matches profile field "speed"  
    module_type_json+="\"type\":\"$disk_type\""    # ← matches profile field "type"
    module_type_json+="}"
    disk_module_types+=("$module_type_json")

    # 2. MODULE BAY (disk bay on device)
    local bay_name="DISK-$name"
    local bay_json="{\"device\":$device_id,\"name\":\"$bay_name\",\"description\":\"Disk Bay for /dev/$name\",\"label\":\"Storage\"}"
    disk_module_bays+=("$bay_json")

    # 3. MODULE (installed disk instance)
    local module_json="{\"device\":$device_id,\"module_bay\":{\"name\":\"$bay_name\"},\"module_type\":{\"manufacturer\":{\"name\":\"$manufacturer\"},\"model\":\"$model\"}"
    [[ -n "$serial" ]] && module_json+=",\"serial\":\"$serial\""
    module_json+="}"
    disk_modules+=("$module_json")
}

_create_disk_module_in_netbox() {
    local device_id="$1"
    echo "Detecting Disk Items..."
    _gather_disks_for_netbox "$device_id" || return 1

    echo "  Creating disk modules in NetBox for device ID: $device_id"

    # 1. Create ModuleTypes (deduplicated)
    declare -A disk_module_type_map
    for mt_json in "${disk_module_types[@]}"; do
        local manuf=$(echo "$mt_json" | jq -r '.manufacturer.name // empty')
        local model=$(echo "$mt_json" | jq -r '.model // empty')
        local key="${manuf}_${model}"
        
        if [[ -n "$manuf" ]] && [[ -n "$model" ]] && [[ -z "${disk_module_type_map[$key]:-}" ]]; then
            local encoded_manuf encoded_model
            encoded_manuf=$(printf '%s' "$manuf" | jq -sRr 'split("\n") | .[0] | @uri')
            encoded_model=$(printf '%s' "$model" | jq -sRr 'split("\n") | .[0] | @uri')
            local exists_resp
            exists_resp=$(_api_request "GET" "dcim/module-types" "?manufacturer=$encoded_manuf&model=$encoded_model" "")
            local count
            count=$(echo "$exists_resp" | jq -r '.count // 0')
            if [[ "$count" -eq 0 ]]; then
                _debug_print "Creating Disk ModuleType: $manuf / $model"
                _api_request "POST" "dcim/module-types" "" "$mt_json" >/dev/null
            else
                _debug_print "Disk ModuleType already exists: $manuf / $model"
            fi
            disk_module_type_map["$key"]=1
        fi
    done

    # 2. Create ModuleBays AND store IDs
    declare -A disk_module_bay_id_map
    for bay_json in "${disk_module_bays[@]}"; do
        local bay_name
        bay_name=$(echo "$bay_json" | jq -r '.name // empty')
        if [[ -n "$bay_name" ]]; then
            local encoded_bay_name
            encoded_bay_name=$(printf '%s' "$bay_name" | jq -sRr 'split("\n") | .[0] | @uri')
            local bay_exists
            bay_exists=$(_api_request "GET" "dcim/module-bays" "?device_id=$device_id&name=$encoded_bay_name" "")
            local bay_count
            bay_count=$(echo "$bay_exists" | jq -r '.count // 0')
            if [[ "$bay_count" -eq 0 ]]; then
                echo "  Creating Disk ModuleBay: $bay_name"
                local bay_resp
                bay_resp=$(_api_request "POST" "dcim/module-bays" "" "$bay_json")
                local bay_id
                bay_id=$(echo "$bay_resp" | jq -r '.id // empty' 2>/dev/null)
                if [[ -n "$bay_id" ]]; then
                    disk_module_bay_id_map["$bay_name"]="$bay_id"
                    _debug_print "Created Disk ModuleBay $bay_name with ID: $bay_id"
                else
                    _debug_print "ERROR: Failed to get ID for new Disk ModuleBay: $bay_name"
                fi
            else
                echo "  Disk ModuleBay already exists: $bay_name"
                local bay_id
                bay_id=$(echo "$bay_exists" | jq -r '.results[0].id // empty')
                if [[ -n "$bay_id" ]]; then
                    disk_module_bay_id_map["$bay_name"]="$bay_id"
                    _debug_print "Existing Disk ModuleBay $bay_name has ID: $bay_id"
                else
                    _debug_print "ERROR: Failed to get ID for existing Disk ModuleBay: $bay_name"
                fi
            fi
        fi
    done

    # 3. Create Modules using ModuleBay IDs
    for mod_json in "${disk_modules[@]}"; do
        local mod_bay_name
        mod_bay_name=$(echo "$mod_json" | jq -r '.module_bay.name // empty')
        if [[ -n "$mod_bay_name" ]]; then
            if [[ -n "${disk_module_bay_id_map[$mod_bay_name]:-}" ]]; then
                local bay_id="${disk_module_bay_id_map[$mod_bay_name]}"
                local mod_exists
                mod_exists=$(_api_request "GET" "dcim/modules" "?device_id=$device_id&module_bay_id=$bay_id" "")
                local mod_count
                mod_count=$(echo "$mod_exists" | jq -r '.count // 0')
                
                if [[ "$mod_count" -eq 0 ]]; then
                    local fixed_mod_json
                    fixed_mod_json=$(echo "$mod_json" | jq --arg id "$bay_id" '.module_bay = ($id | tonumber)' 2>/dev/null)
                    echo "  Creating Disk Module in bay: $mod_bay_name"
                    _api_request "POST" "dcim/modules" "" "$fixed_mod_json" >/dev/null
                else
                    echo "  Disk Module already exists in bay: $mod_bay_name"
                fi
            else
                _debug_print "ERROR: No Disk ModuleBay ID found for: $mod_bay_name"
            fi
        fi
    done

    echo "Disk module sync completed."
}

#######################################################################################
# Netbox Modules
#######################################################################################
# Module pyte custom atributes
## CPU
# architecture, cores, speed
## RAM
# data_rate, size

create_modules() {
    local device_id="$1"

    echo ""
    _create_cpu_module_in_netbox "$device_id"
    _create_memory_module_in_netbox "$device_id"
    _create_disk_module_in_netbox "$device_id"
}

#######################################################################################
# Main execution
#######################################################################################
echo "Starting server registration in NetBox..."

# Auto-detect device type if enabled
if [[ "$AUTO_DETECT" == true && -z "$DEVICE_TYPE" ]]; then
    DEVICE_TYPE=$(_detect_device_type)
    echo "Detected device type: $DEVICE_TYPE"
    if [[ -z "$DEVICE_TYPE" ]]; then
        echo "Error: Device type is required." >&2
        exit 1
    fi
fi

# Auto-detect serial if not provided
if [[ -z "$SERIAL" ]]; then
    if SERIAL_DETECTED=$(_detect_serial 2>/dev/null); then
        SERIAL="$SERIAL_DETECTED"
        echo "Detected serial number: $SERIAL"
    fi
fi

# Get required IDs
SITE_ID=$(_get_site_id "$DEFAULT_SITE")
ROLE_ID=$(_get_role_id "$DEFAULT_ROLE")
DEVICE_TYPE_ID=$(_get_device_type_id "$DEVICE_TYPE")

# Prepare comments
COMMENTS_PAYLOAD="${COMMENTS:-}"

# Check if device exists
EXISTING_DEVICE_ID=$(_check_device_exists "$DEVICE_NAME")

# Register or update device
echo ""
if [[ -n "$EXISTING_DEVICE_ID" ]]; then
    echo "Device '$DEVICE_NAME' already exists (ID: $EXISTING_DEVICE_ID). Updating..."
    PAYLOAD=$(_create_device_payload "true")
    RESPONSE=$(_api_request "PUT" "dcim/devices/$EXISTING_DEVICE_ID" "" "$PAYLOAD")
    DEVICE_ID="$EXISTING_DEVICE_ID"
    echo "Device updated successfully!"
else
    echo "Creating new device '$DEVICE_NAME'..."
    PAYLOAD=$(_create_device_payload "false")
    RESPONSE=$(_api_request "POST" "dcim/devices" "" "$PAYLOAD")
    DEVICE_ID=$(echo "$RESPONSE" | jq -r '.id')
    echo "Device created successfully!"
fi
echo ""

# Detect and create network interfaces
echo "Detecting network interfaces..."
INTERFACES=$(_detect_network_interfaces)

if [[ -n "$INTERFACES" ]]; then
    echo "Found network interfaces, creating in NetBox..."

    # Convert interface list to JSON array for cleanup function
    interface_array_json="["
    first_interface=true
    while IFS= read -r interface; do
      if [[ -n "$interface" ]]; then
        if [[ "$first_interface" == true ]]; then
          interface_array_json="${interface_array_json}\"$interface\""
          first_interface=false
        else
          interface_array_json="${interface_array_json},\"$interface\""
        fi
      fi
    done <<< "$INTERFACES"
    interface_array_json="${interface_array_json}]"
    
    # Clean up ALL MAC addresses for the device before reassigning them
    #_cleanup_all_device_mac_addresses "$DEVICE_ID"

    # Process each interface
    while IFS= read -r interface; do
      if [[ -n "$interface" ]]; then
        echo ""
        echo "Processing interface: $interface"

        # Gather interface properties with error handling
        MASTER=$(_get_interface_master "$interface") || MASTER=""
        SPEED=$(_get_interface_speed "$interface") || SPEED=""
        INTERFACE_TYPE=$(_get_interface_type "$interface" "$SPEED") || INTERFACE_TYPE="other"
        MTU=$(_get_interface_mtu "$interface") || MTU=""
        MAC_ADDRESS=$(_get_interface_mac "$interface") || MAC_ADDRESS=""
        IPV4_ADDRESS=$(_get_ipv4 "$interface") || IPV4_ADDRESS=""
        IPV6_ADDRESS=$(_get_ipv6 "$interface") || IPV6_ADDRESS=""

        # Display information
        cat << EOF
  Interface: $interface
  Type:      $INTERFACE_TYPE
  Master:    $MASTER
  Speed:     $SPEED
  MTU:       $MTU
  MAC:       $MAC_ADDRESS
  IPv4:      $IPV4_ADDRESS
  IPv6:      $IPV6_ADDRESS
  -------------------------
EOF
        # Create or Update Interfaces
        create_or_update_interface "$DEVICE_ID" "$interface" "$MAC_ADDRESS" "$INTERFACE_TYPE" "$SPEED" "$MTU"

        # Check for missing objects
        if [[ -n "$MAC_ADDRESS" ]]; then
            echo "  MAC Address found: $MAC_ADDRESS"
            create_or_update_mac_address_object "$MAC_ADDRESS" "$interface" "$DEVICE_ID" "$INTERFACE_TYPE"
        else
            echo "  No MAC Address detected for $interface"
        fi

        if [[ -n "$IPV4_ADDRESS" ]]; then
            echo "  IPv4 Address found: $IPV4_ADDRESS"
            create_ip_address "$IPV4_ADDRESS" "$(_get_interface_details "$DEVICE_ID" | jq -r --arg name "$interface" '.results[] | select(.name == $name) | .id // empty')"
        else
            echo "  No IPv4 Address detected for $interface"
        fi

        if [[ -n "$IPV6_ADDRESS" ]]; then
            echo "  IPv6 Address found: $IPV6_ADDRESS"
            create_ip_address "$IPV6_ADDRESS" "$(_get_interface_details "$DEVICE_ID" | jq -r --arg name "$interface" '.results[] | select(.name == $name) | .id // empty')"
        else
            echo "  No IPv6 Address detected for $interface"
        fi

        echo "  -------------------------"

      fi
    done <<< "$INTERFACES"
else
    echo "No network interfaces detected."
fi

# Create Console Port
create_ipmi_interface "$DEVICE_ID"

# Create module items
create_modules "$DEVICE_ID"

echo ""
echo "Server registration completed!"

