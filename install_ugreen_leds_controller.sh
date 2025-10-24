#!/usr/bin/env bash
set -euo pipefail

# Cleanup function to remove the ugreen_leds_controller folder
cleanup() {
    echo "Cleaning up..."
    rm -rf "$CLONE_DIR"
    echo "Cleanup completed."
}

# Error handler
error_exit() {
    echo "ERROR: $1" >&2
    exit 1
}

# Trap errors and cleanup
trap cleanup EXIT

# Utility function for user yes/no prompts
prompt_yes_no() {
    local prompt_text="$1"
    local response
    echo "$prompt_text (y/n)"
    read -r response
    if [[ "$response" != "y" && "$response" != "n" ]]; then
        echo "Invalid input. Defaulting to 'n'."
        response="n"
    fi
    [[ "$response" == "y" ]]
}

help() {
    echo "Installation helper for ugreen_leds_controller. Needs to be run as root"
    echo
    echo "Syntax: install_ugreen_leds_controller.sh [-h] [-v <version>]"
    echo "options:"
    echo "-h      Print this help."
    echo "-v      Use predefined TrueNAS version. If not specified it will be extracted from the OS," 
    echo "        but pre-built binaries might not exist. Use format X.Y.Z (X.Y.Z.W applicable as well)."
    echo
}

# Variables
REPO_URL="https://raw.githubusercontent.com/miskcoo/ugreen_leds_controller/refs/heads/gh-actions/build-scripts/truenas/build"
KMOD_URLS=(
    "https://github.com/miskcoo/ugreen_leds_controller/tree/gh-actions/build-scripts/truenas/build/TrueNAS-SCALE-ElectricEel"
    "https://github.com/miskcoo/ugreen_leds_controller/tree/gh-actions/build-scripts/truenas/build/TrueNAS-SCALE-Dragonfish"
    "https://github.com/miskcoo/ugreen_leds_controller/tree/gh-actions/build-scripts/truenas/build/TrueNAS-SCALE-Fangtooth"
)
TRUENAS_VERSION=""

# Version mapping: series -> release name
declare -A TRUENAS_SERIES_MAP=(
    ["24.10"]="TrueNAS-SCALE-ElectricEel"
    ["24.04"]="TrueNAS-SCALE-Dragonfish"
    ["25.04"]="TrueNAS-SCALE-Fangtooth"
)

# ============================================================================
# Argument Parsing
# ============================================================================

# Handle arguments first
while getopts ":hv:" option; do
    case "$option" in
        h)
            help
            exit 0;;
        v)
            TRUENAS_VERSION=${OPTARG}
            # Validate version format (X.Y.Z or X.Y.Z.W)
            if ! [[ "$TRUENAS_VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?(\.[0-9]+)?$ ]]; then
                error_exit "Invalid version format: $TRUENAS_VERSION. Use format X.Y.Z (X.Y.Z.W applicable as well)."
            fi
            ;;
        \?)
            error_exit "Invalid command line option -${OPTARG}. Use -h for help."
    esac
done

# ============================================================================
# Pre-flight Checks
# ============================================================================

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
    error_exit "Please run as root."
fi

# Use current working directory as installation and working directory
INSTALL_DIR="$(pwd)"

# Enforce working directory must be under /mnt/<POOL_NAME>/
if [[ "$INSTALL_DIR" != /mnt/* ]]; then
    error_exit "The script must be run from a directory under /mnt/<POOL_NAME>/. Current directory: $INSTALL_DIR"
fi

# Prevent running directly from /home (just in case)
if [[ "$INSTALL_DIR" == /home/* ]]; then
    error_exit "Do not run or install from /home. Use a directory under /mnt/<POOL_NAME>/"
fi

# Set the clone directory
CLONE_DIR="$INSTALL_DIR/ugreen_leds_controller"

# ============================================================================
# Version Detection and Validation
# ============================================================================

# Initialize an empty array for supported versions
SUPPORTED_VERSIONS=()
for URL in "${KMOD_URLS[@]}"; do
    HTML_CONTENT=$(curl -s "$URL")
    VERSIONS=$(echo "$HTML_CONTENT" | grep -oE 'TrueNAS-SCALE-[^/]*/[0-9]+(\.[0-9]+)*' | grep -oE '[0-9]+(\.[0-9]+)*')
    while IFS= read -r VERSION; do
        SUPPORTED_VERSIONS+=("$VERSION")
    done <<< "$VERSIONS"
done

SUPPORTED_VERSIONS=($(echo "${SUPPORTED_VERSIONS[@]}" | tr ' ' '\n' | sort -u))
OS_VERSION=$(cat /etc/version | grep -oP '^[0-9]+\.[0-9]+(\.[0-9]+)?(\.[0-9]+)?')
if [ -z "${OS_VERSION}" ]; then
    error_exit "Failed to detect TrueNAS SCALE version from /etc/version."
fi
if [ -z "${TRUENAS_VERSION}" ]; then
    TRUENAS_VERSION=${OS_VERSION}
fi

TRUENAS_SERIES=$(echo "$TRUENAS_VERSION" | cut -d'.' -f1,2)

# Resolve TrueNAS series to release name
if [[ -v TRUENAS_SERIES_MAP["$TRUENAS_SERIES"] ]]; then
    TRUENAS_NAME="${TRUENAS_SERIES_MAP[$TRUENAS_SERIES]}"
else
    error_exit "Unsupported TrueNAS SCALE version series: ${TRUENAS_SERIES}. Please build the kernel module manually."
fi

if [[ ! " ${SUPPORTED_VERSIONS[@]} " =~ " ${TRUENAS_VERSION} " ]]; then
    error_exit "Unsupported TrueNAS SCALE version: ${TRUENAS_VERSION}. Please build the kernel module manually."
fi

# ============================================================================
# Kernel Module Installation
# ============================================================================

MODULE_URL="${REPO_URL}/${TRUENAS_NAME}/${TRUENAS_VERSION}/led-ugreen.ko"

echo "Checking if kernel module exists for TrueNAS version ${TRUENAS_VERSION}..."
if ! curl --head --silent --fail "${MODULE_URL}" > /dev/null 2>&1; then
    error_exit "Kernel module not found for TrueNAS version ${TRUENAS_VERSION}. Please build the kernel module manually."
fi

BOOT_POOL_PATH="boot-pool/ROOT/${OS_VERSION}"

echo "Remounting boot-pool datasets with write access..."
mount -o remount,rw "${BOOT_POOL_PATH}/usr" || error_exit "Failed to remount ${BOOT_POOL_PATH}/usr"
mount -o remount,rw "${BOOT_POOL_PATH}/etc" || error_exit "Failed to remount ${BOOT_POOL_PATH}/etc"

# Clone the Ugreen LEDs Controller repository into subdirectory if not already present
if [ ! -d "$CLONE_DIR/.git" ]; then
    echo "Cloning Ugreen LEDs Controller repository into $CLONE_DIR..."
    git clone https://github.com/miskcoo/ugreen_leds_controller.git "$CLONE_DIR" -q || error_exit "Failed to clone repository"
    echo "Repository successfully cloned into $CLONE_DIR"
else
    echo "Repository already present in $CLONE_DIR"
fi

# Install the kernel module
echo "Installing the kernel module..."
mkdir -p "/lib/modules/$(uname -r)/extra" || error_exit "Failed to create kernel module directory"
curl -so "/lib/modules/$(uname -r)/extra/led-ugreen.ko" "${MODULE_URL}" || error_exit "Kernel module download failed"
chmod 644 "/lib/modules/$(uname -r)/extra/led-ugreen.ko"

# Create kernel module load configuration
echo "Creating kernel module load configuration..."
cat <<EOL > /etc/modules-load.d/ugreen-led.conf
i2c-dev
led-ugreen
ledtrig-oneshot
ledtrig-netdev
EOL
chmod 644 /etc/modules-load.d/ugreen-led.conf

echo "Loading kernel modules..."
depmod || error_exit "Failed to run depmod"
modprobe -a i2c-dev led-ugreen ledtrig-oneshot ledtrig-netdev || error_exit "Failed to load kernel modules"

# ============================================================================
# Configuration File Setup
# ============================================================================

CONFIG_FILE="$INSTALL_DIR/ugreen-leds.conf"
TEMPLATE_CONFIG="$CLONE_DIR/scripts/ugreen-leds.conf"

# Validate template config exists
if [ ! -f "$TEMPLATE_CONFIG" ]; then
    error_exit "Template configuration file not found at $TEMPLATE_CONFIG"
fi

# Handle configuration file setup
setup_config_file() {
    local config_source="$1"
    local should_edit="$2"
    
    if [[ "$should_edit" == "true" ]]; then
        nano "$config_source" || echo "Warning: Failed to edit configuration file"
    fi
    
    cp "$config_source" /etc/ugreen-leds.conf || error_exit "Failed to copy to /etc/ugreen-leds.conf"
}

if [[ -f "$CONFIG_FILE" ]]; then
    echo "Using existing configuration file at $CONFIG_FILE"
    echo ""
    echo "################################################################################################################################################"
    echo "Note: The configuration file from the repository may have new options. Please review $TEMPLATE_CONFIG and update your $CONFIG_FILE if necessary."
    echo "################################################################################################################################################"
    echo ""
    if prompt_yes_no "Do you want to modify the LED configuration file now?"; then
        setup_config_file "$CONFIG_FILE" "true"
    else
        setup_config_file "$CONFIG_FILE" "false"
    fi
    echo "Configuration file $CONFIG_FILE for ugreen-leds copied to /etc/ugreen-leds.conf."
else
    if prompt_yes_no "Do you want to modify the LED configuration file now?"; then
        setup_config_file "$TEMPLATE_CONFIG" "true"
    else
        setup_config_file "$TEMPLATE_CONFIG" "false"
    fi
    cp "$TEMPLATE_CONFIG" "$CONFIG_FILE" || error_exit "Failed to copy template to $CONFIG_FILE"
    chmod 644 /etc/ugreen-leds.conf
    echo "Configuration file for ugreen-leds saved as /etc/ugreen-leds.conf."
fi

# ============================================================================
# Network Interface Detection and Service Setup
# ============================================================================

echo "Detecting network interfaces..."
NETWORK_INTERFACES=($(ip -br link show | awk '$1 !~ /^(lo|docker|veth|br|vb)/ && $2 == "UP" {print $1}'))

if [ ${#NETWORK_INTERFACES[@]} -eq 0 ]; then
    echo "Warning: No network interfaces detected. Skipping ugreen-netdevmon service setup."
else
    ACTIVE_INTERFACES=()
    for interface in "${NETWORK_INTERFACES[@]}"; do
        if ifconfig "$interface" 2>/dev/null | grep -q "UP"; then
            ACTIVE_INTERFACES+=("$interface")
        fi
    done

    if [ ${#ACTIVE_INTERFACES[@]} -eq 0 ]; then
        echo "No active interfaces detected. Skipping ugreen-netdevmon service setup."
    elif [ ${#ACTIVE_INTERFACES[@]} -eq 1 ]; then
        CHOSEN_INTERFACE="${ACTIVE_INTERFACES[0]}"
        echo "Detected one active interface: ${CHOSEN_INTERFACE}."
    else
        echo "Multiple active interfaces detected: ${ACTIVE_INTERFACES[*]}"
        echo "Please choose one interface to use:"
        select CHOSEN_INTERFACE in "${ACTIVE_INTERFACES[@]}"; do
            # Validate selection
            if [[ -n "$CHOSEN_INTERFACE" ]]; then
                echo "You selected: ${CHOSEN_INTERFACE}"
                break
            else
                echo "Invalid selection. Please try again."
            fi
        done
    fi
fi

# ============================================================================
# Service Management
# ============================================================================

check_and_remove_existing_services() {
    local service_name="ugreen-netdevmon"
    echo "Checking for existing services matching: ${service_name}@*.service"
    for service in /etc/systemd/system/multi-user.target.wants/${service_name}@*.service; do
        if [ -e "$service" ]; then
            local interface=$(basename "$service" | sed "s/${service_name}@\(.*\)\.service/\1/")
            # Validate interface name (alphanumeric and hyphens only)
            if ! [[ "$interface" =~ ^[a-zA-Z0-9-]+$ ]]; then
                echo "Warning: Invalid interface name extracted from service: $interface"
                continue
            fi
            echo "Found existing service for interface ${interface}. Removing..."
            systemctl stop "${service_name}@${interface}.service" 2>/dev/null || echo "Warning: Failed to stop ${service_name}@${interface}.service"
            systemctl disable "${service_name}@${interface}.service" 2>/dev/null || echo "Warning: Failed to disable ${service_name}@${interface}.service"
            rm -f "$service" || echo "Warning: Failed to remove service file"
            echo "Successfully removed ${service_name}@${interface}.service"
        fi
    done
    systemctl daemon-reload || echo "Warning: Failed to reload systemd daemon"
}

check_and_remove_existing_services

# Copy scripts and configure services
echo "Setting up systemd services..."
cd "$CLONE_DIR" || error_exit "Failed to change directory to $CLONE_DIR"

scripts=("ugreen-diskiomon" "ugreen-netdevmon" "ugreen-probe-leds" "ugreen-power-led")
for script in "${scripts[@]}"; do
    if [ ! -f "scripts/$script" ]; then
        error_exit "Script not found: scripts/$script"
    fi
    chmod +x "scripts/$script" || error_exit "Failed to make script executable: scripts/$script"
    cp "scripts/$script" /usr/bin || error_exit "Failed to copy script to /usr/bin: $script"
done

# Verify systemd service files exist before copying
if [ ! -d "scripts/systemd" ]; then
    error_exit "Systemd service directory not found: scripts/systemd"
fi
cp scripts/systemd/*.service /etc/systemd/system/ || error_exit "Failed to copy systemd service files"
systemctl daemon-reload || error_exit "Failed to reload systemd daemon"

echo "Enabling and starting ugreen-diskiomon service..."
systemctl start ugreen-diskiomon.service || error_exit "Failed to start ugreen-diskiomon.service"
systemctl enable ugreen-diskiomon.service || error_exit "Failed to enable ugreen-diskiomon.service"

if [ ${#NETWORK_INTERFACES[@]} -eq 0 ]; then
    echo "Warning: No network interfaces detected. Skipping ugreen-netdevmon service setup."
else
    # Validate CHOSEN_INTERFACE is set and contains only valid characters
    if [ -z "${CHOSEN_INTERFACE:-}" ]; then
        echo "Warning: No network interface selected. Skipping ugreen-netdevmon service setup."
    elif ! [[ "$CHOSEN_INTERFACE" =~ ^[a-zA-Z0-9-]+$ ]]; then
        error_exit "Invalid interface name: $CHOSEN_INTERFACE"
    else
        echo "Enabling and starting ugreen-netdevmon service for interface: ${CHOSEN_INTERFACE}..."
        systemctl enable "ugreen-netdevmon@${CHOSEN_INTERFACE}" || error_exit "Failed to enable ugreen-netdevmon@${CHOSEN_INTERFACE}.service"
        systemctl restart "ugreen-netdevmon@${CHOSEN_INTERFACE}" || error_exit "Failed to restart ugreen-netdevmon@${CHOSEN_INTERFACE}.service"
    fi
fi

# Check if CONFIG_FILE exists before checking BLINK_TYPE_POWER
if [ ! -f "$CONFIG_FILE" ]; then
    error_exit "Configuration file not found: $CONFIG_FILE"
fi

# Check if BLINK_TYPE_POWER is enabled
if grep -qP '^BLINK_TYPE_POWER=(?!none$).+' "$CONFIG_FILE"; then
    echo "Enabling and starting ugreen-power-led.service because BLINK_TYPE_POWER is set."
    systemctl enable ugreen-power-led.service || error_exit "Failed to enable ugreen-power-led.service"
    systemctl start ugreen-power-led.service || error_exit "Failed to start ugreen-power-led.service"
else
    echo "BLINK_TYPE_POWER is set to 'none', not enabling ugreen-power-led.service."
fi

cleanup

echo "Setup complete. Reboot your system to verify."
