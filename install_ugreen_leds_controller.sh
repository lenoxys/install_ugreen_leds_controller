#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Configuration Section - Centralized Settings
# ============================================================================

# Script metadata
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="1.0.0"

# Installation directories and paths
readonly CLONE_DIR_NAME="ugreen_leds_controller"
readonly KERNEL_MODULES_DIR="/lib/modules"
readonly MODULES_LOAD_DIR="/etc/modules-load.d"
readonly SYSTEMD_SYSTEM_DIR="/etc/systemd/system"
readonly SCRIPTS_BIN_DIR="/usr/bin"
readonly CONFIG_FILENAME="ugreen-leds.conf"
readonly MODULES_LOAD_CONF="ugreen-led.conf"

# Network and timeouts
readonly CURL_TIMEOUT=30
readonly MAX_RETRIES=3

# Repository URLs
readonly REPO_URL="https://raw.githubusercontent.com/miskcoo/ugreen_leds_controller/refs/heads/gh-actions/build-scripts/truenas/build"
readonly REPO_HOME="https://github.com/miskcoo/ugreen_leds_controller"

# Kernel modules to load
readonly KERNEL_MODULES=("i2c-dev" "led-ugreen" "ledtrig-oneshot" "ledtrig-netdev")

# Scripts to copy from repository
readonly REPO_SCRIPTS=("ugreen-diskiomon" "ugreen-netdevmon" "ugreen-probe-leds" "ugreen-power-led")

# Version mapping: series -> release name
declare -A TRUENAS_SERIES_MAP=(
    ["24.10"]="TrueNAS-SCALE-ElectricEel"
    ["24.04"]="TrueNAS-SCALE-Dragonfish"
    ["25.04"]="TrueNAS-SCALE-Fangtooth"
)

# Kernel module build URLs for version detection
declare -a KMOD_URLS=(
    "https://github.com/miskcoo/ugreen_leds_controller/tree/gh-actions/build-scripts/truenas/build/TrueNAS-SCALE-ElectricEel"
    "https://github.com/miskcoo/ugreen_leds_controller/tree/gh-actions/build-scripts/truenas/build/TrueNAS-SCALE-Dragonfish"
    "https://github.com/miskcoo/ugreen_leds_controller/tree/gh-actions/build-scripts/truenas/build/TrueNAS-SCALE-Fangtooth"
)

# Required system commands for pre-requisite checks
readonly REQUIRED_COMMANDS=("curl" "git" "mount" "modprobe" "systemctl" "grep" "sed" "awk")

# ============================================================================
# Output Control Flags
# ============================================================================

VERBOSE=false
QUIET=false

# Helper function: Print message if not in quiet mode
log_info() {
    if [ "$QUIET" = false ]; then
        echo "$@"
    fi
}

# Helper function: Print message if in verbose mode
log_verbose() {
    if [ "$VERBOSE" = true ]; then
        echo "[VERBOSE] $@"
    fi
}

# Helper function: Print section header
print_section() {
    local section_title="$1"
    echo ""
    echo "─────────────────────────────────────────────────────────────────────────────"
    echo "→ $section_title"
    echo "─────────────────────────────────────────────────────────────────────────────"
}

# ============================================================================
# Runtime Variables (populated during execution)
# ============================================================================

TRUENAS_VERSION=""
CLONE_DIR=""
INSTALL_DIR=""
OS_VERSION=""
TRUENAS_NAME=""
MODULE_URL=""
CONFIG_FILE=""
TEMPLATE_CONFIG=""
CHOSEN_INTERFACE=""
ACTIVE_INTERFACES=()
SUPPORTED_VERSIONS=()

# Cleanup function to remove the ugreen_leds_controller folder
cleanup() {
    if [[ -n "${CLONE_DIR:-}" && -d "$CLONE_DIR" ]]; then
        echo "Cleaning up..."
        rm -rf "$CLONE_DIR" 2>/dev/null || echo "Warning: Failed to clean up $CLONE_DIR"
        echo "Cleanup completed."
    fi
}

# Error handler
error_exit() {
    echo "ERROR: $1" >&2
    exit 1
}

# Warning handler
warn() {
    echo "WARNING: $1" >&2
}

# Trap errors and cleanup
trap cleanup EXIT

# Check for required commands
check_required_commands() {
    for cmd in "${REQUIRED_COMMANDS[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            error_exit "Required command not found: $cmd. Please install it and try again."
        fi
    done
}

# Helper function: Enable and start a systemd service
enable_and_start_service() {
    local service_name="$1"
    echo "Enabling and starting $service_name..."
    systemctl start "$service_name" || error_exit "Failed to start $service_name"
    systemctl enable "$service_name" || error_exit "Failed to enable $service_name"
}

# Helper function: Enable, start, or conditionally manage a service
setup_service() {
    local service_name="$1"
    local should_enable="$2"
    local reason="${3:-}"
    
    if [[ "$should_enable" == "true" ]]; then
        if [[ -n "$reason" ]]; then
            echo "Enabling and starting $service_name ($reason)..."
        else
            echo "Enabling and starting $service_name..."
        fi
        systemctl enable "$service_name" || error_exit "Failed to enable $service_name"
        systemctl start "$service_name" || error_exit "Failed to start $service_name"
    else
        echo "Skipping $service_name (not enabled)."
    fi
}

# Utility function for user yes/no prompts
prompt_yes_no() {
    local prompt_text="$1"
    local response
    echo "$prompt_text (y/n)"
    read -r response < /dev/tty
    if [[ "$response" != "y" && "$response" != "n" ]]; then
        echo "Invalid input. Defaulting to 'n'."
        response="n"
    fi
    [[ "$response" == "y" ]]
}

help() {
    echo "Installation helper for ugreen_leds_controller. Needs to be run as root"
    echo
    echo "Syntax: install_ugreen_leds_controller.sh [-h] [-v <version>] [-q] [-V]"
    echo "options:"
    echo "-h           Print this help."
    echo "-v <version> Use predefined TrueNAS version. If not specified it will be extracted from the OS,"
    echo "             but pre-built binaries might not exist. Use format X.Y.Z (X.Y.Z.W applicable as well)."
    echo "-q           Quiet mode: suppress informational messages (errors always shown)."
    echo "-V           Verbose mode: show detailed debug information."
    echo
}

# ============================================================================
# Argument Parsing
# ============================================================================

# Handle arguments first
while getopts ":hv:qV" option; do
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
        q)
            QUIET=true
            ;;
        V)
            VERBOSE=true
            ;;
        \?)
            error_exit "Invalid command line option -${OPTARG}. Use -h for help."
    esac
done

# ============================================================================
# Pre-flight Checks
# ============================================================================

print_section "Pre-flight Checks"

# Check for required commands
check_required_commands

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
# Installation Confirmation
# ============================================================================

echo ""
echo "╔════════════════════════════════════════════════════════════════════════════╗"
echo "║         Ugreen LED Controller Installation Confirmation                    ║"
echo "╚════════════════════════════════════════════════════════════════════════════╝"
echo ""
log_info "This script will perform the following actions:"
log_info "  • Download and verify kernel module for TrueNAS ${TRUENAS_VERSION}"
log_info "  • Remount boot-pool datasets with write access"
log_info "  • Clone Ugreen LED Controller repository"
log_info "  • Install kernel modules and system services"
log_info "  • Configure LED control services"
echo ""
echo "⚠️  WARNING: This script modifies system files and mounts. Interruption may cause instability."
echo ""

if ! prompt_yes_no "Do you want to proceed with the installation?"; then
    echo "Installation cancelled by user."
    exit 0
fi

# ============================================================================
# Version Detection and Validation
# ============================================================================

print_section "Version Detection and Validation"

# Initialize an empty array for supported versions
SUPPORTED_VERSIONS=()
for URL in "${KMOD_URLS[@]}"; do
    HTML_CONTENT=$(curl -s --max-time "$CURL_TIMEOUT" "$URL" 2>/dev/null) || {
        warn "Failed to fetch from $URL. Skipping version detection from this URL."
        continue
    }
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
if [[ ${TRUENAS_SERIES_MAP[$TRUENAS_SERIES]:-} ]]; then
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

print_section "Kernel Module Installation"

MODULE_URL="${REPO_URL}/${TRUENAS_NAME}/${TRUENAS_VERSION}/led-ugreen.ko"

echo "Checking if kernel module exists for TrueNAS version ${TRUENAS_VERSION}..."
if ! curl --head --silent --fail --max-time "$CURL_TIMEOUT" "${MODULE_URL}" > /dev/null 2>&1; then
    error_exit "Kernel module not found for TrueNAS version ${TRUENAS_VERSION}. Please build the kernel module manually."
fi

BOOT_POOL_PATH="boot-pool/ROOT/${OS_VERSION}"

echo "Remounting boot-pool datasets with write access..."
mount -o remount,rw "${BOOT_POOL_PATH}/usr" || error_exit "Failed to remount ${BOOT_POOL_PATH}/usr. Verify the path exists and you have proper permissions."
mount -o remount,rw "${BOOT_POOL_PATH}/etc" || error_exit "Failed to remount ${BOOT_POOL_PATH}/etc. Verify the path exists and you have proper permissions."

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
mkdir -p "${KERNEL_MODULES_DIR}/$(uname -r)/extra" || error_exit "Failed to create kernel module directory"
curl -so "${KERNEL_MODULES_DIR}/$(uname -r)/extra/led-ugreen.ko" "${MODULE_URL}" || error_exit "Kernel module download failed"
chmod 644 "${KERNEL_MODULES_DIR}/$(uname -r)/extra/led-ugreen.ko"

# Create kernel module load configuration
echo "Creating kernel module load configuration..."
if [ ! -w "$MODULES_LOAD_DIR/" ]; then
    error_exit "No write permission to $MODULES_LOAD_DIR/. Make sure you're running as root."
fi

cat <<EOL > "$MODULES_LOAD_DIR/$MODULES_LOAD_CONF"
${KERNEL_MODULES[0]}
${KERNEL_MODULES[1]}
${KERNEL_MODULES[2]}
${KERNEL_MODULES[3]}
EOL
chmod 644 "$MODULES_LOAD_DIR/$MODULES_LOAD_CONF" || error_exit "Failed to set permissions on $MODULES_LOAD_DIR/$MODULES_LOAD_CONF"

echo "Loading kernel modules..."
depmod || error_exit "Failed to run depmod"
modprobe -a "${KERNEL_MODULES[@]}" || error_exit "Failed to load kernel modules"

# ============================================================================
# Configuration File Setup
# ============================================================================

print_section "Configuration File Setup"

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
        # Check if we have a terminal before trying to edit
        if [ -t 0 ]; then
            nano "$config_source" || echo "Warning: Failed to edit configuration file"
        else
            echo "Note: Running without terminal (piped script). Skipping interactive config editing."
            echo "You can manually edit the config after installation at: /etc/ugreen-leds.conf"
        fi
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

print_section "Network Interface Detection"

echo "Detecting network interfaces..."
# Filter for physical network interfaces: exclude loopback, docker, bridges, virtual ethernet, and incus interfaces
ACTIVE_INTERFACES=($(ip -br link show | awk '$1 !~ /^(lo|docker|veth|br-|vb|incus)/ && $2 == "UP" {print $1}'))

if [ ${#ACTIVE_INTERFACES[@]} -eq 0 ]; then
    error_exit "No active network interfaces detected. A NAS requires at least one network connection."
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

# ============================================================================
# Service Management
# ============================================================================

print_section "Service Management"

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
            echo "Found existing service for interface ${interface}. Stopping..."
            systemctl stop "${service_name}@${interface}.service" 2>/dev/null || echo "Warning: Failed to stop ${service_name}@${interface}.service"
            systemctl disable "${service_name}@${interface}.service" 2>/dev/null || echo "Warning: Failed to disable ${service_name}@${interface}.service"
            rm -f "$service" || echo "Warning: Failed to remove service file"
            echo "Successfully removed ${service_name}@${interface}.service"
        fi
    done
    
    # Stop all ugreen services
    echo "Stopping all ugreen services..."
    systemctl stop ugreen-diskiomon.service 2>/dev/null || echo "Note: ugreen-diskiomon.service not running"
    systemctl stop ugreen-power-led.service 2>/dev/null || echo "Note: ugreen-power-led.service not running"
    
    systemctl daemon-reload || echo "Warning: Failed to reload systemd daemon"
}

check_and_remove_existing_services

# Copy scripts and configure services
echo "Setting up systemd services..."
cd "$CLONE_DIR" || error_exit "Failed to change directory to $CLONE_DIR"

for script in "${REPO_SCRIPTS[@]}"; do
    if [ ! -f "scripts/$script" ]; then
        error_exit "Script not found: scripts/$script"
    fi
    chmod +x "scripts/$script" || error_exit "Failed to make script executable: scripts/$script"
    cp "scripts/$script" "$SCRIPTS_BIN_DIR" || error_exit "Failed to copy script to $SCRIPTS_BIN_DIR: $script"
done

# Verify systemd service files exist before copying
if [ ! -d "scripts/systemd" ]; then
    error_exit "Systemd service directory not found: scripts/systemd"
fi
cp scripts/systemd/*.service "$SYSTEMD_SYSTEM_DIR" || error_exit "Failed to copy systemd service files"
systemctl daemon-reload || error_exit "Failed to reload systemd daemon"

echo "Starting LED services with updated service files..."

# Check if CONFIG_FILE exists before checking BLINK_TYPE_POWER
if [ ! -f "$CONFIG_FILE" ]; then
    error_exit "Configuration file not found: $CONFIG_FILE"
fi

# Determine if power LED should be enabled
power_led_enabled="false"
if grep -qP '^BLINK_TYPE_POWER=(?!none$).+' "$CONFIG_FILE"; then
    power_led_enabled="true"
fi

# Setup all services with harmonized approach
setup_service "ugreen-diskiomon.service" "true"
setup_service "ugreen-netdevmon@${CHOSEN_INTERFACE}.service" "true" "interface: ${CHOSEN_INTERFACE}"
setup_service "ugreen-power-led.service" "$power_led_enabled" "BLINK_TYPE_POWER enabled"

cleanup

print_section "Installation Complete"
echo ""
echo "✅ Ugreen LED Controller has been installed successfully!"
echo ""
echo "Next steps:"
echo "  1. Reboot your system to load the kernel modules"
echo "  2. Verify the LED status after reboot"
echo ""
echo "For troubleshooting, check:"
echo "  • systemctl status ugreen-diskiomon.service"
if [ -n "${CHOSEN_INTERFACE:-}" ]; then
    echo "  • systemctl status ugreen-netdevmon@${CHOSEN_INTERFACE}.service"
fi
echo "  • systemctl status ugreen-power-led.service"
echo ""
