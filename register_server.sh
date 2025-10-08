#!/bin/bash

# Netbox API Automation Script - FIXED VERSION with MAC Address Objects and Interface Hierarchy
# Usage: ./register_server.sh [OPTIONS]

set -euo pipefail

# Source config file
if [[ -f "./config.ini" ]]; then
    echo "Loading Config"
    source ./config.ini
else
    echo "Error: Missing ./config.ini"
    exit 1
fi

# Default values (can be overridden by command line)
DEVICE_NAME=$(hostname -f)
DEVICE_TYPE=""
CHASSIS_TYPE=""
BAY_NUMBER=""
CHASSIS_NAME=""
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

_print() {
    echo "$*" >&2
}

# Make API requests
_api_request() {
    local method="$1"
    local endpoint="$2"
    local parameter="$3"
    local data="${4:-}"

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
    local slug
    slug=$(echo "$name" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-_' | tr -s '-' | sed 's/-$//; s/^-//')

    # Reset global
    _CANONICAL_MANUFACTURER=""

    # Try by name first
    local resp
    resp=$(_api_request "GET" "dcim/manufacturers" "?name=$(printf '%s' "$name" | jq -sRr '@uri')" "")
    if [[ $(echo "$resp" | jq -r '.count // 0') -gt 0 ]]; then
        _CANONICAL_MANUFACTURER="$name"
        _debug_print "Manufacturer exists: $name"
        return 0
    fi

    # Try to create
    local payload="{\"name\":\"$name\",\"slug\":\"$slug\"}"
    resp=$(_api_request "POST" "dcim/manufacturers" "" "$payload")

    if [[ "$resp" == *"slug"* ]] && [[ "$resp" == *"already exists"* ]]; then
        _debug_print "Slug conflict for '$slug' – fetching existing manufacturer"
        local by_slug
        by_slug=$(_api_request "GET" "dcim/manufacturers" "?slug=$slug" "")
        local count
        count=$(echo "$by_slug" | jq -r '.count // 0')
        if [[ "$count" -gt 0 ]]; then
            _CANONICAL_MANUFACTURER=$(echo "$by_slug" | jq -r '.results[0].name')
            _debug_print "Using canonical name: '$_CANONICAL_MANUFACTURER'"
            return 0
        fi
    elif [[ "$resp" == *"id"* ]]; then
        _CANONICAL_MANUFACTURER="$name"
        _debug_print "Created manufacturer: $name"
        return 0
    fi

    _debug_print "ERROR: Failed to ensure manufacturer '$name'"
    return 1
}

#######################################################################################
## Chassis
#######################################################################################

_extract_chassis_and_bay_from_hostname() {
    local hostname="$(hostname -s)"

    # Initialize from config if provided
    if [[ -n "${DEFAULT_CHASSIS_NAME:-}" ]]; then
        CHASSIS_NAME="$DEFAULT_CHASSIS_NAME"
    fi
    if [[ -n "${DEFAULT_DEVICE_BAY_NUMBER:-}" ]]; then
        BAY_NUMBER="$DEFAULT_DEVICE_BAY_NUMBER"
    fi

    # If both are already set via config, we're done
    if [[ -n "${CHASSIS_NAME:-}" ]] && [[ -n "${BAY_NUMBER:-}" ]]; then
        return 0
    fi

    # Match pattern: <chassis>b<number> (e.g., blade03b5)
    if [[ "$hostname" =~ ^([a-zA-Z][a-zA-Z0-9]*)b([0-9]+)$ ]]; then
        CHASSIS_NAME="${BASH_REMATCH[1]}"
        BAY_NUMBER="${BASH_REMATCH[2]}"
        return 0
    fi
    # Optional: support uppercase B (e.g., blade03B5)
    if [[ "$hostname" =~ ^([a-zA-Z][a-zA-Z0-9]*)B([0-9]+)$ ]]; then
        CHASSIS_NAME="${BASH_REMATCH[1]}"
        BAY_NUMBER="${BASH_REMATCH[2]}"
        return 0
    fi
    return 1
}

_ensure_chassis_device() {
    local site_id="$1"
    local chassis_name="$2"
    local chassis_role_id=$(_get_role_id "Chassis")  

    local resp=$(_api_request "GET" "dcim/devices" "?name=$chassis_name" "")
    _debug_print "$resp"
    local chassis_id=$(echo "$resp" | jq -r '.results[0].id // empty')

    if [[ -z "$chassis_id" ]]; then
        # Create chassis device type if needed
        local chassis_type_id=$(_get_device_type_id "$CHASSIS_TYPE")
        if [[ -z "$chassis_type_id" ]]; then
            _print "ERROR: Chassis device type '$CHASSIS_TYPE' not found!" >&2
            exit 1
        fi

        # Create chassis device
        local payload=$(jq -n \
            --arg name "$chassis_name" \
            --argjson device_type "$chassis_type_id" \
            --argjson site "$site_id" \
            --argjson role "$chassis_role_id" \
            '{name: $name, device_type: $device_type, site: $site, role: $role, status: "active"}')

        if [[ "$DRY_RUN" == false ]]; then
            local create_resp=$(_api_request "POST" "dcim/devices" "" "$payload")
            chassis_id=$(echo "$create_resp" | jq -r '.id')
            _print "Created chassis: $chassis_name (ID: $chassis_id)"
        else
            _print "Chassis '$chassis_name' would be created"
            chassis_id="DRY_RUN"
        fi
    else
        _print "Chassis already exists: $chassis_name (ID: $chassis_id)"

    fi

    echo "$chassis_id"
}

#######################################################################################
## Device
#######################################################################################

_ensure_blade_chassis_role() {
    local role_name="$1"
    local slug=$(echo $role_name | tr '[:upper:]' '[:lower:]')
    local color="9e9e9e"  # Gray (matches your existing "Chassis" role)

    # Check if role already exists by name
    local response
    response=$(_api_request "GET" "dcim/device-roles" "?name=$(printf '%s' "$role_name" | jq -sRr '@uri')" "")
    local count
    count=$(echo "$response" | jq -r '.count // 0')

    if [[ "$count" -gt 0 ]]; then
        local existing_id
        existing_id=$(echo "$response" | jq -r '.results[0].id')
        _print "Device role '$role_name' already exists (ID: $existing_id)"
        return 0
    fi

    # Role doesn't exist – create it
    _print "Creating device role: $role_name"
    local payload
    payload=$(jq -n \
        --arg name "$role_name" \
        --arg slug "$slug" \
        --arg color "$color" \
        '{name: $name, slug: $slug, color: $color, vm_role: false}')

    if [[ "$DRY_RUN" == true ]]; then
        _print "DRY RUN: Would create device role '$role_name'"
        echo "DRY_RUN_ID"
        return 0
    fi

    local create_resp
    create_resp=$(_api_request "POST" "dcim/device-roles" "" "$payload")
    local new_id
    new_id=$(echo "$create_resp" | jq -r '.id // empty')

    if [[ -z "$new_id" ]]; then
        _print "ERROR: Failed to create device role '$role_name'" >&2
        _debug_print "API response: $create_resp"
        exit 1
    fi

    _print "Created device role '$role_name' (ID: $new_id)"
    echo "$new_id"
}

_ensure_blade_chassis_roles() {
    _ensure_blade_chassis_role "Blade"
    _ensure_blade_chassis_role "Server"
    _ensure_blade_chassis_role "Chassis"
}

_check_device_exists() {
    local device_name="$1"
    local response
    response=$(_api_request "GET" "dcim/devices" "?name=$device_name" "")
    echo "$response" | jq -r '.results[0].id // empty'
}

_ensure_device_bays() {
    local chassis_id="$1"
    local chassis_name="$2"
    local bay_name="$3"  # e.g., "Bay 3"

    local resp=$(_api_request "GET" "dcim/device-bays" "?device_id=$chassis_id&name=$bay_name" "")
    local count=$(echo "$resp" | jq -r '.count // 0')

    if [[ "$count" -eq 0 ]] && [[ "$DRY_RUN" == false ]]; then
        local payload=$(jq -n --arg name "$bay_name" --argjson device "$chassis_id" \
            '{name: $name, device: $device}')

        local create_resp=$(_api_request "POST" "dcim/device-bays" "" "$payload")
        
        # Check for the specific error about device bays not supported
        if echo "$create_resp" | jq -e '."__all__" // empty' >/dev/null; then
            local error_msg
            error_msg=$(echo "$create_resp" | jq -r '."__all__"[0]')
            if [[ "$error_msg" == *"does not support device bays"* ]]; then
                _print "ERROR: Cannot create device bay '$bay_name' in chassis '$chassis_name' (ID: $chassis_id)."
                _print "       The device type 'SYS-2027TR-H72RF' must have 'Subdevice Role = Parent' in NetBox."
                _print "       Please update the device type in NetBox and try again."
                exit 1
            fi
        fi
        echo "Created device bay: $bay_name in chassis $chassis_name"
    elif [[ "$count" -gt 0 ]]; then
        echo "Device bay already exists: $bay_name in chassis $chassis_name"
    fi
}

_get_device_bay_id() {
    local chassis_id="$1"
    local bay_name="$2"
    local encoded_bay_name
    encoded_bay_name=$(printf '%s' "$bay_name" | jq -sRr 'split("\n") | .[0] | @uri')
    
    local response
    response=$(_api_request "GET" "dcim/device-bays" "?device_id=$chassis_id&name=$encoded_bay_name" "")
    
    local count
    count=$(echo "$response" | jq -r '.count // 0')
    
    if [[ "$count" -eq 0 ]]; then
        _debug_print "Device bay '$bay_name' not found in chassis ID $chassis_id"
        echo ""
        return 1
    fi
    
    local bay_id
    bay_id=$(echo "$response" | jq -r '.results[0].id // empty')
    
    if [[ -z "$bay_id" ]]; then
        _debug_print "Failed to extract ID for device bay '$bay_name'"
        echo ""
        return 1
    fi
    
    echo "$bay_id"
}

# Create device payload helper
_create_device_payload() {
    local is_update="$1"
    local device_type_id="$2"
    local site_id="$3"
    local role_id="$4"
    local comments_payload="$5"
    local existing_device_id="$6"

    local json_data="{"
    json_data="${json_data}\"name\":\"$DEVICE_NAME\","
    json_data="${json_data}\"device_type\":$device_type_id,"
    json_data="${json_data}\"site\":$site_id,"
    json_data="${json_data}\"role\":$role_id,"
    json_data="${json_data}\"status\":\"$DEFAULT_STATUS\","

    if [[ -n "$SERIAL" ]]; then
        json_data="${json_data}\"serial\":\"$SERIAL\","
    fi

    if [[ -n "$ASSET_TAG" ]]; then
        json_data="${json_data}\"asset_tag\":\"$ASSET_TAG\","
    fi

    json_data="${json_data}\"comments\":\"$comments_payload\""

    if [[ "$is_update" == "true" ]]; then
        json_data="${json_data},\"id\":$existing_device_id"
    fi

    json_data="${json_data}}"
    _debug_print "Device Payload: $json_data"
    echo "$json_data"
}

create_devices() {
    local site_id=$(_get_site_id "$DEFAULT_SITE_SLUG") device_type_id role_id
    local CHASSIS_ID="" BAY_ID="" BAY_NAME=""

    _ensure_blade_chassis_roles

    # Auto-detect device type if enabled
    if [[ "$AUTO_DETECT" == true && -z "$DEVICE_TYPE" ]]; then
        _detect_device_type
        echo "Detected device type: $DEVICE_TYPE"
        if [[ -z "$DEVICE_TYPE" ]]; then
            echo "Error: Device type is required." >&2
            exit 1
        fi
        if [[ -n "$CHASSIS_TYPE" ]]; then

            # Try to extract chassis name and bay from hostname
            if _extract_chassis_and_bay_from_hostname; then
                if [[ -z "$BAY_NUMBER" ]] || [[ -z "$CHASSIS_NAME" ]]; then
                    echo "ERROR: Failed to extract chassis or bay number." >&2
                    echo "Extracted from hostname: chassis='$CHASSIS_NAME', bay='$BAY_NUMBER'" >&2
                    exit 1
                fi

                echo "Extracted from hostname: chassis='$CHASSIS_NAME', bay='$BAY_NUMBER'"
                BAY_NAME="Bay-$BAY_NUMBER"
            else
                echo "ERROR: Blade detected but hostname does not match '<chassis>b<number>' pattern (e.g., blade03b5)" >&2
                exit 1
            fi

            CHASSIS_ID=$(_ensure_chassis_device "$site_id" $CHASSIS_NAME)
            _ensure_device_bays "$CHASSIS_ID" "$CHASSIS_NAME" "$BAY_NAME"
            BAY_ID=$(_get_device_bay_id "$CHASSIS_ID" "$BAY_NAME")
            role_id=$(_get_role_id "Blade")
        else
            role_id=$(_get_role_id "Server")
        fi
    fi

    device_type_id=$(_get_device_type_id "$DEVICE_TYPE")

    # Auto-detect serial if not provided
    if [[ -z "$SERIAL" ]]; then
        SERIAL_DETECTED=$(_detect_serial 2>/dev/null)

        if [ $? -eq 0 ] && [ -n "$SERIAL_DETECTED" ]; then
            SERIAL="$SERIAL_DETECTED"
            echo "Detected serial number: $SERIAL"
        fi
    fi

    if [[ -z "$device_type_id" ]]; then
        echo "ERROR: Device Type dose not exists: $DEVICE_TYPE"
        exit 1
    fi

    # Prepare comments
    local comments_payload="${COMMENTS:-}"

    # Check if device exists
    local existing_device_id=$(_check_device_exists "$DEVICE_NAME")

    # Register or update device
    echo ""
    if [[ -n "$existing_device_id" ]]; then
        echo "Device '$DEVICE_NAME' already exists (ID: $existing_device_id). Updating..."
        PAYLOAD=$(_create_device_payload "true" "$device_type_id" "$site_id" "$role_id" "$comments_payload" "$existing_device_id")
        RESPONSE=$(_api_request "PUT" "dcim/devices/$existing_device_id" "" "$PAYLOAD")
        DEVICE_ID="$existing_device_id"
        echo "Device updated successfully!"
    else
        echo "Creating new device '$DEVICE_NAME'..."
        PAYLOAD=$(_create_device_payload "false" "$device_type_id" "$site_id" "$role_id" "$comments_payload" "")
        RESPONSE=$(_api_request "POST" "dcim/devices" "" "$PAYLOAD")
        DEVICE_ID=$(echo "$RESPONSE" | jq -r '.id')
        echo "Device created successfully!"
    fi

    if [[ -n "$CHASSIS_ID" ]] && [[ -n "$BAY_ID" ]]; then
        # Install the device into the bay by updating the bay
        local bay_patch_payload="{\"installed_device\":$DEVICE_ID}"
        _debug_print "Installing device $DEVICE_ID into bay $BAY_ID"
        _api_request "PATCH" "dcim/device-bays/$BAY_ID" "" "$bay_patch_payload"
        _print "Device installed into bay successfully."
    fi
}


#######################################################################################
## Device Type
#######################################################################################

# Function to detect device type automatically
_detect_device_type() {
    echo "Starting device type detection..."
    local lshw_json sys_product mb_product
    lshw_json=$(lshw -quiet -json 2>/dev/null)

    if [ -z "$lshw_json" ]; then
        echo "ERROR: lshw failed or returned no output." >&2
        return 1
    fi

    # Extract system and motherboard product
    sys_product=$(echo "$lshw_json" | jq -r '.product // empty')
    mb_product=$(echo "$lshw_json" | jq -r '.children[] | select(.class == "bus" and .id == "core") | .product // empty')

    sys_product=${sys_product:-""}
    mb_product=${mb_product:-""}

    # Clean system product (remove " (To be filled...)")
    local clean_sys="${sys_product%% (*}"

    # Strip trailing '+' from both
    mb_product="${mb_product%+}"
    clean_sys="${clean_sys%+}"

    # Blade detection patterns (case-insensitive, but we use literal match)
    local blade_patterns=(
        'SBI-' 'SBA-'
        'TR-' 'TP-' 'BT-'
        'SYS-5039' 'SYS-5038' 'SYS-202'
    )

    local blade_mb_patterns=(
        '^X[5-9]' '^P4'
    )

    local is_blade=0

    # Check system product
    for pat in "${blade_patterns[@]}"; do
        if [[ "$clean_sys" == *"$pat"* ]]; then
            is_blade=1
            break
        fi
    done

    # Check motherboard
    if [[ $is_blade -eq 0 ]]; then
        for pat in "${blade_mb_patterns[@]}"; do
            if [[ "$mb_product" =~ $pat ]]; then
                is_blade=1
                break
            fi
        done
    fi

    if [[ $is_blade -eq 1 ]]; then
        echo "system_type: blade"
        echo "system_model: $mb_product"

        # Determine chassis_type: prefer detected, fallback to default
        if [[ -n "$DEFAULT_CHASSIS_TYPE" ]]; then
            CHASSIS_TYPE="$DEFAULT_CHASSIS_TYPE"
        elif [[ "$clean_sys" != "Super Server" ]] && [[ "$clean_sys" != "To Be Filled By O.E.M." ]] && [[ -n "$clean_sys" ]]; then
            CHASSIS_TYPE="$clean_sys"
        else
            CHASSIS_TYPE="$clean_sys"
        fi

        echo "chassis_type: $CHASSIS_TYPE"

        # Set DEVICE_TYPE to motherboard (blade type)
        if [[ -n "$DEFAULT_DEVICE_TYPE" ]]; then
            DEVICE_TYPE="$DEFAULT_DEVICE_TYPE"
        else
            DEVICE_TYPE="$mb_product"
        fi
    else
        echo "system_type: standalone"
        echo "system_model: $mb_product"
        echo "chassis_type: N/A"

        # Standalone: no chassis, device type = motherboard
        if [[ -n "$DEFAULT_DEVICE_TYPE" ]]; then
            DEVICE_TYPE="$DEFAULT_DEVICE_TYPE"
        else
            DEVICE_TYPE="$mb_product"
        fi

        # Do NOT set CHASSIS_TYPE for standalone
        CHASSIS_TYPE=""
    fi
}

# Function to detect serial number automatically
_detect_serial() {
    if command -v lshw >/dev/null 2>&1; then
        local serial
        serial=$(lshw -quiet -json -class system 2>/dev/null | jq -r '
            if type == "array" then
                .[0].serial // empty
            else
                .serial // empty
            end
        ')
        if [[ -n "$serial" && "$serial" != "To be filled by O.E.M." && "$serial" != "None" && "$serial" != "0" ]]; then
            echo "$serial"
            return 0
        fi
    fi

    if [[ -f "/sys/class/dmi/id/product_serial" ]]; then
        local SERIAL_NUM
        SERIAL_NUM=$(cat /sys/class/dmi/id/product_serial 2>/dev/null)
        if [[ -n "$SERIAL_NUM" && "$SERIAL_NUM" != "To be filled by O.E.M." && "$SERIAL_NUM" != "None" ]]; then
            echo "$SERIAL_NUM"
            return 0
        fi
    fi

    _debug_print "ERROR: Can't Detect Serial"
    return 1
}

_get_site_id() {
    local site_name="$1"
    local response
    response=$(_api_request "GET" "dcim/sites" "?slug=$site_name" "")
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
    local speed

    # === Method 1: Use ethtool if available (preferred) ===
    if command -v ethtool >/dev/null 2>&1; then
        # Get full ethtool output once
        local ethtool_out
        ethtool_out=$(ethtool "$interface" 2>/dev/null)

        # Try to extract current speed from "Speed:" line
        if [[ "$ethtool_out" =~ Speed:\ ([0-9]+)Mb/s ]]; then
            local speed_val="${BASH_REMATCH[1]}"
            if [[ -n "$speed_val" ]] && [[ "$speed_val" =~ ^[0-9]+$ ]]; then
                echo "$speed_val"
                return 0
            fi
        fi

        # === Method 2 (last resort): Parse highest advertised speed from ethtool ===
        local speed=0
        while read -r line; do
            # Match patterns like "1000baseT/Full"
            while [[ "$line" =~ ([0-9]+)base ]]; do
                local s="${BASH_REMATCH[1]}"
                if (( s > speed )); then
                    speed="$s"
                fi
                # Remove matched part to continue
                line="${line#*${BASH_REMATCH[0]}}"
            done
        done <<< "$ethtool_out"
        if (( speed > 0 )); then
            echo "$speed"
            return 0
        fi

        if [[ -n "$speed" && "$speed" =~ ^[0-9]+$ && "$speed" -gt 0 ]]; then
            echo "$speed"
            return 0
        fi
    fi

    # === Method 2: Use /sys/class/net/$interface/speed (returns Mbps) ===
    if [[ -f "/sys/class/net/$interface/speed" ]]; then
        speed=$(cat "/sys/class/net/$interface/speed" 2>/dev/null)
        if [[ "$speed" != "-1" ]] && [[ "$speed" != "" ]] && [[ "$speed" =~ ^[0-9]+$ ]]; then
            echo "$speed"
            return 0
        fi
    fi
}

_get_interface_up_or_down() {
    local iface="$1"
    if ! ip link show "$iface" &>/dev/null; then
        return 1  # interface doesn't exist
    fi

    if ip link show "$iface" 2>/dev/null | grep -q 'state UP'; then
        echo "UP"
    else
        echo "DOWN"
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

    # Handle special interface names
    if [[ "$interface" == bond* ]]; then
        echo "lag"
        return
    fi

    if [[ "$interface" == *"br"* ]] || [[ "$interface" == vmbr* ]]; then
        echo "bridge"
        return
    fi

    # === Detect SFP / SFP+ via ethtool --module-info ===
    if command -v ethtool >/dev/null 2>&1; then
        local module_info
        module_info=$(ethtool --module-info "$interface" 2>/dev/null)

        if [[ -n "$module_info" ]]; then
            local identifier
            identifier=$(echo "$module_info" | awk '/Identifier[ \t]*:/ {print $3}')

            case "$identifier" in
                "0x03")  # SFP
                    echo "1000base-x-sfp"
                    return
                    ;;
                "0x0d")  # SFP+
                    if [[ -n "$speed" ]]; then
                        case "$speed" in
                            1000)   echo "1000base-x-sfp" ;;
                            10000)  echo "10gbase-x-sfp+" ;;
                            25000)  echo "25gbase-x-sfp28" ;;  # some SFP28
                            *)      echo "10gbase-x-sfp+" ;;
                        esac
                    else
                        echo "10gbase-x-sfp+"
                    fi
                    return
                    ;;
                "0x11")  # QSFP+
                    echo "40gbase-x-qsfpp"
                    return
                    ;;
                "0x12")  # QSFP28
                    echo "100gbase-x-qsfp28"
                    return
                    ;;
            esac
        fi
    fi

    # === Fallback: Guess from speed (assumes copper unless SFP detected) ===
    if [[ -n "$speed" ]]; then
        case "$speed" in
            10)     echo "other" ;;
            100)    echo "100base-tx" ;;
            1000)   echo "1000base-t" ;;
            10000)  echo "10gbase-t" ;;
            25000)  echo "25gbase-x-sfp28" ;;
            40000)  echo "40gbase-x-qsfpp" ;;
            100000) echo "100gbase-x-qsfp28" ;;
            *)      echo "other" ;;
        esac
        return
    fi

    # === Final fallback: interface name heuristics ===
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

declare -A nic_module_id_by_mac=()

_get_interface_pci_address() {
    local iface="$1"
    _debug_print "_get_interface_pci_address: $iface"

    # sysfs symlink (works for onboard NICs)
    local sys_link
    sys_link=$(readlink "/sys/class/net/$iface/device" 2>/dev/null)
    _debug_print "_get_interface_pci_address: $sys_link"
    if [[ "$sys_link" =~ ../../../([0-9a-f]{4}:([0-9a-f]{2}:[0-9a-f]{2}\.[0-9])) ]]; then
        echo "${BASH_REMATCH[2]}"
        return 0
    fi

    _debug_print "PCI Address Not found"
    #return 1
}

_get_interface_details() {
    local device_id="$1"
    local response
    response=$(_api_request "GET" "dcim/interfaces" "?device_id=$device_id" "")
    echo "$response"
}

_create_or_update_interface() {
    local device_id="$1"
    local interface_name="$2"
    local mac_address="$3"
    local interface_type="$4"
    local speed="$5"
    local mtu="$6"
    local active="$7"
    local parent_interface_id="$8"
    local module_id="${9:-}"  # Optional module ID

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

    if [[ -n "$module_id" ]]; then
        interface_payload="$interface_payload,\"module\":$module_id"
    fi

    # Normalize active state to uppercase (if needed)
    local active_upper=$(echo "$active" | tr '[:lower:]' '[:upper:]')

    if [[ "$active_upper" == "UP" ]]; then
        interface_payload="$interface_payload,\"enabled\":true"
    else
        interface_payload="$interface_payload,\"enabled\":false"
    fi

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

detect_and_create_network_interfaces() {
    # Detect and create network interfaces
    echo ""
    echo "Detecting network interfaces..."

    local device_id="$1"
    INTERFACES=$(_detect_network_interfaces)
    MASTER_ID=""

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
        #_cleanup_all_device_mac_addresses "$device_id"

        # Process each interface
        while IFS= read -r interface; do
        if [[ -n "$interface" ]]; then
            echo ""
            echo "Processing interface: $interface"

            # Gather interface properties with error handling
            MASTER=$(_get_interface_master "$interface") || MASTER=""
            SPEED=$(_get_interface_speed "$interface") || SPEED=""
            ACTIVE=$(_get_interface_up_or_down "$interface") || ACTIVE="DOWN"
            INTERFACE_TYPE=$(_get_interface_type "$interface" "$SPEED") || INTERFACE_TYPE="other"
            MTU=$(_get_interface_mtu "$interface") || MTU=""
            MAC_ADDRESS=$(_get_interface_mac "$interface") || MAC_ADDRESS=""
            IPV4_ADDRESS=$(_get_ipv4 "$interface") || IPV4_ADDRESS=""
            IPV6_ADDRESS=$(_get_ipv6 "$interface") || IPV6_ADDRESS=""

            # Determine MODULE_ID_FOR_INTERFACE using PCI address
            local MODULE_ID_FOR_INTERFACE=""
            local pci_addr bay_name encoded_bay_name bay_exists bay_count bay_id
            if [[ "$INTERFACE_TYPE" != "bridge" ]] && [[ "$INTERFACE_TYPE" != "lag" ]] && [[ "$interface" != vmbr* ]] && [[ "$interface" != bond* ]]; then
                pci_addr=$(_get_interface_pci_address "$interface")
                _debug_print "PCI_ADDR: $pci_addr"

                if [[ -n "$pci_addr" ]]; then
                    echo "Gether Module: on PCI address $pci_addr for $interface"
                    bay_name="PCIe-$pci_addr"
                    encoded_bay_name=$(printf '%s' "$bay_name" | jq -sRr 'split("\n") | .[0] | @uri')
                    bay_exists=$(_api_request "GET" "dcim/module-bays" "?device_id=$device_id&name=$encoded_bay_name" "")
                    bay_count=$(echo "$bay_exists" | jq -r '.count // 0')
                    if [[ "$bay_count" -gt 0 ]]; then
                        MODULE_ID_FOR_INTERFACE=$(echo "$bay_exists" | jq -r '.results[0].installed_module.id // empty')
                        if [[ -n "$MODULE_ID_FOR_INTERFACE" ]]; then
                            echo "Found NIC module ID $MODULE_ID_FOR_INTERFACE in bay $bay_name (PCI: $pci_addr) for interface $interface"
                        else
                            echo "No installed module found in bay $bay_name (PCI: $pci_addr)"
                        fi
                    else
                        echo "No module bay ID found for $bay_name (PCI: $pci_addr)"
                    fi
                else
                    echo "Skipping module assignment: no PCI address for $interface"
                fi
            else
                echo "Skipping module assignment for interface: $interface (type: $INTERFACE_TYPE)"
            fi

            # Display information
            cat << EOF
    Interface: $interface
    Active:    $ACTIVE
    Type:      $INTERFACE_TYPE
    Master:    $MASTER
    Speed:     $SPEED
    MTU:       $MTU
    MAC:       $MAC_ADDRESS
    IPv4:      $IPV4_ADDRESS
    IPv6:      $IPV6_ADDRESS
    -------------------------
EOF

            if [[ -n $MASTER ]]; then
                interface_exists=$(_api_request "GET" "dcim/interfaces" "?device_id=$device_id&name=$MASTER" "")
                interface_count=$(echo "$interface_exists" | jq -r '.count // 0')
                if [[ "$interface_count" -eq 1 ]]; then
                    MASTER_ID=$(echo "$interface_exists" | jq -r '.results[0].id // empty')
                fi
            fi

            # Create or Update Interfaces
            _create_or_update_interface "$device_id" "$interface" "$MAC_ADDRESS" "$INTERFACE_TYPE" "$SPEED" "$MTU" "$ACTIVE" "$MASTER_ID" "$MODULE_ID_FOR_INTERFACE"

            # Check for missing objects
            if [[ -n "$MAC_ADDRESS" ]]; then
                echo "  MAC Address found: $MAC_ADDRESS"
                create_or_update_mac_address_object "$MAC_ADDRESS" "$interface" "$device_id" "$INTERFACE_TYPE"
            else
                echo "  No MAC Address detected for $interface"
            fi

            if [[ -n "$IPV4_ADDRESS" ]]; then
                echo "  IPv4 Address found: $IPV4_ADDRESS"
                create_ip_address "$IPV4_ADDRESS" "$(_get_interface_details "$device_id" | jq -r --arg name "$interface" '.results[] | select(.name == $name) | .id // empty')"
            else
                echo "  No IPv4 Address detected for $interface"
            fi

            if [[ -n "$IPV6_ADDRESS" ]]; then
                echo "  IPv6 Address found: $IPV6_ADDRESS"
                create_ip_address "$IPV6_ADDRESS" "$(_get_interface_details "$device_id" | jq -r --arg name "$interface" '.results[] | select(.name == $name) | .id // empty')"
            else
                echo "  No IPv6 Address detected for $interface"
            fi

            echo "  -------------------------"

        fi
        done <<< "$INTERFACES"
    else
        echo "No network interfaces detected."
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
# IP Adress
#######################################################################################

# Function to create IP address in NetBox
create_ip_address() {
    local ip_with_prefix="$1"
    local interface_id="$2"

    # Validate input
    if [[ -z "$ip_with_prefix" ]] || [[ -z "$interface_id" ]]; then
        echo "  Error: Missing IP or interface ID for IP assignment" >&2
        return 1
    fi

    # Check if CIDR is present
    if [[ "$ip_with_prefix" != */* ]]; then
        echo "  Warning: No CIDR in IP '$ip_with_prefix'. Skipping prefix association."
        local prefix_id=""
        local full_prefix=""
    else
        # Use Python to compute network address and validate
        if command -v python3 >/dev/null 2>&1; then
            local full_prefix
            full_prefix=$(python3 -c "
import ipaddress
try:
    net = ipaddress.ip_network('$ip_with_prefix', strict=False)
    print(net)
except Exception as e:
    exit(1)
" 2>/dev/null)

            if [[ -n "$full_prefix" ]]; then
                # URL-encode the prefix for GET request
                local encoded_prefix
                encoded_prefix=$(printf '%s' "$full_prefix" | jq -sRr 'split("\n") | .[0] | @uri')

                # Check if prefix exists
                local prefix_resp
                prefix_resp=$(_api_request "GET" "ipam/prefixes" "?prefix=$encoded_prefix" "")
                local prefix_count
                prefix_count=$(echo "$prefix_resp" | jq -r '.count // 0')

                if [[ "$prefix_count" -eq 0 ]]; then
                    # Create prefix
                    local prefix_payload="{\"prefix\":\"$full_prefix\",\"status\":\"active\"}"
                    if [[ "$DRY_RUN" == true ]]; then
                        echo "  Prefix '$full_prefix' would be created"
                        prefix_id="DRY_RUN_ID"
                    else
                        _debug_print "Creating prefix: $full_prefix"
                        local create_resp
                        create_resp=$(_api_request "POST" "ipam/prefixes" "" "$prefix_payload")
                        prefix_id=$(echo "$create_resp" | jq -r '.id // empty')
                        if [[ -n "$prefix_id" ]]; then
                            echo "  Created prefix: $full_prefix (ID: $prefix_id)"
                        else
                            echo "  Warning: Failed to create prefix '$full_prefix'" >&2
                            _debug_print "Response: $create_resp"
                            prefix_id=""
                        fi
                    fi
                else
                    prefix_id=$(echo "$prefix_resp" | jq -r '.results[0].id // empty')
                    _debug_print "Prefix '$full_prefix' already exists (ID: $prefix_id)"
                fi
            else
                echo "  Warning: Could not compute network prefix for '$ip_with_prefix'" >&2
                prefix_id=""
                full_prefix=""
            fi
        else
            echo "  Warning: python3 not found. Skipping prefix creation." >&2
            prefix_id=""
            full_prefix=""
        fi
    fi

    # Handle the IP address itself
    local existing_ip_id
    existing_ip_id=$(_api_request "GET" "ipam/ip-addresses" "?address=$ip_with_prefix" "" | jq -r '.results[0].id // empty')

    # Build IP payload
    local ip_payload="{\"address\":\"$ip_with_prefix\""
    if [[ -n "$prefix_id" ]] && [[ "$prefix_id" != "DRY_RUN_ID" ]]; then
        ip_payload="$ip_payload,\"prefix\":$prefix_id"
    fi
    ip_payload="$ip_payload,\"assigned_object_type\":\"dcim.interface\",\"assigned_object_id\":$interface_id,\"status\":\"active\"}"

    if [[ -n "$existing_ip_id" ]]; then
        echo "  IP address $ip_with_prefix already exists (ID: $existing_ip_id)"
        # Check current assignment
        local current_assignment
        current_assignment=$(_api_request "GET" "ipam/ip-addresses/$existing_ip_id" "" "" | jq -r '.assigned_object_id // empty')
        if [[ "$current_assignment" != "$interface_id" ]]; then
            if [[ "$DRY_RUN" == true ]]; then
                echo "  IP would be reassigned to interface ID $interface_id"
            else
                local update_payload="{\"assigned_object_type\":\"dcim.interface\",\"assigned_object_id\":$interface_id}"
                local update_response
                update_response=$(_api_request "PATCH" "ipam/ip-addresses/$existing_ip_id" "" "$update_payload")
                if echo "$update_response" | jq -e '.id' >/dev/null 2>&1; then
                    echo "  Reassigned IP $ip_with_prefix to interface ID $interface_id"
                else
                    echo "  Warning: Failed to reassign IP $ip_with_prefix" >&2
                    _debug_print "Response: $update_response"
                fi
            fi
        fi
        return 0
    fi

    # Create new IP
    if [[ "$DRY_RUN" == true ]]; then
        echo "  IP address $ip_with_prefix would be created (prefix: ${full_prefix:-none})"
    else
        _debug_print "Creating IP with payload: $ip_payload"
        local create_response
        create_response=$(_api_request "POST" "ipam/ip-addresses" "" "$ip_payload")
        if echo "$create_response" | jq -e '.id' >/dev/null 2>&1; then
            local new_ip_id
            new_ip_id=$(echo "$create_response" | jq -r '.id')
            echo "  Created IP address (ID: $new_ip_id): $ip_with_prefix"
        else
            echo "  Warning: Failed to create IP address for $ip_with_prefix" >&2
            _debug_print "Response: $create_response"
        fi
    fi
}

#######################################################################################
# IPMI Detection
#######################################################################################

_ipmitool_test() {
    if ! command -v ipmitool >/dev/null 2>&1; then
        _debug_print "ipmitool not found, skipping IPMI detection."
        return 1
    else
        return 0
    fi
}

_has_ipmi_interface() {
    if _ipmitool_test; then
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
    local ipmi_netmask
    local ipmi_mac
    local ipmi_cidr

    output=$(ipmitool lan print 1 2>/dev/null)
    ipmi_ip=$(echo "$output" | awk -F': ' '/^IP Address[[:space:]]*:/ {print $2; exit}')
    ipmi_netmask=$(echo "$output" | awk -F': ' '/^Subnet Mask[[:space:]]*:/ {print $2; exit}')
    ipmi_mac=$(echo "$output" | awk -F': ' '/^MAC Address[[:space:]]*:/ {print $2; exit}')

    if [[ -n "$ipmi_netmask" ]]; then
        # Convert dotted decimal netmask to CIDR (e.g., 255.255.255.0 → 24)
        local cidr_bits=0
        local octet
        IFS='.' read -r -a octets <<< "$ipmi_netmask"
        for octet in "${octets[@]}"; do
            case "$octet" in
                255) cidr_bits=$((cidr_bits + 8)) ;;
                254) cidr_bits=$((cidr_bits + 7)) ;;
                252) cidr_bits=$((cidr_bits + 6)) ;;
                248) cidr_bits=$((cidr_bits + 5)) ;;
                240) cidr_bits=$((cidr_bits + 4)) ;;
                224) cidr_bits=$((cidr_bits + 3)) ;;
                192) cidr_bits=$((cidr_bits + 2)) ;;
                128) cidr_bits=$((cidr_bits + 1)) ;;
                0) ;;
                *) cidr_bits=0; break ;;  # Invalid netmask
            esac
        done
        
        if [[ "$cidr_bits" -gt 0 ]] && [[ "$cidr_bits" -le 32 ]]; then
            ipmi_cidr="$ipmi_ip/$cidr_bits"
        else
            _debug_print "Invalid netmask '$ipmi_netmask'"
        fi
    else
        _debug_print "No netmask detected for IPMI IP $ipmi_ip"
    fi

    # test console port on device
    if _has_ipmi_interface; then
        # Display information
        cat << EOF
  Interface: IPAM
  Type:      other
  MAC:       $ipmi_mac
  IPv4:      $ipmi_ip
  Netmask:   $ipmi_netmask
  CIDR:      $ipmi_cidr
  -------------------------
EOF

        # Create missing console ports
        _create_or_update_interface "$device_id" "IPMI" "$ipmi_mac" "other" "" "1500" "UP" "" ""
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
        if [[ -n "$ipmi_cidr" ]]; then
            echo "  IPv4 Address found: $ipmi_cidr"
            create_ip_address "$ipmi_cidr" "$(_get_interface_details "$device_id" | jq -r --arg name "IPMI" '.results[] | select(.name == $name) | .id // empty')"
        elif [[ -n "$ipmi_ip" ]]; then
            echo "  IPv4 Address found: $ipmi_ip"
            create_ip_address "$ipmi_ip" "$(_get_interface_details "$device_id" | jq -r --arg name "IPMI" '.results[] | select(.name == $name) | .id // empty')"
        else
            echo "  No IPv4 Address detected for IPMI"
        fi

    fi
}

#######################################################################################
# Neighbors
#######################################################################################

# Inside the loop in _get_lldp_neighbors(), after extracting data:
_create_lldp_cable_in_netbox() {
    local local_interface_name="$1"
    local remote_device_name="$2"
    local remote_interface_name="$3"
    local device_id="$4"

    # Get local interface ID
    local local_iface_id
    local_iface_id=$(_get_interface_details "$device_id" | jq -r --arg name "$local_interface_name" '.results[] | select(.name == $name) | .id // empty')
    if [[ -z "$local_iface_id" ]]; then
        _debug_print "Local interface $local_interface_name not found in NetBox"
        return 1
    fi

    # Get remote device ID
    local remote_device_id
    remote_device_id=$(_api_request "GET" "dcim/devices" "?name=$remote_device_name" "" | jq -r '.results[0].id // empty')
    if [[ -z "$remote_device_id" ]]; then
        _debug_print "Remote device $remote_device_name not found in NetBox"
        return 1
    fi

    # Get remote interface ID
    local remote_iface_id
    remote_iface_id=$(_get_interface_details "$remote_device_id" | jq -r --arg name "$remote_interface_name" '.results[] | select(.name == $name) | .id // empty')
    if [[ -z "$remote_iface_id" ]]; then
        _debug_print "Remote interface $remote_interface_name not found on device $remote_device_name"
        return 1
    fi

    # Check if cable already exists
    local existing_cable
    existing_cable=$(_api_request "GET" "dcim/cables" "?connected_endpoint_a_type=dcim.interface&connected_endpoint_a_id=$local_iface_id" "")
    if [[ "$(echo "$existing_cable" | jq -r '.count // 0')" -gt 0 ]]; then
        echo "  Cable already exists for $local_interface_name"
        return 0
    fi

    # Create cable
    if [[ "$DRY_RUN" == false ]]; then
        local cable_payload="{\"termination_a_type\":\"dcim.interface\",\"termination_a_id\":$local_iface_id,\"termination_b_type\":\"dcim.interface\",\"termination_b_id\":$remote_iface_id}"
        _api_request "POST" "dcim/cables" "" "$cable_payload" >/dev/null
        echo "  Created cable: $local_interface_name ↔ $remote_device_name:$remote_interface_name"
    else
        echo "  Cable would be created: $local_interface_name ↔ $remote_device_name:$remote_interface_name"
    fi
}

get_lldp_neighbors() {
    local device_id="$1"  # NetBox device ID (optional for now)

    echo ""
    echo "Detected LLDP neighbors:"

    if ! command -v lldpcli >/dev/null 2>&1; then
        echo "  Warning: lldpcli not found. Skipping LLDP neighbor discovery." >&2
        return 1
    fi

    local lldp_output
    lldp_output=$(lldpcli show neighbors details -f json 2>/dev/null)

    if [[ -z "$lldp_output" ]] || [[ "$lldp_output" == *"No such file or directory"* ]]; then
        echo "  No LLDP neighbors detected."
        return 0
    fi

    # Iterate over each element in the "interface" array
    local interface_count
    interface_count=$(echo "$lldp_output" | jq -r '.lldp.interface | length // 0')

    if [[ "$interface_count" -eq 0 ]]; then
        echo "    (none)"
        return 0
    fi

    for ((i = 0; i < interface_count; i++)); do
        # Extract interface name (the key inside the object at index i)
        local iface_obj
        iface_obj=$(echo "$lldp_output" | jq -r ".lldp.interface[$i]")

        # Get the interface name (e.g., "eno1")
        local interface_name
        interface_name=$(echo "$iface_obj" | jq -r 'keys[0]')

        if [[ -z "$interface_name" ]] || [[ "$interface_name" == "null" ]]; then
            continue
        fi

        # Extract data under that interface
        local chassis_name chassis_id port_id port_desc system_desc
        chassis_name=$(echo "$iface_obj" | jq -r ".\"$interface_name\".chassis | keys[0] // empty")
        chassis_id=$(echo "$iface_obj" | jq -r ".\"$interface_name\".chassis.\"$chassis_name\".id.value // empty")
        port_id=$(echo "$iface_obj" | jq -r ".\"$interface_name\".port.id.value // empty")
        port_desc=$(echo "$iface_obj" | jq -r ".\"$interface_name\".port.descr // empty")
        system_desc=$(echo "$iface_obj" | jq -r ".\"$interface_name\".chassis.\"$chassis_name\".descr // empty")

        cat << EOF
    Interface: $interface_name
      Chassis:     $chassis_name
      Port:        $port_id
      Port desc:   $port_desc
      MAC Address: $chassis_id
      System:      $system_desc

EOF
    done
}

#######################################################################################
# CPU
#######################################################################################

declare -a cpu_module_types=()
declare -a cpu_module_bays=()
declare -a cpu_modules=()

_gather_cpu_for_netbox() {
    local device_id="$1"
    cpu_module_types=()
    cpu_module_bays=()
    cpu_modules=()

    if ! command -v lshw >/dev/null 2>&1; then
        echo "Error: lshw not installed" >&2
        return 1
    fi

    local lshw_output
    lshw_output=$(lshw -quiet -json -class processor 2>/dev/null)
    if [[ -z "$lshw_output" ]]; then
        echo "Error: No CPU data from lshw" >&2
        return 1
    fi

    # Normalize to array
    if ! echo "$lshw_output" | jq -e '. | type == "array"' >/dev/null; then
        lshw_output="[$lshw_output]"
    fi

    local count i=0
    count=$(echo "$lshw_output" | jq 'length')
    while [[ $i -lt $count ]]; do
        local cpu
        cpu=$(echo "$lshw_output" | jq -c ".[$i]")
        local socket_designation manufacturer version core_count thread_count current_speed
        socket_designation=$(echo "$cpu" | jq -r '.slot // "CPU"')
        manufacturer=$(echo "$cpu" | jq -r '.vendor // "Unknown"')
        version=$(echo "$cpu" | jq -r '.product // empty')
        core_count=$(echo "$cpu" | jq -r '.configuration.cores // "0"')
        thread_count=$(echo "$cpu" | jq -r --arg cc "$core_count" '.configuration.threads // $cc')
        current_speed=$(echo "$cpu" | jq -r '.capacity // "0"')

        if [[ -n "$version" ]] && [[ "$version" != *"Not Specified"* ]] && [[ "$version" != *"Not Installed"* ]]; then
            _process_cpu_device "$device_id" "$socket_designation" "$manufacturer" "$version" "$core_count" "$thread_count" "$current_speed"
        fi
        ((i++))
    done
    return 0
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
    if [[ -n "$speed" ]] && [[ "$speed" =~ ^[0-9]+$ ]] && (( speed > 0 )); then
        # Convert Hz to GHz (e.g., 3800000000 → 3.80)
        clock_speed=$(echo "scale=2; $speed / 1000000000" | bc -l 2>/dev/null)
        # Remove trailing zeros and decimal point if whole number
        clock_speed=$(echo "$clock_speed" | sed 's/\.0*$//' | sed 's/0*$//')
        [[ -z "$clock_speed" ]] && clock_speed=0
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

    module_type_json+="\"attributes\":{"
    module_type_json+="\"cores\":$core_count,"
    module_type_json+="\"speed\":$clock_speed"
    # Architecture ???
    module_type_json+="},"

    module_type_json+="\"threads\":$thread_count,"
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
    _gather_cpu_for_netbox "$device_id"

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
                    echo "  Creating CPU Module in bay: $mod_bay_name"
                    _api_request "POST" "dcim/modules" "" "$fixed_mod_json" >/dev/null
                else
                    echo "  CPU Module already exists in bay: $mod_bay_name"
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

declare -a memory_module_types=()   # For ModuleType creation
declare -a memory_module_bays=()    # For ModuleBay creation  
declare -a memory_modules=()        # For Module creation

_gather_memory_for_netbox() {
    local device_id="$1"
    if ! command -v lshw >/dev/null 2>&1; then
        echo "Error: lshw not installed" >&2
        return 1
    fi

    local root_mem
    root_mem=$(lshw -quiet -json -class memory 2>/dev/null)
    if [[ -z "$root_mem" ]]; then
        echo "Error: No memory data" >&2
        return 1
    fi

    # Extract DIMM banks (top-level entries with id="bank:*" and non-empty)
    local dimms
    dimms=$(echo "$root_mem" | jq -c '
        .[] |
        select(.id | startswith("bank:")) |
        select(has("size"))
    ')

    if [[ -z "$dimms" ]]; then
        _debug_print "No DIMMs found"
        return 0
    fi

    while IFS= read -r mem; do
        local size=$(echo "$mem" | jq -r '.size // empty')
        [[ -z "$size" ]] && continue
        local size_gb=$((size / 1000000000))
        local manufacturer=$(echo "$mem" | jq -r '.vendor // "Unknown"')
        local part_number=$(echo "$mem" | jq -r '.product // "Unknown"')
        local serial=$(echo "$mem" | jq -r '.serial // "Unknown"')
        local locator=$(echo "$mem" | jq -r '.slot // "DIMM"')
        local bank_locator=$(echo "$mem" | jq -r '.physid // ""')
        local type=$(echo "$mem" | jq -r '.description // "DRAM"')
        local speed=$(echo "$mem" | jq -r '.clock // "0"')
        local speed_mts=$((speed / 1000000))

        _process_memory_device "$device_id" "${size_gb} GB" "$type" "${speed_mts} MT/s" "$manufacturer" "$part_number" "$serial" "$locator" "$bank_locator"
    done <<< "$dimms"

    _debug_print "Processed $(wc -l <<< "$dimms") DIMMs"
    _debug_print "Module types count: ${#memory_module_types[@]}"
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

    module_type_json+="\"attributes\":{"
    module_type_json+="\"class\":\"$mem_class\","
    module_type_json+="\"size\":$size_gb,"
    module_type_json+="\"data_rate\":$speed_mts,"
    module_type_json+="\"ecc\":$ecc"
    module_type_json+="}"

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
    echo ""
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
                echo "  ModuleBay already exists: $bay_name"
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
                    local fixed_mod_json
                    fixed_mod_json=$(echo "$mod_json" | jq --arg id "$bay_id" '.module_bay = ($id | tonumber)' 2>/dev/null)
                    echo "  Creating RAM Module in bay: $mod_bay_name"
                    _api_request "POST" "dcim/modules" "" "$fixed_mod_json" >/dev/null
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

declare -a disk_module_types=()
declare -a disk_module_bays=()
declare -a disk_modules=()

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

    # Get list of physical disk devices (type=disk only)
    local disks
    disks=$(lsblk -d -n -o NAME,TYPE 2>/dev/null | awk '$2 == "disk" {print $1}' | grep -E '^[a-z]+[0-9]*$')
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

        # Get SMART info
        local smart_info
        smart_info=$(smartctl -i "/dev/$name" 2>/dev/null)

        if [[ -z "$smart_info" ]] || [[ "$smart_info" == *"Read Device Identity failed"* ]] || [[ "$smart_info" == *"INQUIRY failed"* ]]; then
            _debug_print "WARNING: smartctl failed for /dev/$name – skipping"
            continue
        fi

        # --- Extract model ---
        local model
        model=$(echo "$smart_info" | grep -E '^(Device Model|Model Number):' | sed -E 's/^(Device Model|Model Number):[[:space:]]*//')
        [[ -z "$model" ]] && model="Unknown"
        model="${model//\"/\\\"}"

        if [[ "$model" == "Unknown" ]]; then
            _debug_print "Skipping disk with unknown model"
            continue
        fi

        # --- Extract serial ---
        local serial
        serial=$(echo "$smart_info" | grep "^Serial Number:" | sed 's/Serial Number:[[:space:]]*//')
        serial="${serial//\"/\\\"}"

        # --- Determine interface ---
        local interface="SAS"
        if [[ "$model" == *"SSD"* ]] || [[ "$model" == *"EVO"* ]] || [[ "$model" == *"NVMe"* ]] || [[ "$smart_info" == *"SATA"* ]]; then
            interface="SATA"
        fi

        # --- Determine RPM ---
        local rpm=7200
        if [[ "$model" == *"SSD"* ]] || [[ "$model" == *"NVMe"* ]]; then
            rpm=0
        else
            local rotation_line
            rotation_line=$(echo "$smart_info" | grep "^Rotation Rate:")
            if [[ -n "$rotation_line" ]]; then
                if [[ "$rotation_line" == *"solid state device"* ]] || [[ "$rotation_line" == *"Not reported"* ]]; then
                    rpm=0
                else
                    rpm=$(echo "$rotation_line" | grep -o '[0-9]\+' | head -1)
                    rpm=${rpm:-7200}
                fi
            fi
        fi

        # --- Get size in GB as INTEGER (using --bytes to avoid decimals) ---
        local size_gb=0
        local size_bytes
        size_bytes=$(lsblk -d -n -o SIZE --bytes "/dev/$name" 2>/dev/null | tr -d '[:space:]')
        _debug_print "Raw size in bytes: '$size_bytes'"

        if [[ -n "$size_bytes" ]] && [[ "$size_bytes" =~ ^[0-9]+$ ]] && (( size_bytes > 0 )); then
            # 1 GB = 1,000,000,000 bytes (decimal)
            size_gb=$(( (size_bytes + 999999999) / 1000000000 ))
        fi

        # Ensure non-negative integer
        size_gb=$(( size_gb < 0 ? 0 : size_gb ))

        # If device exists but size is 0, set to 1 GB minimum
        if [[ "$size_gb" -eq 0 ]] && [[ -n "$size_bytes" ]] && (( size_bytes > 0 )); then
            size_gb=1
        fi

        _debug_print "Final disk info: model='$model', size=$size_gb GB, interface=$interface, rpm=$rpm"

        # Process the disk
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
    local disk_type="HD"
    if [[ $rpm -eq 0 ]]; then
        disk_type="SSD"
    elif [[ "$interface" == "NVME" ]]; then
        disk_type="NVME"
    else
        disk_type="HD"
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

    module_type_json+="\"attributes\":{"
    module_type_json+="\"size\":$size_gb,"          # ← matches profile field "size"
    module_type_json+="\"speed\":$rpm,"            # ← matches profile field "speed"
    module_type_json+="\"type\":\"$disk_type\""    # ← matches profile field "type"
    module_type_json+="}"

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
    echo ""
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
## Controllers
#######################################################################################

# Global arrays for controllers
declare -a controller_module_types=()
declare -a controller_module_bays=()
declare -a controller_modules=()

_gather_controllers_for_netbox() {
    local device_id="$1"
    controller_module_types=()
    controller_module_bays=()
    controller_modules=()

    echo "Detecting Controllers..."
    if ! command -v lshw >/dev/null 2>&1; then
        echo "Error: Tool lshw is not available" >&2
        return 1
    fi

    local output
    output=$(lshw -quiet -json -class storage 2>/dev/null)
    if [[ -z "$output" ]]; then
        _debug_print "No controller info from lshw"
        return 0
    fi

    # Normalize to array if needed (though lshw -json always returns array)
    if ! echo "$output" | jq -e '. | type == "array"' >/dev/null; then
        output="[$output]"
    fi

    # Process each controller WITHOUT subshell
    while IFS= read -r ctrl; do
        [[ -z "$ctrl" ]] && continue
        local product vendor bus_info description
        product=$(echo "$ctrl" | jq -r '.product // empty')
        vendor=$(echo "$ctrl" | jq -r '.vendor // empty')
        bus_info=$(echo "$ctrl" | jq -r '.businfo // empty')
        description=$(echo "$ctrl" | jq -r '.description // empty')

        if [[ -n "$product" ]] && [[ -n "$vendor" ]] && [[ -n "$bus_info" ]]; then
            local pci_address
            pci_address=$(echo "$bus_info" | sed 's/.*pci@0000://; s/^[[:space:]]*//; s/[[:space:]]*$//')
            local ctrl_type="Controller"
            case "$description" in
                *RAID*) ctrl_type="RAID" ;;
                *SAS*)  ctrl_type="SAS" ;;
                *SATA*) ctrl_type="SATA" ;;
            esac

            local firmware=""
            if [[ "$ctrl_type" == "RAID" ]] && command -v megacli &> /dev/null; then
                firmware=$(sudo megacli -adpfwinfo -aALL 2>/dev/null | grep "FW Version" | head -1 | awk -F: '{print $2}' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
            fi

            _process_controller_device "$device_id" "$pci_address" "$product" "$vendor" "$ctrl_type" "$firmware"
        fi
    done < <(echo "$output" | jq -c '.[]')
    _debug_print "Detected ${#controller_module_types[@]} controller(s)"
}

_process_controller_device() {
    local device_id="$1" pci_address="$2" model="$3" manufacturer="$4" ctrl_type="$5" firmware="$6"

    # Clean up manufacturer name
    case "$manufacturer" in
        *"Broadcom"*|*"LSI"*) manufacturer="Broadcom" ;;
        *"Intel"*) manufacturer="Intel" ;;
        *"Marvell"*) manufacturer="Marvell" ;;
        *"AMD"*|*"ATI"*) manufacturer="AMD" ;;
        *) manufacturer="Unknown" ;;
    esac

    # Ensure manufacturer exists
    _ensure_manufacturer "$manufacturer"

    # Clean and truncate model name for NetBox limits
    local clean_model="$model"
    local truncated_model="${clean_model:0:100}"
    local truncated_part_number="${clean_model:0:50}"

    # Escape strings for JSON
    pci_address="${pci_address//\"/\\\"}"
    truncated_model="${truncated_model//\"/\\\"}"
    truncated_part_number="${truncated_part_number//\"/\\\"}"
    manufacturer="${manufacturer//\"/\\\"}"
    ctrl_type="${ctrl_type//\"/\\\"}"
    firmware="${firmware//\"/\\\"}"

    # Set default values
    local ports=8
    local interface_speed="12Gbps"
    if [[ "$ctrl_type" == "NVMe" ]]; then
        interface_speed="PCIe"
    fi

    # 1. MODULE TYPE (controller template) - Profile ID 7
    local module_type_json="{"
    module_type_json+="\"profile\":7,"
    module_type_json+="\"manufacturer\":{\"name\":\"$manufacturer\"},"
    module_type_json+="\"model\":\"$truncated_model\","
    module_type_json+="\"part_number\":\"$truncated_part_number\","
    module_type_json+="\"controller_type\":\"$ctrl_type\","
    module_type_json+="\"firmware_version\":\"$firmware\","
    module_type_json+="\"ports\":$ports,"
    module_type_json+="\"interface_speed\":\"$interface_speed\""
    module_type_json+="}"
    controller_module_types+=("$module_type_json")

    # 2. MODULE BAY (PCIe slot)
    local bay_name="PCIe-$pci_address"
    local bay_json="{\"device\":$device_id,\"name\":\"$bay_name\",\"description\":\"Controller Slot $pci_address\",\"label\":\"Controller\"}"
    controller_module_bays+=("$bay_json")

    # 3. MODULE (installed controller instance)
    local module_json="{\"device\":$device_id,\"module_bay\":{\"name\":\"$bay_name\"},\"module_type\":{\"manufacturer\":{\"name\":\"$manufacturer\"},\"model\":\"$truncated_model\"}}"
    controller_modules+=("$module_json")
}

_create_controller_module_in_netbox() {
    local device_id="$1"
    echo ""
    echo "Detecting Controller Items..."
    _gather_controllers_for_netbox "$device_id" || return 1

    echo "Creating controller modules in NetBox for device ID: $device_id"

    # 1. Create ModuleTypes (deduplicated)
    declare -A controller_module_type_map
    for mt_json in "${controller_module_types[@]}"; do
        local manuf=$(echo "$mt_json" | jq -r '.manufacturer.name // empty')
        local model=$(echo "$mt_json" | jq -r '.model // empty')
        if [[ -z "$manuf" ]] || [[ -z "$model" ]]; then
            _debug_print "Skipping empty Controller ModuleType"
            continue
        fi
        
        local key="${manuf}_${model}"
        if [[ -z "${controller_module_type_map[$key]:-}" ]]; then
            local encoded_manuf encoded_model
            encoded_manuf=$(printf '%s' "$manuf" | jq -sRr 'split("\n") | .[0] | @uri')
            encoded_model=$(printf '%s' "$model" | jq -sRr 'split("\n") | .[0] | @uri')
            local exists_resp
            exists_resp=$(_api_request "GET" "dcim/module-types" "?manufacturer=$encoded_manuf&model=$encoded_model" "")
            local count
            count=$(echo "$exists_resp" | jq -r '.count // 0')
            if [[ "$count" -eq 0 ]]; then
                _debug_print "Creating Controller ModuleType: $manuf / $model"
                _api_request "POST" "dcim/module-types" "" "$mt_json" >/dev/null
            else
                _debug_print "Controller ModuleType already exists: $manuf / $model"
            fi
            controller_module_type_map["$key"]=1
        fi
    done

    # 2. Create ModuleBays AND store IDs
    declare -A controller_module_bay_id_map
    for bay_json in "${controller_module_bays[@]}"; do
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
                echo "Creating Controller ModuleBay: $bay_name"
                local bay_resp
                bay_resp=$(_api_request "POST" "dcim/module-bays" "" "$bay_json")
                local bay_id
                bay_id=$(echo "$bay_resp" | jq -r '.id // empty' 2>/dev/null)
                if [[ -n "$bay_id" ]]; then
                    controller_module_bay_id_map["$bay_name"]="$bay_id"
                    _debug_print "Created Controller ModuleBay $bay_name with ID: $bay_id"
                else
                    _debug_print "ERROR: Failed to get ID for new Controller ModuleBay: $bay_name"
                fi
            else
                echo "Controller ModuleBay already exists: $bay_name"
                local bay_id
                bay_id=$(echo "$bay_exists" | jq -r '.results[0].id // empty')
                if [[ -n "$bay_id" ]]; then
                    controller_module_bay_id_map["$bay_name"]="$bay_id"
                    _debug_print "Existing Controller ModuleBay $bay_name has ID: $bay_id"
                else
                    _debug_print "ERROR: Failed to get ID for existing Controller ModuleBay: $bay_name"
                fi
            fi
        fi
    done

    # 3. Create Modules using ModuleBay IDs
    for mod_json in "${controller_modules[@]}"; do
        local mod_bay_name
        mod_bay_name=$(echo "$mod_json" | jq -r '.module_bay.name // empty')
        if [[ -n "$mod_bay_name" ]]; then
            if [[ -n "${controller_module_bay_id_map[$mod_bay_name]:-}" ]]; then
                local bay_id="${controller_module_bay_id_map[$mod_bay_name]}"
                local mod_exists
                mod_exists=$(_api_request "GET" "dcim/modules" "?device_id=$device_id&module_bay_id=$bay_id" "")
                local mod_count
                mod_count=$(echo "$mod_exists" | jq -r '.count // 0')
                
                if [[ "$mod_count" -eq 0 ]]; then
                    local manuf=$(echo "$mod_json" | jq -r '.module_type.manufacturer.name // empty')
                    local model=$(echo "$mod_json" | jq -r '.module_type.model // empty')
                    local fixed_mod_json="{\"device\":$device_id,\"module_bay\":$bay_id,\"module_type\":{\"manufacturer\":{\"name\":\"$manuf\"},\"model\":\"$model\"}}"
                    echo "Creating Controller Module in bay: $mod_bay_name"
                    _api_request "POST" "dcim/modules" "" "$fixed_mod_json" >/dev/null
                else
                    echo "Controller Module already exists in bay: $mod_bay_name"
                fi
            else
                _debug_print "ERROR: No Controller ModuleBay ID found for: $mod_bay_name"
            fi
        fi
    done

    echo "Controller module sync completed."
}

#######################################################################################
# GPU
#######################################################################################

# Global arrays for GPU
declare -a gpu_module_types=()
declare -a gpu_module_bays=()
declare -a gpu_modules=()

_gather_gpus_for_netbox() {
    local device_id="$1"
    gpu_module_types=()
    gpu_module_bays=()
    gpu_modules=()

    echo "Detecting GPUs..."
    if ! command -v lshw >/dev/null 2>&1; then
        echo "Error: Tool lshw is not available" >&2
        return 1
    fi

    local output
    output=$(lshw -quiet -json -class display 2>/dev/null)
    if [[ -z "$output" ]]; then
        _debug_print "No GPU info from lshw"
        return 0
    fi

    if ! echo "$output" | jq -e '. | type == "array"' >/dev/null; then
        output="[$output]"
    fi

    echo "$output" | jq -c '.[]' | while read -r gpu; do
        local product vendor bus_info
        product=$(echo "$gpu" | jq -r '.product // empty')
        vendor=$(echo "$gpu" | jq -r '.vendor // empty')
        bus_info=$(echo "$gpu" | jq -r '.businfo // empty')

        if [[ -n "$product" ]] && [[ -n "$vendor" ]] && [[ -n "$bus_info" ]]; then
            local pci_address
            pci_address=$(echo "$bus_info" | sed 's/.*@0000://; s/^[[:space:]]*//; s/[[:space:]]*$//')
            _process_gpu_device "$device_id" "$pci_address" "$product" "$vendor" "0"
        fi
    done
}

_process_gpu_device() {
    local device_id="$1" pci_address="$2" model="$3" manufacturer="$4" memory_size="$5"

    # Clean up manufacturer name
    case "$manufacturer" in
        *"Matrox"*) manufacturer="Matrox" ;;
        *"NVIDIA"*) manufacturer="NVIDIA" ;;
        *"AMD"*|*"ATI"*|*"Advanced Micro"*) manufacturer="AMD" ;;
        *"Intel"*) manufacturer="Intel" ;;
        *"ASPEED"*) manufacturer="ASPEED" ;;
        *) manufacturer="Unknown" ;;
    esac

    # Ensure manufacturer exists
    _ensure_manufacturer "$manufacturer"

    # Clean and truncate model name for NetBox limits
    local clean_model="$model"
    local truncated_model="${clean_model:0:100}"
    local truncated_part_number="${clean_model:0:50}"

    # Escape strings for JSON
    pci_address="${pci_address//\"/\\\"}"
    truncated_model="${truncated_model//\"/\\\"}"
    truncated_part_number="${truncated_part_number//\"/\\\"}"
    manufacturer="${manufacturer//\"/\\\"}"

    # Determine GPU type
    local gpu_type="Discrete"
    if [[ "$manufacturer" == "Intel" ]] || [[ "$manufacturer" == "ASPEED" ]]; then
        gpu_type="Integrated"
    fi

    # 1. MODULE TYPE (GPU template) - Profile ID 3
    local module_type_json="{"
    module_type_json+="\"profile\":3,"
    module_type_json+="\"manufacturer\":{\"name\":\"$manufacturer\"},"
    module_type_json+="\"model\":\"$truncated_model\","
    module_type_json+="\"part_number\":\"$truncated_part_number\","

    module_type_json+="\"attributes\":{"
    module_type_json+="\"memory\":$memory_size,"
    module_type_json+="\"gpu\":\"$gpu_type\""
    module_type_json+="}"

    module_type_json+="}"
    gpu_module_types+=("$module_type_json")

    # 2. MODULE BAY (PCIe slot)
    local bay_name="PCIe-$pci_address"
    local bay_json="{\"device\":$device_id,\"name\":\"$bay_name\",\"description\":\"GPU Slot $pci_address\",\"label\":\"GPU\"}"
    gpu_module_bays+=("$bay_json")

    # 3. MODULE (installed GPU instance)
    local module_json="{\"device\":$device_id,\"module_bay\":{\"name\":\"$bay_name\"},\"module_type\":{\"manufacturer\":{\"name\":\"$manufacturer\"},\"model\":\"$truncated_model\"}}"
    gpu_modules+=("$module_json")
}

_create_gpu_module_in_netbox() {
    local device_id="$1"
    echo ""
    echo "Detecting GPU Items..."
    _gather_gpus_for_netbox "$device_id" || return 1

    echo "Creating GPU modules in NetBox for device ID: $device_id"

    # 1. Create ModuleTypes (deduplicated)
    declare -A gpu_module_type_map
    for mt_json in "${gpu_module_types[@]}"; do
        local manuf=$(echo "$mt_json" | jq -r '.manufacturer.name // empty')
        local model=$(echo "$mt_json" | jq -r '.model // empty')
        if [[ -z "$manuf" ]] || [[ -z "$model" ]]; then
            _debug_print "Skipping empty GPU ModuleType"
            continue
        fi
        
        local key="${manuf}_${model}"
        if [[ -z "${gpu_module_type_map[$key]:-}" ]]; then
            local encoded_manuf encoded_model
            encoded_manuf=$(printf '%s' "$manuf" | jq -sRr 'split("\n") | .[0] | @uri')
            encoded_model=$(printf '%s' "$model" | jq -sRr 'split("\n") | .[0] | @uri')
            local exists_resp
            exists_resp=$(_api_request "GET" "dcim/module-types" "?manufacturer=$encoded_manuf&model=$encoded_model" "")
            local count
            count=$(echo "$exists_resp" | jq -r '.count // 0')
            if [[ "$count" -eq 0 ]]; then
                _debug_print "Creating GPU ModuleType: $manuf / $model"
                _api_request "POST" "dcim/module-types" "" "$mt_json" >/dev/null
            else
                _debug_print "GPU ModuleType already exists: $manuf / $model"
            fi
            gpu_module_type_map["$key"]=1
        fi
    done

    # 2. Create ModuleBays AND store IDs
    declare -A gpu_module_bay_id_map
    for bay_json in "${gpu_module_bays[@]}"; do
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
                echo "Creating GPU ModuleBay: $bay_name"
                local bay_resp
                bay_resp=$(_api_request "POST" "dcim/module-bays" "" "$bay_json")
                local bay_id
                bay_id=$(echo "$bay_resp" | jq -r '.id // empty' 2>/dev/null)
                if [[ -n "$bay_id" ]]; then
                    gpu_module_bay_id_map["$bay_name"]="$bay_id"
                    _debug_print "Created GPU ModuleBay $bay_name with ID: $bay_id"
                else
                    _debug_print "ERROR: Failed to get ID for new GPU ModuleBay: $bay_name"
                fi
            else
                echo "GPU ModuleBay already exists: $bay_name"
                local bay_id
                bay_id=$(echo "$bay_exists" | jq -r '.results[0].id // empty')
                if [[ -n "$bay_id" ]]; then
                    gpu_module_bay_id_map["$bay_name"]="$bay_id"
                    _debug_print "Existing GPU ModuleBay $bay_name has ID: $bay_id"
                else
                    _debug_print "ERROR: Failed to get ID for existing GPU ModuleBay: $bay_name"
                fi
            fi
        fi
    done

    # 3. Create Modules using ModuleBay IDs
    for mod_json in "${gpu_modules[@]}"; do
        local mod_bay_name
        mod_bay_name=$(echo "$mod_json" | jq -r '.module_bay.name // empty')
        if [[ -n "$mod_bay_name" ]]; then
            if [[ -n "${gpu_module_bay_id_map[$mod_bay_name]:-}" ]]; then
                local bay_id="${gpu_module_bay_id_map[$mod_bay_name]}"
                local mod_exists
                mod_exists=$(_api_request "GET" "dcim/modules" "?device_id=$device_id&module_bay_id=$bay_id" "")
                local mod_count
                mod_count=$(echo "$mod_exists" | jq -r '.count // 0')
                
                if [[ "$mod_count" -eq 0 ]]; then
                    local manuf=$(echo "$mod_json" | jq -r '.module_type.manufacturer.name // empty')
                    local model=$(echo "$mod_json" | jq -r '.module_type.model // empty')
                    local fixed_mod_json="{\"device\":$device_id,\"module_bay\":$bay_id,\"module_type\":{\"manufacturer\":{\"name\":\"$manuf\"},\"model\":\"$model\"}}"
                    echo "Creating GPU Module in bay: $mod_bay_name"
                    _api_request "POST" "dcim/modules" "" "$fixed_mod_json" >/dev/null
                else
                    echo "GPU Module already exists in bay: $mod_bay_name"
                fi
            else
                _debug_print "ERROR: No GPU ModuleBay ID found for: $mod_bay_name"
            fi
        fi
    done

    echo "GPU module sync completed."
}

#######################################################################################
# Network Cards
#######################################################################################

# Global arrays for network interfaces
declare -a nic_module_types=()
declare -a nic_module_bays=()
declare -a nic_modules=()

_gather_nics_for_netbox() {
    local device_id="$1"
    nic_module_types=()
    nic_module_bays=()
    nic_modules=()

    echo "Detecting Network Interfaces..."
    if ! command -v lshw >/dev/null 2>&1; then
        _debug_print "lshw not available – skipping NIC detection"
        return 0
    fi

    local output
    output=$(lshw -quiet -json -class network 2>/dev/null)
    if [[ -z "$output" ]]; then
        _debug_print "No NIC info from lshw"
        return 0
    fi

    # Handle array or single object
    if ! echo "$output" | jq -e '. | type == "array"' >/dev/null; then
        output="[$output]"
    fi

    echo "$output" | jq -c '.[]' | while read -r nic; do
        local product vendor bus_info serial
        product=$(echo "$nic" | jq -r '.product // empty')
        vendor=$(echo "$nic" | jq -r '.vendor // empty')
        bus_info=$(echo "$nic" | jq -r '.businfo // empty')
        serial=$(echo "$nic" | jq -r '.serial // empty')

        if [[ -n "$product" ]] && [[ -n "$vendor" ]] && [[ -n "$bus_info" ]] && [[ -n "$serial" ]]; then
            local pci_address
            pci_address=$(echo "$bus_info" | sed 's/.*@0000://; s/^[[:space:]]*//; s/[[:space:]]*$//')
            local nic_type="Ethernet"
            if [[ "$product" == *"Infiniband"* ]] || [[ "$product" == *"ConnectX"* ]]; then
                nic_type="Infiniband"
            elif [[ "$product" == *"Wireless"* ]] || [[ "$product" == *"Wi-Fi"* ]]; then
                nic_type="Wireless"
            fi
            _process_nic_device "$device_id" "$pci_address" "$product" "$vendor" "$serial" "$nic_type"
        fi
    done
}

_process_nic_device() {
    local device_id="$1" pci_address="$2" model="$3" manufacturer="$4" mac_address="$5" interface_type="$6"

    # Clean up manufacturer name
    case "$manufacturer" in
        *"Intel"*) manufacturer="Intel" ;;
        *"Broadcom"*|*"NetXtreme"*) manufacturer="Broadcom" ;;
        *"Mellanox"*|*"ConnectX"*) manufacturer="Mellanox" ;;
        *"Chelsio"*) manufacturer="Chelsio" ;;
        *"Realtek"*) manufacturer="Realtek" ;;
        *"AMD"*|*"ATI"*) manufacturer="AMD" ;;
        *) manufacturer="Unknown" ;;
    esac

    # Ensure manufacturer exists
    _ensure_manufacturer "$manufacturer"

    # Clean and truncate model name for NetBox limits
    local clean_model="$model"
    local truncated_model="${clean_model:0:100}"
    local truncated_part_number="${clean_model:0:50}"

    # Escape strings for JSON
    pci_address="${pci_address//\"/\\\"}"
    truncated_model="${truncated_model//\"/\\\"}"
    truncated_part_number="${truncated_part_number//\"/\\\"}"
    manufacturer="${manufacturer//\"/\\\"}"
    mac_address="${mac_address//\"/\\\"}"
    interface_type="${interface_type//\"/\\\"}"

    # 1. MODULE TYPE (Expansion card) - Profile ID 7
    local module_type_json="{"
    module_type_json+="\"profile\":7,"
    module_type_json+="\"manufacturer\":{\"name\":\"$manufacturer\"},"
    module_type_json+="\"model\":\"$truncated_model\","
    module_type_json+="\"part_number\":\"$truncated_part_number\","
    module_type_json+="\"interface_type\":\"$interface_type\""
    module_type_json+="}"
    nic_module_types+=("$module_type_json")

    # 2. MODULE BAY (PCIe slot)
    local bay_name="PCIe-$pci_address"
    local bay_json="{\"device\":$device_id,\"name\":\"$bay_name\",\"description\":\"Network Interface $pci_address\",\"label\":\"NIC\"}"
    nic_module_bays+=("$bay_json")

    # 3. MODULE (installed NIC instance) - MAC as serial
    local module_json="{\"device\":$device_id,\"module_bay\":{\"name\":\"$bay_name\"},\"module_type\":{\"manufacturer\":{\"name\":\"$manufacturer\"},\"model\":\"$truncated_model\"},\"serial\":\"$mac_address\"}"
    nic_modules+=("$module_json")
}

_create_nic_module_in_netbox() {
    local device_id="$1"
    echo ""
    echo "Detecting NIC Items..."
    _gather_nics_for_netbox "$device_id" || return 1

    echo "Creating NIC modules in NetBox for device ID: $device_id"

    # 1. Create ModuleTypes (deduplicated)
    declare -A nic_module_type_map
    for mt_json in "${nic_module_types[@]}"; do
        local manuf=$(echo "$mt_json" | jq -r '.manufacturer.name // empty')
        local model=$(echo "$mt_json" | jq -r '.model // empty')
        if [[ -z "$manuf" ]] || [[ -z "$model" ]]; then
            _debug_print "Skipping empty NIC ModuleType"
            continue
        fi
        
        local key="${manuf}_${model}"
        if [[ -z "${nic_module_type_map[$key]:-}" ]]; then
            local encoded_manuf encoded_model
            encoded_manuf=$(printf '%s' "$manuf" | jq -sRr 'split("\n") | .[0] | @uri')
            encoded_model=$(printf '%s' "$model" | jq -sRr 'split("\n") | .[0] | @uri')
            local exists_resp
            exists_resp=$(_api_request "GET" "dcim/module-types" "?manufacturer=$encoded_manuf&model=$encoded_model" "")
            local count
            count=$(echo "$exists_resp" | jq -r '.count // 0')
            if [[ "$count" -eq 0 ]]; then
                _debug_print "Creating NIC ModuleType: $manuf / $model"
                _api_request "POST" "dcim/module-types" "" "$mt_json" >/dev/null
            else
                _debug_print "NIC ModuleType already exists: $manuf / $model"
            fi
            nic_module_type_map["$key"]=1
        fi
    done

    # 2. Create ModuleBays AND store IDs
    declare -A nic_module_bay_id_map
    for bay_json in "${nic_module_bays[@]}"; do
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
                echo "Creating NIC ModuleBay: $bay_name"
                local bay_resp
                bay_resp=$(_api_request "POST" "dcim/module-bays" "" "$bay_json")
                local bay_id
                bay_id=$(echo "$bay_resp" | jq -r '.id // empty' 2>/dev/null)
                if [[ -n "$bay_id" ]]; then
                    nic_module_bay_id_map["$bay_name"]="$bay_id"
                    _debug_print "Created NIC ModuleBay $bay_name with ID: $bay_id"
                else
                    _debug_print "ERROR: Failed to get ID for new NIC ModuleBay: $bay_name"
                fi
            else
                echo "NIC ModuleBay already exists: $bay_name"
                local bay_id
                bay_id=$(echo "$bay_exists" | jq -r '.results[0].id // empty')
                if [[ -n "$bay_id" ]]; then
                    nic_module_bay_id_map["$bay_name"]="$bay_id"
                    _debug_print "Existing NIC ModuleBay $bay_name has ID: $bay_id"
                else
                    _debug_print "ERROR: Failed to get ID for existing NIC ModuleBay: $bay_name"
                fi
            fi
        fi
    done

    # 3. Create Modules using ModuleBay IDs
for mod_json in "${nic_modules[@]}"; do
    local mod_bay_name
    mod_bay_name=$(echo "$mod_json" | jq -r '.module_bay.name // empty')
    if [[ -n "$mod_bay_name" ]]; then
        if [[ -n "${nic_module_bay_id_map[$mod_bay_name]:-}" ]]; then
            local bay_id="${nic_module_bay_id_map[$mod_bay_name]}"
            local mod_exists
            mod_exists=$(_api_request "GET" "dcim/modules" "?device_id=$device_id&module_bay_id=$bay_id" "")
            local mod_count
            mod_count=$(echo "$mod_exists" | jq -r '.count // 0')
            # Extract MAC address (stored as 'serial' in NIC module)
            local mac_address
            mac_address=$(echo "$mod_json" | jq -r '.serial // empty')
            if [[ -z "$mac_address" ]]; then
                _debug_print "WARNING: No MAC address (serial) found for NIC module in bay $mod_bay_name"
                continue
            fi
            if [[ "$mod_count" -eq 0 ]]; then
                local manuf=$(echo "$mod_json" | jq -r '.module_type.manufacturer.name // empty')
                local model=$(echo "$mod_json" | jq -r '.module_type.model // empty')
                local serial=$(echo "$mod_json" | jq -r '.serial // empty')
                local fixed_mod_json="{\"device\":$device_id,\"module_bay\":$bay_id,\"module_type\":{\"manufacturer\":{\"name\":\"$manuf\"},\"model\":\"$model\"},\"serial\":\"$serial\"}"
                echo "Creating NIC Module in bay: $mod_bay_name"
                local create_resp
                create_resp=$(_api_request "POST" "dcim/modules" "" "$fixed_mod_json")
            else
                echo "NIC Module already exists in bay: $mod_bay_name"
            fi
        else
            _debug_print "ERROR: No NIC ModuleBay ID found for: $mod_bay_name"
        fi
    fi
done

    echo "NIC module sync completed."
}

#######################################################################################
# PSU
#######################################################################################

declare -a psu_module_types=()
declare -a psu_module_bays=()
declare -a psu_modules=()
declare -a psu_power_ports=()

_gather_psus_for_netbox() {
    local device_id="$1"
    psu_module_types=()
    psu_module_bays=()
    psu_modules=()
    psu_power_ports=()

    echo "Detecting PSUs via lshw..."
    if ! command -v lshw >/dev/null 2>&1; then
        _debug_print "lshw not available – skipping PSU detection"
        return 0
    fi

    local lshw_output
    lshw_output=$(lshw -quiet -json -class power 2>/dev/null)
    if [[ -z "$lshw_output" ]]; then
        _debug_print "No PSU data from lshw"
        return 0
    fi

    echo "PSU Detected:"
    local psu_json_array
    psu_json_array=$(echo "$lshw_output" | jq -c 'if type == "array" then . else [.] end' 2>/dev/null || echo "[]")
    
    local index=1
    local psu_count
    psu_count=$(echo "$psu_json_array" | jq -r 'length')
    
    # Process each PSU entry
    for ((i=0; i<psu_count; i++)); do
        local psu_entry
        psu_entry=$(echo "$psu_json_array" | jq -c ".[$i]")
        
        # Skip if no essential fields (optional safety)
        local vendor product
        vendor=$(echo "$psu_entry" | jq -r '.vendor // empty')
        product=$(echo "$psu_entry" | jq -r '.product // empty')
        if [[ -z "$vendor" ]] || [[ -z "$product" ]]; then
            continue
        fi

        local location slot physid
        slot=$(echo "$psu_entry" | jq -r '.slot // "PSU"')
        physid=$(echo "$psu_entry" | jq -r '.physid')
        location="$slot-$physid"
        echo "  Slot: $location"
        
        local manufacturer="$vendor"
        echo "  Manufacturer: $manufacturer"
        
        local model="$product"
        echo "  Model: $model"
        
        local serial
        serial=$(echo "$psu_entry" | jq -r '.serial // "Undetected"')
        echo "  Serial: $serial"
        
        local wattage
        wattage=$(echo "$psu_entry" | jq -r '.capacity // "1"')
        wattage=${wattage//[!0-9]/}
        wattage=${wattage:-1}
        # Note: lshw reports capacity in mWh, but for PSU it's likely a mislabel — treat as watts
        echo "  Wattage: $wattage W"
        echo "  ------------------------------"

        _process_psu_device "$device_id" "$index" "$location" "$manufacturer" "$model" "$serial" "${wattage} W" "false"
        ((index++))
    done

    if [[ $index -eq 1 ]]; then
        echo "  No PSUs detected via lshw"
    fi
}

_process_psu_device() {
    local device_id="$1" index="$2" location="$3" manufacturer="$4" model="$5" serial="$6" max_power_raw="$7" hot_swappable="$8"

    # Skip empty or placeholder entries
    if [[ "$manufacturer" == "To Be Filled By O.E.M." ]] || [[ -z "$manufacturer" ]] || [[ "$manufacturer" == "Not Specified" ]]; then
        manufacturer="Generic"
    fi

    if [[ "$model" == "To Be Filled By O.E.M." ]] || [[ -z "$model" ]] || [[ "$model" == "Not Specified" ]]; then
        model="PSU (Undetected)"
    fi

    if [[ "$serial" == "To Be Filled By O.E.M." ]] || [[ -z "$serial" ]] || [[ "$serial" == "Not Specified" ]]; then
        serial="Undetected"
    fi

    # Normalize location or use index
    local bay_name="PSU$index"
    [[ -n "$location" ]] && [[ "$location" != "Not Specified" ]] && bay_name="$location"

    # Ensure manufacturer exists
    _ensure_manufacturer "$manufacturer" || return 1
    manufacturer="$_CANONICAL_MANUFACTURER"

    # Parse max power (e.g., "800 W" → 800)
    local wattage=1
    if [[ -n "$max_power_raw" ]]; then
        wattage=$(echo "$max_power_raw" | sed 's/[^0-9]*//g')
        [[ -z "$wattage" ]] && wattage=1
    fi

    # Default hot-swappable to false if not detected
    [[ -z "$hot_swappable" ]] && hot_swappable="false"

    # === Infer input_current and input_voltage ===
    # dmidecode rarely provides these, so use safe defaults
    local input_current="AC"
    local input_voltage=120

    # Optional: enhance with IPMI later if needed (e.g., via `ipmitool sensor list | grep -i voltage`)

    # Escape strings for JSON
    manufacturer="${manufacturer//\"/\\\"}"
    model="${model//\"/\\\"}"
    serial="${serial//\"/\\\"}"
    bay_name="${bay_name//\"/\\\"}"

    # Use a generic model if empty
    local psu_model="$model"
    [[ -z "$psu_model" ]] && psu_model="PSU-$index"

    # === 1. MODULE TYPE (Power Supply profile – ID 6) ===
    local module_type_json="{"
    module_type_json+="\"profile\":6,"
    module_type_json+="\"manufacturer\":{\"name\":\"$manufacturer\"},"
    module_type_json+="\"model\":\"$psu_model\","
    module_type_json+="\"part_number\":\"$psu_model\","
    module_type_json+="\"attributes\":{"
    module_type_json+="\"wattage\":$wattage,"
    module_type_json+="\"hot_swappable\":$hot_swappable,"
    module_type_json+="\"input_current\":\"$input_current\","
    module_type_json+="\"input_voltage\":$input_voltage"
    module_type_json+="}"
    module_type_json+="}"
    psu_module_types+=("$module_type_json")

    # === 2. MODULE BAY ===
    local bay_json="{\"device\":$device_id,\"name\":\"$bay_name\",\"description\":\"Power Supply Bay\",\"label\":\"PSU\"}"
    psu_module_bays+=("$bay_json")

    # === 3. MODULE (installed PSU) ===
    local module_json="{\"device\":$device_id,\"module_bay\":{\"name\":\"$bay_name\"},\"module_type\":{\"manufacturer\":{\"name\":\"$manufacturer\"},\"model\":\"$psu_model\"}"
    [[ -n "$serial" ]] && module_json+=",\"serial\":\"$serial\""
    module_json+="}"
    psu_modules+=("$module_json")

    # === 4. POWER PORT (for cabling) ===
    local power_port_name="${bay_name}_IN"
    local power_port_json="{"
    power_port_json+="\"device\":$device_id,"
    power_port_json+="\"name\":\"$power_port_name\","
    power_port_json+="\"type\":\"iec-60320-c14\","
    power_port_json+="\"maximum_draw\":$wattage"
    power_port_json+="}"
    psu_power_ports+=("$power_port_json")
}


_create_psu_modules_in_netbox() {
    local device_id="$1"
    echo ""
    echo "Creating PSU Modules and Power Ports in NetBox..."

    _gather_psus_for_netbox "$device_id" || return 0

    # === 1. Create ModuleTypes (deduplicated) ===
    declare -A psu_module_type_map
    for mt_json in "${psu_module_types[@]}"; do
        local manuf=$(echo "$mt_json" | jq -r '.manufacturer.name // empty')
        local model=$(echo "$mt_json" | jq -r '.model // empty')
        if [[ -n "$manuf" ]] && [[ -n "$model" ]]; then
            local key="${manuf}_${model}"
            if [[ -z "${psu_module_type_map[$key]:-}" ]]; then
                local encoded_manuf=$(printf '%s' "$manuf" | jq -sRr 'split("\n") | .[0] | @uri')
                local encoded_model=$(printf '%s' "$model" | jq -sRr 'split("\n") | .[0] | @uri')
                local exists_resp=$(_api_request "GET" "dcim/module-types" "?manufacturer=$encoded_manuf&model=$encoded_model" "")
                local count=$(echo "$exists_resp" | jq -r '.count // 0')
                if [[ "$count" -eq 0 ]]; then
                    _debug_print "Creating PSU ModuleType: $manuf / $model"
                    _api_request "POST" "dcim/module-types" "" "$mt_json" >/dev/null
                else
                    _debug_print "PSU ModuleType exists: $manuf / $model"
                fi
                psu_module_type_map["$key"]=1
            fi
        fi
    done

    # === 2. Create ModuleBays + store IDs ===
    declare -A psu_module_bay_id_map
    for bay_json in "${psu_module_bays[@]}"; do
        local bay_name=$(echo "$bay_json" | jq -r '.name // empty')
        if [[ -n "$bay_name" ]]; then
            local encoded_bay_name=$(printf '%s' "$bay_name" | jq -sRr 'split("\n") | .[0] | @uri')
            local bay_exists=$(_api_request "GET" "dcim/module-bays" "?device_id=$device_id&name=$encoded_bay_name" "")
            local bay_count=$(echo "$bay_exists" | jq -r '.count // 0')
            if [[ "$bay_count" -eq 0 ]]; then
                echo "  Creating PSU ModuleBay: $bay_name"
                local bay_resp=$(_api_request "POST" "dcim/module-bays" "" "$bay_json")
                local bay_id=$(echo "$bay_resp" | jq -r '.id // empty')
                if [[ -n "$bay_id" ]]; then
                    psu_module_bay_id_map["$bay_name"]="$bay_id"
                fi
            else
                local bay_id=$(echo "$bay_exists" | jq -r '.results[0].id // empty')
                psu_module_bay_id_map["$bay_name"]="$bay_id"
            fi
        fi
    done

    # === 3. Create Modules ===
    for mod_json in "${psu_modules[@]}"; do
        local mod_bay_name=$(echo "$mod_json" | jq -r '.module_bay.name // empty')
        if [[ -n "$mod_bay_name" ]] && [[ -n "${psu_module_bay_id_map[$mod_bay_name]:-}" ]]; then
            local bay_id="${psu_module_bay_id_map[$mod_bay_name]}"
            local mod_exists=$(_api_request "GET" "dcim/modules" "?device_id=$device_id&module_bay_id=$bay_id" "")
            local mod_count=$(echo "$mod_exists" | jq -r '.count // 0')
            if [[ "$mod_count" -eq 0 ]]; then
                local fixed_mod_json=$(echo "$mod_json" | jq --arg id "$bay_id" '.module_bay = ($id | tonumber)')
                echo "  Creating PSU Module in bay: $mod_bay_name"
                _api_request "POST" "dcim/modules" "" "$fixed_mod_json" >/dev/null
            else
                echo "  PSU Module already exists in bay: $mod_bay_name"
            fi
        fi
    done

    # === 4. Create Power Ports ===
    for pp_json in "${psu_power_ports[@]}"; do
        local pp_name=$(echo "$pp_json" | jq -r '.name // empty')
        if [[ -n "$pp_name" ]]; then
            local pp_exists=$(_api_request "GET" "dcim/power-ports" "?device_id=$device_id&name=$pp_name" "")
            local pp_count=$(echo "$pp_exists" | jq -r '.count // 0')
            if [[ "$pp_count" -eq 0 ]]; then
                echo "  Creating Power Port: $pp_name"
                _api_request "POST" "dcim/power-ports" "" "$pp_json" >/dev/null
            else
                echo "  Power Port already exists: $pp_name"
            fi
        fi
    done

    echo "PSU sync completed."
}

#######################################################################################
# Netbox Modules
#######################################################################################

_ensure_module_type_profiles() {
    echo "Ensuring required ModuleType Profiles exist..."

    # Define required profiles
    declare -A required_profiles=(
        ["Controller"]="{
            \"name\": \"Controller\",
            \"description\": \"SAS/RAID/HBA controllers\",
            \"schema\": {
                \"properties\": {
                    \"controller_type\": {\"type\": \"string\", \"enum\": [\"SAS\", \"RAID\", \"HBA\", \"NVMe\"]},
                    \"firmware_version\": {\"type\": \"string\"},
                    \"ports\": {\"type\": \"integer\"},
                    \"interface_speed\": {\"type\": \"string\"}
                },
                \"required\": [\"controller_type\"]
            }
        }"
    )

    # Check and create each profile
    for profile_name in "${!required_profiles[@]}"; do
        local profile_data="${required_profiles[$profile_name]}"
        _debug_print "Checking profile: $profile_name"

        # URL encode profile name for API query
        local encoded_name
        encoded_name=$(printf '%s' "$profile_name" | jq -sRr 'split("\n") | .[0] | @uri')
        
        # Check if profile exists
        local exists_resp
        exists_resp=$(_api_request "GET" "dcim/module-type-profiles" "?name=$encoded_name" "")
        local count
        count=$(echo "$exists_resp" | jq -r '.count // 0')

        if [[ "$count" -eq 0 ]]; then
            _debug_print "Creating ModuleType Profile: $profile_name"
            _api_request "POST" "dcim/module-type-profiles" "" "$profile_data" >/dev/null
        else
            _debug_print "ModuleType Profile already exists: $profile_name"
        fi
    done

    echo "ModuleType Profile check completed."
}

create_modules() {
    local device_id="$1"

    echo ""
    _ensure_module_type_profiles

    _create_cpu_module_in_netbox "$device_id"
    _create_memory_module_in_netbox "$device_id"
    _create_disk_module_in_netbox "$device_id"
    _create_controller_module_in_netbox "$device_id"
    _create_gpu_module_in_netbox "$device_id"
    _create_nic_module_in_netbox "$device_id"
    _create_psu_modules_in_netbox "$device_id"
}

#######################################################################################
# Main execution
#######################################################################################
echo "Starting server registration in NetBox..."
# Create Device
create_devices

# Create module items
create_modules "$DEVICE_ID"

# Create Network Interface MAC and IP
detect_and_create_network_interfaces "$DEVICE_ID"
# Create Console Port
create_ipmi_interface "$DEVICE_ID"

# Get LLDP neighbors in JSON format
#get_lldp_neighbors "$DEVICE_ID"



echo ""
echo "Server registration completed!"
