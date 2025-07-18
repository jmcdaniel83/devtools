#!/bin/bash

# System Update Script with Proper Logging
# This script performs system updates and logs all activities to syslog and local log files

# Script configuration
SCRIPT_NAME="system_update"
LOG_FILE="/var/log/system_update.log"
LOCK_FILE="/var/run/system_update.lock"
FIRMWARE_LOG="/var/log/firmware_update.log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to log messages to both syslog and local log file
log_message() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Log to syslog
    logger -t "$SCRIPT_NAME" -p "user.$level" "$message"

    # Log to local file
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"

    # Also print to console with colors
    case $level in
        "info")
            echo -e "${GREEN}[INFO]${NC} $message"
            ;;
        "warning")
            echo -e "${YELLOW}[WARNING]${NC} $message"
            ;;
        "error")
            echo -e "${RED}[ERROR]${NC} $message"
            ;;
        "debug")
            echo -e "${BLUE}[DEBUG]${NC} $message"
            ;;
        *)
            echo "[$level] $message"
            ;;
    esac
}

# Function to check if script is already running
check_lock() {
    if [ -f "$LOCK_FILE" ]; then
        local pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if ps -p "$pid" > /dev/null 2>&1; then
            log_message "error" "Script is already running (PID: $pid)"
            exit 1
        else
            log_message "warning" "Removing stale lock file"
            rm -f "$LOCK_FILE"
        fi
    fi

    # Create lock file
    echo $$ > "$LOCK_FILE"
}

# Function to cleanup on exit
cleanup() {
    log_message "info" "Cleaning up..."
    rm -f "$LOCK_FILE"
    exit 0
}

# Function to check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_message "error" "This script must be run as root"
        exit 1
    fi
}

# Function to check for firmware updates
check_firmware_updates() {
    log_message "info" "Checking for firmware updates..."

    # Check if fwupd is available
    if command -v fwupdmgr >/dev/null 2>&1; then
        log_message "info" "Using fwupdmgr to check firmware updates"

        # Refresh metadata
        fwupdmgr refresh >> "$FIRMWARE_LOG" 2>&1
        local refresh_exit_code=$?
        if [ $refresh_exit_code -eq 0 ]; then
            log_message "info" "Firmware metadata refreshed successfully"
        else
            # Check if it's the common "capsule updates not available" error
            if grep -q "UEFI capsule updates not available" "$FIRMWARE_LOG" 2>/dev/null; then
                log_message "info" "Firmware capsule updates not available (this is normal for many systems)"
            else
                log_message "warning" "Failed to refresh firmware metadata (exit code: $refresh_exit_code)"
            fi
        fi

        # Check for available updates
        local updates=$(fwupdmgr get-updates 2>/dev/null | grep -c "Available")
        if [ "$updates" -gt 0 ]; then
            log_message "info" "Found $updates firmware update(s) available"
            return 0
        else
            log_message "info" "No firmware updates available"
            return 1
        fi
    else
        log_message "warning" "fwupdmgr not available - skipping firmware check"
        return 1
    fi
}

# Function to install firmware updates
install_firmware_updates() {
    log_message "info" "Installing firmware updates..."

    if command -v fwupdmgr >/dev/null 2>&1; then
        # Install updates
        fwupdmgr update >> "$FIRMWARE_LOG" 2>&1
        local exit_code=$?

        if [ $exit_code -eq 0 ]; then
            log_message "info" "Firmware updates installed successfully"
        else
            log_message "error" "Failed to install firmware updates (exit code: $exit_code)"
        fi

        return $exit_code
    else
        log_message "error" "fwupdmgr not available - cannot install firmware updates"
        return 1
    fi
}

# Main execution
main() {
    # Set up signal handlers
    trap cleanup EXIT INT TERM

    # Check if running as root
    check_root

    # Check for lock file
    check_lock

    # Create log directory if it doesn't exist
    mkdir -p "$(dirname "$LOG_FILE")"
    mkdir -p "$(dirname "$FIRMWARE_LOG")"

    log_message "info" "Starting system update process"
    log_message "info" "Log file: $LOG_FILE"
    log_message "info" "Firmware log: $FIRMWARE_LOG"

    # Step 1: apt update
    log_message "info" "Step 1: Running apt update..."
    if apt update >> "$LOG_FILE" 2>&1; then
        log_message "info" "apt update completed successfully"
    else
        log_message "error" "apt update failed"
        exit 1
    fi

    # Step 2: apt upgrade
    log_message "info" "Step 2: Running apt upgrade..."
    if apt upgrade -y >> "$LOG_FILE" 2>&1; then
        log_message "info" "apt upgrade completed successfully"
    else
        log_message "error" "apt upgrade failed"
        exit 1
    fi

    # Step 3: apt autoremove
    log_message "info" "Step 3: Running apt autoremove..."
    if apt autoremove -y >> "$LOG_FILE" 2>&1; then
        log_message "info" "apt autoremove completed successfully"
    else
        log_message "error" "apt autoremove failed"
        exit 1
    fi

    # Step 4: Check for firmware updates
    log_message "info" "Step 4: Checking for firmware updates..."
    if check_firmware_updates; then
        log_message "info" "Firmware updates are available"

        # Step 5: Install firmware updates
        log_message "info" "Step 5: Installing firmware updates..."
        if install_firmware_updates; then
            log_message "info" "Firmware updates installed successfully"
        else
            log_message "error" "Firmware update installation failed"
            exit 1
        fi
    else
        log_message "info" "No firmware updates available - skipping installation"
    fi

    log_message "info" "System update process completed successfully"

    # Show summary
    echo
    log_message "info" "=== UPDATE SUMMARY ==="
    log_message "info" "All system updates completed"
    log_message "info" "Check logs at: $LOG_FILE"
    log_message "info" "Firmware logs at: $FIRMWARE_LOG"
}

# Run main function
main "$@"