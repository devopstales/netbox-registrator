#!/bin/bash

# Netbox API Automation Script - FIXED VERSION with MAC Address Objects and Interface Hierarchy
# Usage: ./register_server.sh [OPTIONS]

set -euo pipefail

# Configuration - Update these values for your environment
NETBOX_URL="https://netbox.mydomain.intra"           # Your Netbox URL (no trailing spaces!)
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

# Function to detect network interfaces and their hierarchy
detect_network_interfaces() {
    debug_print "Detecting network interfaces..."
    
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

# Function to get interface MAC address (prefer permanent address when available)
get_interface_mac() {
    local interface="$1"
    
    # Try to get permanent MAC address first using 'ip' command
    if command -v ip >/dev/null 2>&1; then
        permaddr=$(ip link show "$interface" 2>/dev/null | grep -o 'permaddr [0-9a-fA-F:]\{17\}' | cut -d' ' -f2 | head -n1)
        if [[ -n "$permaddr" ]]; then
            # Validate permanent MAC address format
            if [[ "$permaddr" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
                debug_print "Found permanent MAC address for $interface: $permaddr"
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
                debug_print "Invalid MAC format for $interface: $mac"
            fi
        fi
    fi
}

# Function to get interface master (for bonding/bridging)
get_interface_master() {
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

# Function to determine if interface should have MAC address assigned
should_assign_mac_address() {
    local interface="$1"
    
    # Get the master of this interface
    local master
    master=$(get_interface_master "$interface")
    
    if [[ -n "$master" ]]; then
        debug_print "Interface $interface has master $master"
        
        # Check if this is a physical interface in a bond (like eno1, eno2 in bond0)
        # These should get their permanent MAC address assigned
        if [[ "$interface" =~ ^(eno|eth|enp|ens|enx)[0-9]+$ ]]; then
            debug_print "Interface $interface is a physical interface with master, will assign permanent MAC address"
            return 0  # Yes, assign MAC address (preferably permanent)
        fi
        
        # For other types of slaves, don't assign MAC
        debug_print "Interface $interface is a slave, will not assign MAC address"
        return 1
    fi
    
    # This interface has no master, so assign MAC address
    debug_print "Interface $interface has no master, will assign MAC address"
    return 0
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
    
    # Trim any trailing whitespace from NETBOX_URL
    local trimmed_url="${NETBOX_URL% }"
    
    if [[ -n "$data" ]]; then
        debug_print "API Request: $method $trimmed_url/api/$endpoint/"
        debug_print "API Payload: $data"
        local response
        response=$(curl -sS -X "$method" \
             -H "Authorization: Token $API_TOKEN" \
             -H "Content-Type: application/json" \
             -H "Accept: application/json" \
             -d "$data" \
             "$trimmed_url/api/$endpoint/")
        debug_print "API Response: $response"
        echo "$response"
    else
        debug_print "API Request: $method $trimmed_url/api/$endpoint/"
        local response
        response=$(curl -sS -X "$method" \
             -H "Authorization: Token $API_TOKEN" \
             -H "Content-Type: application/json" \
             -H "Accept: application/json" \
             "$trimmed_url/api/$endpoint/")
        debug_print "API Response: $response"
        echo "$response"
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

# Get interface details for device
get_interface_details() {
    local device_id="$1"
    local response
    response=$(api_request "GET" "dcim/interfaces" "?device_id=$device_id")
    echo "$response"
}

# Check if MAC address object already exists for this specific MAC
check_mac_address_exists() {
    local mac_address="$1"
    local response
    # Use 'mac_address' parameter, not 'address'
    response=$(api_request "GET" "dcim/mac-addresses" "?mac_address=$mac_address")
    
    # Extract the ID if the MAC address object exists
    local mac_id
    mac_id=$(echo "$response" | jq -r '.results[0].id // empty')
    
    # Verify the MAC address in the response matches the requested one (defense against API quirks)
    if [[ -n "$mac_id" ]]; then
        local response_mac
        response_mac=$(echo "$response" | jq -r ".results[0].mac_address // \"\"")
        if [[ "${response_mac,,}" != "${mac_address,,}" ]]; then
            debug_print "WARNING: API returned MAC address object ID $mac_id with MAC '$response_mac' instead of requested '$mac_address'. This indicates an API inconsistency. Treating as if MAC does not exist."
            echo ""
            return
        fi
    fi
    
    echo "$mac_id"
}

# Check if MAC address object is already assigned to the correct interface
check_mac_assigned_to_interface() {
    local mac_address="$1"
    local interface_id="$2"
    local response
    # Query all MAC addresses assigned to the interface
    response=$(api_request "GET" "dcim/mac-addresses" "?assigned_object_id=$interface_id")
    
    # Check if any of the returned MAC addresses match the one we're looking for
    local found_id
    found_id=$(echo "$response" | jq -r --arg target_mac "$mac_address" '.results[] | select((.mac_address | ascii_downcase) == ($target_mac | ascii_downcase)) | .id // empty' | head -n1)
    
    echo "$found_id"
}

# Check if any MAC address object is assigned to the specified interface
check_any_mac_assigned_to_interface() {
    local interface_id="$1"
    local response
    response=$(api_request "GET" "dcim/mac-addresses" "?assigned_object_id=$interface_id")
    local existing_mac_id
    existing_mac_id=$(echo "$response" | jq -r '.results[0].id // empty')
    echo "$existing_mac_id"
}

# Create MAC address object
create_mac_address_object() {
    local mac_address="$1"
    local interface_id="$2"
    
    debug_print "Creating MAC address object for MAC: $mac_address, Interface ID: $interface_id"
    
    # Normalize MAC address for comparison (lowercase)
    local normalized_mac="${mac_address,,}"
    
    # First check if MAC address is already assigned to the correct interface (double-check)
    local assigned_to_interface_id
    assigned_to_interface_id=$(check_mac_assigned_to_interface "$normalized_mac" "$interface_id")
    
    if [[ -n "$assigned_to_interface_id" ]]; then
        debug_print "MAC address $normalized_mac is already correctly assigned to interface ID $interface_id"
        echo "  MAC address $normalized_mac is already correctly assigned to interface ID $interface_id"
        return 0 # Success, nothing to do
    fi
    
    # Check if MAC address object already exists (but may be assigned to a different interface)
    local existing_mac_id
    existing_mac_id=$(check_mac_address_exists "$normalized_mac")
    
    if [[ -n "$existing_mac_id" ]]; then
        debug_print "MAC address $normalized_mac already exists with ID $existing_mac_id, updating assignment to interface ID $interface_id"
        # Update the existing MAC address to link to the correct interface
        local update_payload="{\"assigned_object_type\":\"dcim.interface\",\"assigned_object_id\":$interface_id}"
        if [[ "$DRY_RUN" == false ]]; then
            local update_response
            update_response=$(api_request "PATCH" "dcim/mac-addresses/$existing_mac_id" "$update_payload")
            if echo "$update_response" | jq -e '.id' >/dev/null 2>&1; then
                echo "  Updated MAC address object $existing_mac_id assignment for $normalized_mac to interface ID $interface_id"
                return 0 # Success
            else
                echo "  Warning: Failed to update MAC address object $existing_mac_id assignment for $normalized_mac" >&2
                debug_print "Response: $update_response"
                return 1 # Failure
            fi
        else
            echo "  MAC address object $existing_mac_id assignment for $normalized_mac would be updated to interface ID $interface_id"
            return 0 # Success (dry-run)
        fi
    fi
    
    # Check if any MAC address object is already assigned to this interface and unassign it first
    local existing_interface_mac_id
    existing_interface_mac_id=$(check_any_mac_assigned_to_interface "$interface_id")
    
    if [[ -n "$existing_interface_mac_id" ]]; then
        debug_print "Interface $interface_id already has a MAC address object (ID: $existing_interface_mac_id) assigned. Unassigning it first."
        # Unassign the existing MAC address from the interface by setting assigned_object to null
        local unassign_payload="{\"assigned_object_type\":null,\"assigned_object_id\":null}"
        if [[ "$DRY_RUN" == false ]]; then
            local unassign_response
            unassign_response=$(api_request "PATCH" "dcim/mac-addresses/$existing_interface_mac_id" "$unassign_payload")
            if echo "$unassign_response" | jq -e '.id' >/dev/null 2>&1; then
                debug_print "Successfully unassigned MAC address object $existing_interface_mac_id from interface ID $interface_id"
            else
                echo "  Warning: Failed to unassign MAC address object $existing_interface_mac_id from interface ID $interface_id" >&2
                debug_print "Response: $unassign_response"
                # Continue anyway, as creating a new object might work
            fi
        else
            echo "  MAC address object $existing_interface_mac_id would be unassigned from interface ID $interface_id"
        fi
    fi
    
    # Create new MAC address object - use 'mac_address' field
    local mac_payload="{\"mac_address\":\"$normalized_mac\",\"assigned_object_type\":\"dcim.interface\",\"assigned_object_id\":$interface_id}"
    
    if [[ "$DRY_RUN" == false ]]; then
        debug_print "Creating MAC address object with payload: $mac_payload"
        local create_response
        create_response=$(api_request "POST" "dcim/mac-addresses" "$mac_payload")
        
        if echo "$create_response" | jq -e '.id' >/dev/null 2>&1; then
            local new_mac_id
            new_mac_id=$(echo "$create_response" | jq -r '.id')
            echo "  Created MAC address object (ID: $new_mac_id) for $normalized_mac and assigned to interface ID $interface_id"
            return 0 # Success
        else
            echo "  Warning: Failed to create MAC address object for $normalized_mac" >&2
            debug_print "Response: $create_response"
            return 1 # Failure
        fi
    else
        echo "  MAC address object for $normalized_mac would be created and linked to interface ID $interface_id"
        return 0 # Success (dry-run)
    fi
}

# Create interface with proper hierarchy (parent, lag, bridge support)
create_interface() {
    local device_id="$1"
    local interface_name="$2"
    local mac_address="$3"
    local interface_type="$4"
    local speed="$5"
    local mtu="$6"
    
    # Get master interface if it exists
    local master_interface
    master_interface=$(get_interface_master "$interface_name")
    local parent_interface_id=""
    
    if [[ -n "$master_interface" ]]; then
        # Find the parent interface ID in NetBox
        local parent_response
        parent_response=$(api_request "GET" "dcim/interfaces" "?device_id=$device_id&name=$master_interface")
        parent_interface_id=$(echo "$parent_response" | jq -r '.results[0].id // empty')
    fi
    
    # Build interface payload with hierarchy support
    local interface_payload="{\"device\":$device_id,\"name\":\"$interface_name\",\"type\":\"$interface_type\""
    
    if [[ -n "$speed" ]]; then
        interface_payload="$interface_payload,\"speed\":$speed"
    fi
    
    if [[ -n "$mtu" ]]; then
        interface_payload="$interface_payload,\"mtu\":$mtu"
    fi
    
    if [[ -n "$parent_interface_id" ]]; then
        # Add parent interface for proper hierarchy
        interface_payload="$interface_payload,\"parent\":$parent_interface_id"
    fi
    
    interface_payload="$interface_payload}"
    
    if [[ "$DRY_RUN" == false ]]; then
        debug_print "Creating interface: $interface_payload"
        local create_response
        create_response=$(api_request "POST" "dcim/interfaces" "$interface_payload")
        
        if echo "$create_response" | jq -e '.id' >/dev/null 2>&1; then
            local new_interface_id
            new_interface_id=$(echo "$create_response" | jq -r '.id')
            echo "  Created interface: $interface_name"
            
            # Create MAC address object and link it to the interface if MAC is provided
            if [[ -n "$mac_address" ]]; then
                create_mac_address_object "$mac_address" "$new_interface_id"
            fi
        else
            echo "  Warning: Failed to create interface $interface_name" >&2
            debug_print "Full response: $create_response"
        fi
    else
        echo "  Interface '$interface_name' would be created (type: $interface_type${speed:+, Speed: ${speed}Mbps}${mtu:+, MTU: $mtu}${parent_interface_id:+, Parent: $parent_interface_id})"
        if [[ -n "$mac_address" ]]; then
            echo "  MAC address object for $mac_address would be created and linked to the interface"
        fi
    fi
}

# Update interface MAC address if needed (create MAC address object)
update_interface_mac() {
    local device_id="$1"
    local interface_name="$2"
    local mac_address="$3"
    local interface_id="$4"
    
    if [[ -z "$mac_address" ]]; then
        return 0 # Nothing to do, success
    fi
    
    # Create MAC address object and link it to the interface
    if [[ "$DRY_RUN" == false ]]; then
        debug_print "Creating MAC address object for interface $interface_name (ID: $interface_id) with MAC: $mac_address"
        create_mac_address_object "$mac_address" "$interface_id"
        echo "  Updated interface '$interface_name' with MAC address: $mac_address"
    else
        echo "  Interface '$interface_name' would be updated with MAC address: $mac_address"
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

# Detect and create/update network interfaces
echo "Detecting network interfaces..."
INTERFACES=$(detect_network_interfaces)

if [[ -n "$INTERFACES" ]]; then
    echo "Found network interfaces, checking in NetBox..."
    
    # Get existing interface details to map names to IDs
    EXISTING_INTERFACE_DETAILS=$(get_interface_details "$DEVICE_ID")
    
    # Process each detected interface
    while IFS= read -r interface; do
        if [[ -n "$interface" ]]; then
            # Get interface details from NetBox
            interface_id=$(echo "$EXISTING_INTERFACE_DETAILS" | jq -r --arg name "$interface" '.results[] | select(.name == $name) | .id // empty')
            
            # Get MAC address first
            MAC_ADDRESS=$(get_interface_mac "$interface")
            SPEED=$(get_interface_speed "$interface")
            MTU=$(get_interface_mtu "$interface")
            INTERFACE_TYPE=$(get_interface_type "$interface" "$SPEED")
            
            # Normalize MAC address to lowercase for consistent handling
            if [[ -n "$MAC_ADDRESS" ]]; then
                MAC_ADDRESS=$(echo "$MAC_ADDRESS" | tr '[:upper:]' '[:lower:]')
            fi
            
            # Check if this interface should have MAC address assigned
            if should_assign_mac_address "$interface"; then
                debug_print "Interface $interface should have MAC address assigned: $MAC_ADDRESS"
                # MAC_ADDRESS is already set from get_interface_mac
            else
                debug_print "Interface $interface should not have MAC address assigned, clearing MAC"
                MAC_ADDRESS=""  # Clear MAC address for interfaces that shouldn't have one
            fi
            
            if [[ -n "$interface_id" ]]; then
                # Interface exists, update MAC address if needed
                if [[ -n "$MAC_ADDRESS" ]]; then
                    update_interface_mac "$DEVICE_ID" "$interface" "$MAC_ADDRESS" "$interface_id"
                else
                    echo "  Skipped MAC address assignment for interface '$interface' (not assigned)"
                fi
            else
                # Interface doesn't exist, create it with proper hierarchy
                create_interface "$DEVICE_ID" "$interface" "$MAC_ADDRESS" "$INTERFACE_TYPE" "$SPEED" "$MTU"
            fi
        fi
    done <<< "$INTERFACES"
    echo "Network interface processing completed!"
else
    echo "No network interfaces detected."
fi
