#!/bin/bash

# Netbox API Automation Script - FIXED VERSION
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
DEVICE_NAME=$(hostname -s)
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

Register or update a server in Netbox with automatic device type detection and interface creation.

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

# Debug function
debug_print() {
    if [[ "$DEBUG" == true ]]; then
        echo "DEBUG: $*" >&2
    fi
}

# Function to detect device type automatically
detect_device_type() {
    debug_print "Starting device type detection..."
    
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
detect_serial() {
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

# Function to detect network interfaces
detect_network_interfaces() {
    debug_print "Detecting network interfaces..."
    
    if command -v ip >/dev/null 2>&1; then
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

# Function to get interface MAC address
get_interface_mac() {
    local interface="$1"
    if [[ -f "/sys/class/net/$interface/address" ]]; then
        mac=$(cat "/sys/class/net/$interface/address" 2>/dev/null)
        if [[ "$mac" != "00:00:00:00:00:00" ]] && [[ -n "$mac" ]]; then
            echo "$mac"
        fi
    fi
}

# Function to get interface speed
get_interface_speed() {
    local interface="$1"
    if [[ -f "/sys/class/net/$interface/speed" ]]; then
        speed=$(cat "/sys/class/net/$interface/speed" 2>/dev/null)
        if [[ "$speed" != "-1" ]] && [[ "$speed" != "" ]] && [[ "$speed" =~ ^[0-9]+$ ]]; then
            echo "$speed"
        fi
    fi
}

# Function to get interface MTU
get_interface_mtu() {
    local interface="$1"
    if [[ -f "/sys/class/net/$interface/mtu" ]]; then
        mtu=$(cat "/sys/class/net/$interface/mtu" 2>/dev/null)
        if [[ -n "$mtu" ]] && [[ "$mtu" =~ ^[0-9]+$ ]]; then
            echo "$mtu"
        fi
    fi
}

# Function to determine interface type
get_interface_type() {
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

# Function to make API requests
api_request() {
    local method="$1"
    local endpoint="$2"
    local data="$3"
    
    debug_print "API Request: $method $NETBOX_URL/api/$endpoint/"
    if [[ -n "$data" ]]; then
        debug_print "API Payload: $data"
        curl -sS -X "$method" \
             -H "Authorization: Token $API_TOKEN" \
             -H "Content-Type: application/json" \
             -H "Accept: application/json" \
             -d "$data" \
             "$NETBOX_URL/api/$endpoint/"
    else
        curl -sS -X "$method" \
             -H "Authorization: Token $API_TOKEN" \
             -H "Accept: application/json" \
             "$NETBOX_URL/api/$endpoint/"
    fi
}

# Function to get site ID
get_site_id() {
    local site_name="$1"
    local response
    response=$(api_request "GET" "dcim/sites" "?name=$site_name")
    local site_id
    site_id=$(echo "$response" | jq -r '.results[0].id // empty')
    
    if [[ -z "$site_id" ]]; then
        echo "Error: Site '$site_name' not found in Netbox" >&2
        exit 1
    fi
    echo "$site_id"
}

# Function to get device role ID
get_role_id() {
    local role_name="$1"
    local response
    response=$(api_request "GET" "dcim/device-roles" "?name=$role_name")
    local role_id
    role_id=$(echo "$response" | jq -r '.results[0].id // empty')
    
    if [[ -z "$role_id" ]]; then
        local role_payload
        local slug=$(echo "$role_name" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]-')
        role_payload=$(jq -n --arg name "$role_name" --arg slug "$slug" --arg color "0080ff" '{name: $name, slug: $slug, color: $color, vm_role: false}')
        local create_response
        create_response=$(api_request "POST" "dcim/device-roles" "$role_payload")
        role_id=$(echo "$create_response" | jq -r '.id')
        if [[ -z "$role_id" ]]; then
            echo "Error: Failed to create device role '$role_name'" >&2
            exit 1
        fi
    fi
    echo "$role_id"
}

# Function to get device type ID
get_device_type_id() {
    local type_name="$1"
    local response
    response=$(api_request "GET" "dcim/device-types" "")
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

# Check if device already exists
check_device_exists() {
    local device_name="$1"
    local response
    response=$(api_request "GET" "dcim/devices" "?name=$device_name")
    echo "$response" | jq -r '.results[0].id // empty'
}

# Get ALL interfaces for device (workaround for API bug)
get_all_interfaces_for_device() {
    local device_id="$1"
    local response
    response=$(api_request "GET" "dcim/interfaces" "?device_id=$device_id")
    echo "$response" | jq -r '.results[].name'
}

# Create interface (with MTU support)
create_interface() {
    local device_id="$1"
    local interface_name="$2"
    local mac_address="$3"
    local interface_type="$4"
    local speed="$5"
    local mtu="$6"
    
    # Build interface payload with MTU
    local interface_payload="{\"device\":$device_id,\"name\":\"$interface_name\",\"type\":\"$interface_type\""
    
    if [[ -n "$mac_address" ]]; then
        interface_payload="$interface_payload,\"mac_address\":\"$mac_address\""
    fi
    
    if [[ -n "$speed" ]]; then
        interface_payload="$interface_payload,\"speed\":$speed"
    fi
    
    if [[ -n "$mtu" ]]; then
        interface_payload="$interface_payload,\"mtu\":$mtu"
    fi
    
    interface_payload="$interface_payload}"
    
    if [[ "$DRY_RUN" == false ]]; then
        debug_print "Creating interface: $interface_payload"
        local create_response
        create_response=$(api_request "POST" "dcim/interfaces" "$interface_payload")
        if echo "$create_response" | jq -e '.id' >/dev/null 2>&1; then
            echo "  Created interface: $interface_name"
        else
            echo "  Warning: Failed to create interface $interface_name" >&2
        fi
    else
        echo "  Interface '$interface_name' would be created (type: $interface_type${mac_address:+, MAC: $mac_address}${speed:+, Speed: ${speed}Mbps}${mtu:+, MTU: $mtu})"
    fi
}

# Main execution
echo "Starting server registration in Netbox..."

# Auto-detect device type if enabled
if [[ "$AUTO_DETECT" == true && -z "$DEVICE_TYPE" ]]; then
    DEVICE_TYPE=$(detect_device_type)
    echo "Detected device type: $DEVICE_TYPE"
fi

# Auto-detect serial if not provided
if [[ -z "$SERIAL" ]]; then
    if SERIAL_DETECTED=$(detect_serial 2>/dev/null); then
        SERIAL="$SERIAL_DETECTED"
        echo "Detected serial number: $SERIAL"
    fi
fi

# Validate required parameters
if [[ -z "$DEVICE_TYPE" ]]; then
    echo "Error: Device type is required." >&2
    exit 1
fi

# Get required IDs
SITE_ID=$(get_site_id "$DEFAULT_SITE")
ROLE_ID=$(get_role_id "$DEFAULT_ROLE")
DEVICE_TYPE_ID=$(get_device_type_id "$DEVICE_TYPE")

# Check if device exists
EXISTING_DEVICE_ID=$(check_device_exists "$DEVICE_NAME")

# Prepare comments
COMMENTS_PAYLOAD="${COMMENTS:-}"

# Create device payload
create_payload_json() {
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
    
    json_data="${json_data}\"comments\":\"$COMMENTS_PAYLOAD\""
    
    if [[ "$is_update" == "true" ]]; then
        json_data="${json_data},\"id\":$EXISTING_DEVICE_ID"
    fi
    
    json_data="${json_data}}"
    echo "$json_data"
}

# Register or update device
if [[ -n "$EXISTING_DEVICE_ID" ]]; then
    echo "Device '$DEVICE_NAME' already exists (ID: $EXISTING_DEVICE_ID). Updating..."
    PAYLOAD=$(create_payload_json "true")
    RESPONSE=$(api_request "PUT" "dcim/devices/$EXISTING_DEVICE_ID" "$PAYLOAD")
    DEVICE_ID="$EXISTING_DEVICE_ID"
    echo "Device updated successfully!"
else
    echo "Creating new device '$DEVICE_NAME'..."
    PAYLOAD=$(create_payload_json "false")
    RESPONSE=$(api_request "POST" "dcim/devices" "$PAYLOAD")
    DEVICE_ID=$(echo "$RESPONSE" | jq -r '.id')
    echo "Device created successfully!"
fi

# Detect and create network interfaces
echo "Detecting network interfaces..."
INTERFACES=$(detect_network_interfaces)

if [[ -n "$INTERFACES" ]]; then
    echo "Found network interfaces, creating in Netbox..."
    
    # Get existing interfaces to avoid duplicates (workaround for API bug)
    EXISTING_INTERFACES=$(get_all_interfaces_for_device "$DEVICE_ID")
    debug_print "Existing interfaces: $(echo "$EXISTING_INTERFACES" | tr '\n' ' ')"
    
    while IFS= read -r interface; do
        if [[ -n "$interface" ]]; then
            # Skip if interface already exists
            if echo "$EXISTING_INTERFACES" | grep -Fxq "$interface"; then
                debug_print "Interface '$interface' already exists, skipping..."
                continue
            fi
            
            MAC_ADDRESS=$(get_interface_mac "$interface")
            SPEED=$(get_interface_speed "$interface")
            MTU=$(get_interface_mtu "$interface")
            INTERFACE_TYPE=$(get_interface_type "$interface" "$SPEED")
            create_interface "$DEVICE_ID" "$interface" "$MAC_ADDRESS" "$INTERFACE_TYPE" "$SPEED" "$MTU"
        fi
    done <<< "$INTERFACES"
    echo "Network interface creation completed!"
else
    echo "No network interfaces detected."
fi
