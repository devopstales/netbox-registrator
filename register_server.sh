#!/bin/bash

# Netbox API Automation Script with Auto Device Type Detection
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

Register or update a server in Netbox with automatic device type detection.

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

Examples:
    $0                                  # Auto-detect everything, use hostname as name
    $0 --dry-run                        # Test mode - show detected data and Netbox status
    $0 --debug                          # Run with detailed debug output
    $0 -n backup01                      # Register with specific name
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
    
    # Method 1: Try dmidecode (most reliable for servers)
    if command -v dmidecode >/dev/null 2>&1 && [[ $EUID -eq 0 ]]; then
        debug_print "Trying dmidecode (root mode)..."
        if PRODUCT_NAME=$(dmidecode -s system-product-name 2>/dev/null | tr -d '\0'); then
            if [[ -n "$PRODUCT_NAME" && "$PRODUCT_NAME" != "To be filled by O.E.M." && "$PRODUCT_NAME" != "None" ]]; then
                debug_print "dmidecode found: '$PRODUCT_NAME'"
                echo "$PRODUCT_NAME"
                return 0
            else
                debug_print "dmidecode returned invalid value: '$PRODUCT_NAME'"
            fi
        else
            debug_print "dmidecode failed or returned empty"
        fi
    elif command -v dmidecode >/dev/null 2>&1; then
        debug_print "dmidecode available but not running as root"
    fi
    
    # Method 2: Try /sys/class/dmi/id/ (doesn't require root)
    if [[ -f "/sys/class/dmi/id/product_name" ]]; then
        debug_print "Trying /sys/class/dmi/id/product_name..."
        PRODUCT_NAME=$(cat /sys/class/dmi/id/product_name 2>/dev/null)
        if [[ -n "$PRODUCT_NAME" && "$PRODUCT_NAME" != "To be filled by O.E.M." && "$PRODUCT_NAME" != "None" ]]; then
            debug_print "Found in /sys: '$PRODUCT_NAME'"
            echo "$PRODUCT_NAME"
            return 0
        else
            debug_print "/sys returned invalid value: '$PRODUCT_NAME'"
        fi
    else
        debug_print "/sys/class/dmi/id/product_name not found"
    fi
    
    # Method 3: Try lshw (requires root for full info)
    if command -v lshw >/dev/null 2>&1; then
        debug_print "Trying lshw..."
        if PRODUCT_NAME=$(lshw -class system -short 2>/dev/null | grep -v "H/W" | head -2 | tail -1 | awk '{print $3,$4,$5}' | xargs); then
            if [[ -n "$PRODUCT_NAME" && "$PRODUCT_NAME" != "product:" ]]; then
                debug_print "lshw found: '$PRODUCT_NAME'"
                echo "$PRODUCT_NAME"
                return 0
            else
                debug_print "lshw returned invalid value: '$PRODUCT_NAME'"
            fi
        else
            debug_print "lshw failed or returned empty"
        fi
    fi
    
    # Method 4: Try /proc/cpuinfo for virtual machines
    if [[ -f "/proc/cpuinfo" ]]; then
        debug_print "Checking /proc/cpuinfo for VM signatures..."
        if grep -q "QEMU" /proc/cpuinfo 2>/dev/null; then
            debug_print "Detected QEMU VM"
            echo "Virtual Machine (QEMU)"
            return 0
        elif grep -q "VMware" /proc/cpuinfo 2>/dev/null; then
            debug_print "Detected VMware VM"
            echo "Virtual Machine (VMware)"
            return 0
        elif grep -q "Xen" /proc/cpuinfo 2>/dev/null; then
            debug_print "Detected Xen VM"
            echo "Virtual Machine (Xen)"
            return 0
        elif [[ -f "/sys/hypervisor/type" ]] && [[ "$(cat /sys/hypervisor/type 2>/dev/null)" == "xen" ]]; then
            debug_print "Detected Xen VM (via sysfs)"
            echo "Virtual Machine (Xen)"
            return 0
        fi
    fi
    
    # Method 5: Check for cloud instances
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        debug_print "Trying systemd-detect-virt..."
        VIRT_TYPE=$(systemd-detect-virt 2>/dev/null)
        if [[ "$VIRT_TYPE" != "none" ]]; then
            debug_print "Detected virtualization: $VIRT_TYPE"
            echo "Virtual Machine ($VIRT_TYPE)"
            return 0
        else
            debug_print "systemd-detect-virt returned 'none'"
        fi
    fi
    
    # Fallback: Use generic server type
    debug_print "All detection methods failed, using fallback"
    echo "Generic Server"
    return 1
}

# Function to detect serial number automatically
detect_serial() {
    debug_print "Starting serial number detection..."
    
    # Method 1: dmidecode (requires root)
    if command -v dmidecode >/dev/null 2>&1 && [[ $EUID -eq 0 ]]; then
        debug_print "Trying dmidecode for serial (root mode)..."
        if SERIAL_NUM=$(dmidecode -s system-serial-number 2>/dev/null | tr -d '\0'); then
            if [[ -n "$SERIAL_NUM" && "$SERIAL_NUM" != "To be filled by O.E.M." && "$SERIAL_NUM" != "None" ]]; then
                debug_print "dmidecode found serial: '$SERIAL_NUM'"
                echo "$SERIAL_NUM"
                return 0
            else
                debug_print "dmidecode returned invalid serial: '$SERIAL_NUM'"
            fi
        else
            debug_print "dmidecode serial detection failed"
        fi
    fi
    
    # Method 2: /sys/class/dmi/id/ (doesn't require root)
    if [[ -f "/sys/class/dmi/id/product_serial" ]]; then
        debug_print "Trying /sys/class/dmi/id/product_serial..."
        SERIAL_NUM=$(cat /sys/class/dmi/id/product_serial 2>/dev/null)
        if [[ -n "$SERIAL_NUM" && "$SERIAL_NUM" != "To be filled by O.E.M." && "$SERIAL_NUM" != "None" ]]; then
            debug_print "Found serial in /sys: '$SERIAL_NUM'"
            echo "$SERIAL_NUM"
            return 0
        else
            debug_print "/sys returned invalid serial: '$SERIAL_NUM'"
        fi
    else
        debug_print "/sys/class/dmi/id/product_serial not found"
    fi
    
    # No serial found
    debug_print "Serial detection failed"
    return 1
}

# Function to make API requests
api_request() {
    local method="$1"
    local endpoint="$2"
    local data="$3"
    
    debug_print "API Request: $method $NETBOX_URL/api/$endpoint/"
    if [[ -n "$data" ]]; then
        debug_print "API Payload: $data"
        local response
        response=$(curl -sS -X "$method" \
             -H "Authorization: Token $API_TOKEN" \
             -H "Content-Type: application/json" \
             -H "Accept: application/json" \
             -d "$data" \
             "$NETBOX_URL/api/$endpoint/")
        debug_print "API Response: $response"
        echo "$response"
    else
        local response
        response=$(curl -sS -X "$method" \
             -H "Authorization: Token $API_TOKEN" \
             -H "Accept: application/json" \
             "$NETBOX_URL/api/$endpoint/")
        debug_print "API Response: $response"
        echo "$response"
    fi
}

# Function to get site ID (create if doesn't exist, unless dry-run)
get_site_id() {
    local site_name="$1"
    debug_print "Checking site: $site_name"
    local response
    response=$(api_request "GET" "dcim/sites" "?name=$site_name")
    local site_id
    site_id=$(echo "$response" | jq -r '.results[0].id // empty')
    
    if [[ -z "$site_id" ]]; then
        if [[ "$DRY_RUN" == true ]]; then
            echo "  Site '$site_name': NOT FOUND (would be created)" >&2
        else
            debug_print "Site '$site_name' not found, creating..."
            echo "Site '$site_name' not found. Creating site..." >&2
            # Create the site
            local site_payload
            site_payload=$(jq -n --arg name "$site_name" --arg slug "$(echo "$site_name" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]-')" '{name: $name, slug: $slug}')
            local create_response
            create_response=$(api_request "POST" "dcim/sites" "$site_payload")
            site_id=$(echo "$create_response" | jq -r '.id')
            if [[ -z "$site_id" ]]; then
                echo "Error: Failed to create site '$site_name'" >&2
                debug_print "Site creation failed. Response: $create_response"
                exit 1
            fi
            echo "Site '$site_name' created successfully (ID: $site_id)" >&2
        fi
    else
        if [[ "$DRY_RUN" == true ]]; then
            echo "  Site '$site_name': FOUND (ID: $site_id)" >&2
        fi
        debug_print "Site found with ID: $site_id"
    fi
    echo "$site_id"
}

# Function to get device role ID (create if doesn't exist, unless dry-run)
get_role_id() {
    local role_name="$1"
    debug_print "Checking device role: $role_name"
    local response
    response=$(api_request "GET" "dcim/device-roles" "?name=$role_name")
    local role_id
    role_id=$(echo "$response" | jq -r '.results[0].id // empty')
    
    if [[ -z "$role_id" ]]; then
        if [[ "$DRY_RUN" == true ]]; then
            echo "  Device role '$role_name': NOT FOUND (would be created)" >&2
        else
            debug_print "Device role '$role_name' not found, creating..."
            echo "Device role '$role_name' not found. Creating device role..." >&2
            # Create the device role
            local role_payload
            local slug=$(echo "$role_name" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]-')
            role_payload=$(jq -n \
                --arg name "$role_name" \
                --arg slug "$slug" \
                --arg color "0080ff" \
                '{name: $name, slug: $slug, color: $color, vm_role: false}')
            local create_response
            create_response=$(api_request "POST" "dcim/device-roles" "$role_payload")
            role_id=$(echo "$create_response" | jq -r '.id')
            if [[ -z "$role_id" ]]; then
                echo "Error: Failed to create device role '$role_name'" >&2
                debug_print "Role creation failed. Response: $create_response"
                exit 1
            fi
            echo "Device role '$role_name' created successfully (ID: $role_id)" >&2
        fi
    else
        if [[ "$DRY_RUN" == true ]]; then
            echo "  Device role '$role_name': FOUND (ID: $role_id)" >&2
        fi
        debug_print "Device role found with ID: $role_id"
    fi
    echo "$role_id"
}

# Function to get device type ID - FIXED TO MATCH EXACT MODEL
get_device_type_id() {
    local type_name="$1"
    debug_print "Checking device type: $type_name"
    
    # Get all device types and filter locally for exact match
    local response
    response=$(api_request "GET" "dcim/device-types" "")
    local type_id
    # Use jq to find exact match (case-sensitive)
    type_id=$(echo "$response" | jq -r --arg model "$type_name" '.results[] | select(.model == $model) | .id | tostring | . // empty' | head -n1)
    
    if [[ -z "$type_id" ]]; then
        # Try without the trailing '+' if it exists
        if [[ "$type_name" == *"+" ]]; then
            local stripped_name="${type_name%+}"
            debug_print "Trying without trailing +: $stripped_name"
            type_id=$(echo "$response" | jq -r --arg model "$stripped_name" '.results[] | select(.model == $model) | .id | tostring | . // empty' | head -n1)
            if [[ -n "$type_id" ]]; then
                debug_print "Found match without +: $stripped_name"
                echo "$type_id"
                return 0
            fi
        fi
        
        if [[ "$DRY_RUN" == true ]]; then
            echo "  Device type '$type_name': NOT FOUND (must be created manually)" >&2
        else
            echo "Error: Device type '$type_name' not found in Netbox" >&2
            echo "Please create this device type in Netbox first, or use an existing one." >&2
            debug_print "Device type lookup failed. Available models:"
            echo "$response" | jq -r '.results[].model' | while read -r model; do
                debug_print "  - '$model'"
            done
            exit 1
        fi
    else
        if [[ "$DRY_RUN" == true ]]; then
            echo "  Device type '$type_name': FOUND (ID: $type_id)" >&2
        fi
        debug_print "Device type found with ID: $type_id"
    fi
    echo "$type_id"
}

# Check if device already exists
check_device_exists() {
    local device_name="$1"
    debug_print "Checking if device exists: $device_name"
    local response
    response=$(api_request "GET" "dcim/devices" "?name=$device_name")
    local device_id
    device_id=$(echo "$response" | jq -r '.results[0].id // empty')
    debug_print "Device check result: $device_id"
    echo "$device_id"
}

# Main execution
echo "Starting server registration in Netbox..."

if [[ "$DRY_RUN" == true ]]; then
    echo "DRY RUN MODE: No changes will be made to Netbox"
    echo "==============================================="
fi

if [[ "$DEBUG" == true ]]; then
    echo "DEBUG MODE: Detailed output enabled"
    echo "===================================="
fi

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
    else
        echo "Warning: Could not auto-detect serial number" >&2
    fi
fi

# Validate required parameters
if [[ -z "$DEVICE_TYPE" ]]; then
    echo "Error: Device type is required. Auto-detection failed and no type was specified." >&2
    exit 1
fi

# Display final configuration
echo ""
echo "Final Configuration:"
echo "  Device Name: $DEVICE_NAME"
echo "  Device Type: $DEVICE_TYPE"
echo "  Serial: ${SERIAL:-<not provided>}"
echo "  Asset Tag: ${ASSET_TAG:-<not provided>}"
echo "  Site: $DEFAULT_SITE"
echo "  Role: $DEFAULT_ROLE"
echo "  Status: $DEFAULT_STATUS"
if [[ -n "$COMMENTS" ]]; then
    echo "  Comments: $COMMENTS"
fi
if [[ -n "$CUSTOM_FIELDS" ]]; then
    echo "  Custom Fields: $CUSTOM_FIELDS"
fi
echo ""

if [[ "$DRY_RUN" == true ]]; then
    echo "Checking Netbox object existence:"
fi

# Get required IDs (will create if they don't exist, unless dry-run)
SITE_ID=$(get_site_id "$DEFAULT_SITE")
ROLE_ID=$(get_role_id "$DEFAULT_ROLE")
DEVICE_TYPE_ID=$(get_device_type_id "$DEVICE_TYPE")

# Check if device exists
EXISTING_DEVICE_ID=$(check_device_exists "$DEVICE_NAME")

if [[ "$DRY_RUN" == true ]]; then
    if [[ -n "$EXISTING_DEVICE_ID" ]]; then
        echo "  Device '$DEVICE_NAME': EXISTS (ID: $EXISTING_DEVICE_ID)"
        echo ""
        echo "ACTION: Would UPDATE existing device"
    else
        echo "  Device '$DEVICE_NAME': NOT FOUND"
        echo ""
        echo "ACTION: Would CREATE new device"
    fi
    echo ""
    echo "Dry run completed successfully. No changes made to Netbox."
    exit 0
fi

# Prepare comments (ensure it's never null)
COMMENTS_PAYLOAD="${COMMENTS:-}"

# Create payload function to avoid quoting issues
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

# Register or update device (only if not dry-run)
if [[ -n "$EXISTING_DEVICE_ID" ]]; then
    echo "Device '$DEVICE_NAME' already exists (ID: $EXISTING_DEVICE_ID). Updating..."
    PAYLOAD=$(create_payload_json "true")
    debug_print "Update payload: $PAYLOAD"
    RESPONSE=$(api_request "PUT" "dcim/devices/$EXISTING_DEVICE_ID" "$PAYLOAD")
    echo "Device updated successfully!"
else
    echo "Creating new device '$DEVICE_NAME'..."
    PAYLOAD=$(create_payload_json "false")
    debug_print "Create payload: $PAYLOAD"
    RESPONSE=$(api_request "POST" "dcim/devices" "$PAYLOAD")
    
    # Check if creation was successful
    if echo "$RESPONSE" | jq -e '.id' >/dev/null 2>&1; then
        echo "Device created successfully!"
    else
        echo "ERROR: Device creation failed!"
        if [[ "$DEBUG" == false ]]; then
            echo "Run with --debug to see detailed error information."
        fi
        debug_print "Creation failed. Response: $RESPONSE"
        exit 1
    fi
fi
