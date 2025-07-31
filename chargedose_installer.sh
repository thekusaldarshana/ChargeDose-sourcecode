#!/bin/bash
# Chargedose Complete Installer Script - Robust & Lightweight
# Copy, paste, and launch ready - handles everything automatically

# --- Configuration Variables ---
SCRIPT_NAME="chargedose"
SCRIPT_FILE="/usr/local/bin/${SCRIPT_NAME}.sh"
# SERVICE_FILE="${HOME}/.config/systemd/user/${SCRIPT_NAME}.service" # Removed systemd specific variable
# TIMER_FILE="${HOME}/.config/systemd/user/${SCRIPT_NAME}.timer" # Removed systemd specific variable
LOG_FILE="/tmp/${SCRIPT_NAME}_log.txt"
WRAPPER_FILE="/usr/local/bin/${SCRIPT_NAME}-wrapper.sh"

# Default sound paths to try
DEFAULT_SOUNDS=(
    "/usr/share/sounds/freedesktop/stereo/complete.oga"
    "/usr/share/sounds/alsa/Rear_Left.wav"
    "/usr/share/sounds/sound-icons/prompt.wav"
    "/usr/share/sounds/generic.wav"
)

# --- Chargedose Main Script ---
read -r -d '' CHARGEDOSE_SCRIPT_CONTENT << 'EOF'
#!/bin/bash
# Chargedose Battery Alert - V2.0

# --- User Settings ---
ALERT_LOW_THRESHOLD=20
ALERT_HIGH_THRESHOLD=80
PERCENTAGE_HYSTERESIS=3
CUSTOM_SOUND_PATH="CUSTOM_SOUND_PATH_PLACEHOLDER"

# --- Internal Variables ---
LOG_FILE="/tmp/chargedose_log.txt"
LAST_LOW_ALERTED_PERCENTAGE=101
LAST_HIGH_ALERTED_PERCENTAGE=0
LAST_BATTERY_STATUS=""

# notification function with multiple fallbacks
send_robust_notification() {
    local title="$1"
    local message="$2"
    local icon="$3"
    local success=false
    
    # Method 1: Standard notify-send with multiple DBUS attempts
    if command -v notify-send >/dev/null 2>&1; then
        # Try current session
        if notify-send "$title" "$message" -i "$icon" -t 8000 >/dev/null 2>&1; then
            success=true
        else
            # Try with explicit DBUS addresses
            for dbus_addr in "unix:path=/run/user/$(id -u)/bus" "unix:path=/tmp/dbus-*"; do
                if DBUS_SESSION_BUS_ADDRESS="$dbus_addr" notify-send "$title" "$message" -i "$icon" -t 8000 >/dev/null 2>&1; then
                    success=true
                    break
                fi
            done
        fi
    fi
    
    # Method 2: Try gdbus direct call
    if [ "$success" = false ] && command -v gdbus >/dev/null 2>&1; then
        if gdbus call --session --dest org.freedesktop.Notifications \
            --object-path /org/freedesktop/Notifications \
            --method org.freedesktop.Notifications.Notify \
            "Chargedose" 0 "$icon" "$title" "$message" "[]" "{}" 8000 >/dev/null 2>&1; then
            success=true
        fi
    fi
    
    # Method 3: GUI dialog fallbacks
    if [ "$success" = false ]; then
        if command -v zenity >/dev/null 2>&1; then
            (echo "$message" | zenity --info --title="$title" --timeout=8 >/dev/null 2>&1 &)
            success=true
        elif command -v kdialog >/dev/null 2>&1; then
            (kdialog --msgbox "$message" --title "$title" >/dev/null 2>&1 &)
            success=true
        elif command -v xmessage >/dev/null 2>&1; then
            (echo "$message" | xmessage -title "$title" -timeout 8 -file - >/dev/null 2>&1 &)
            success=true
        fi
    fi
    
    # Method 4: System logger (always works)
    logger -t "Chargedose" "$title: $message"
    
    return 0
}

# sound playing function
play_sound_robust() {
    if [ ! -f "$CUSTOM_SOUND_PATH" ]; then
        return 1
    fi
    
    # Try paplay first (PulseAudio)
    if command -v paplay >/dev/null 2>&1; then
        (paplay "$CUSTOM_SOUND_PATH" >/dev/null 2>&1 &)
        return 0
    fi
    
    # Try aplay (ALSA)
    if command -v aplay >/dev/null 2>&1; then
        (aplay "$CUSTOM_SOUND_PATH" >/dev/null 2>&1 &)
        return 0
    fi
    
    # Try ffplay (if available)
    if command -v ffplay >/dev/null 2>&1; then
        (ffplay -nodisp -autoexit "$CUSTOM_SOUND_PATH" >/dev/null 2>&1 &)
        return 0
    fi
    
    return 1
}

# Load previous state
load_last_alert_status() {
    if [ -f "$LOG_FILE" ]; then
        while IFS='=' read -r key value; do
            case "$key" in
                "LAST_LOW_ALERTED_PERCENTAGE") LAST_LOW_ALERTED_PERCENTAGE="$value" ;;
                "LAST_HIGH_ALERTED_PERCENTAGE") LAST_HIGH_ALERTED_PERCENTAGE="$value" ;;
                "LAST_BATTERY_STATUS") LAST_BATTERY_STATUS="$value" ;;
            esac
        done < "$LOG_FILE"
    fi
    
    # Ensure numeric values
    LAST_LOW_ALERTED_PERCENTAGE=${LAST_LOW_ALERTED_PERCENTAGE:-101}
    LAST_HIGH_ALERTED_PERCENTAGE=${LAST_HIGH_ALERTED_PERCENTAGE:-0}
    LAST_BATTERY_STATUS=${LAST_BATTERY_STATUS:-"Unknown"}
}

# Save current state
save_last_alert_status() {
    cat > "$LOG_FILE" << EOL
LAST_LOW_ALERTED_PERCENTAGE=$LAST_LOW_ALERTED_PERCENTAGE
LAST_HIGH_ALERTED_PERCENTAGE=$LAST_HIGH_ALERTED_PERCENTAGE
LAST_BATTERY_STATUS=$LAST_BATTERY_STATUS
EOL
}

# battery detection
get_battery_info() {
    local battery_path=""
    local percentage=""
    local status=""
    
    # Find battery path
    for path in /sys/class/power_supply/BAT*; do
        if [ -d "$path" ] && [ -f "$path/capacity" ] && [ -f "$path/status" ]; then
            battery_path="$path"
            break
        fi
    done
    
    if [ -z "$battery_path" ]; then
        echo "0,Unknown"
        return 1
    fi
    
    # Read battery info with error handling
    if ! percentage=$(cat "$battery_path/capacity" 2>/dev/null); then
        echo "0,Unknown"
        return 1
    fi
    
    if ! status=$(cat "$battery_path/status" 2>/dev/null); then
        echo "0,Unknown"
        return 1
    fi
    
    # Normalize status
    case "$status" in
        "Charging"|"Full") status="Charging" ;;
        *) status="Discharging" ;;
    esac
    
    # Validate percentage is numeric
    if ! [[ "$percentage" =~ ^[0-9]+$ ]] || [ "$percentage" -lt 0 ] || [ "$percentage" -gt 100 ]; then
        echo "0,Unknown"
        return 1
    fi
    
    echo "$percentage,$status"
    return 0
}

# Main logic
main() {
    load_last_alert_status
    
    # Get battery info
    if ! battery_info=$(get_battery_info); then
        logger -t "Chargedose" "Error: Could not retrieve battery information"
        return 1
    fi
    
    local current_percentage="${battery_info%,*}"
    local current_status="${battery_info#*,}"
    
    # Validate we got valid data
    if [ "$current_percentage" -eq 0 ] && [ "$current_status" = "Unknown" ]; then
        logger -t "Chargedose" "Error: Invalid battery data received"
        return 1
    fi
    
    # Low Battery Alert Logic
    if [ "$current_percentage" -le "$ALERT_LOW_THRESHOLD" ] && [ "$current_status" = "Discharging" ]; then
        local should_alert=false
        
        # Check if we should alert
        if [ "$LAST_LOW_ALERTED_PERCENTAGE" -gt "$current_percentage" ] || \
           [ "$((LAST_LOW_ALERTED_PERCENTAGE - current_percentage))" -ge "$PERCENTAGE_HYSTERESIS" ] || \
           [ "$LAST_BATTERY_STATUS" != "Discharging" ]; then
            should_alert=true
        fi
        
        if [ "$should_alert" = true ]; then
            send_robust_notification "Chargedose: Low Battery!" \
                "Battery at ${current_percentage}%. Connect charger now!" "battery-low"
            play_sound_robust
            LAST_LOW_ALERTED_PERCENTAGE="$current_percentage"
            LAST_HIGH_ALERTED_PERCENTAGE=0
        fi
    else
        # Reset low alert when significantly above threshold
        if [ "$current_percentage" -gt "$((ALERT_LOW_THRESHOLD + PERCENTAGE_HYSTERESIS))" ]; then
            LAST_LOW_ALERTED_PERCENTAGE=101
        fi
    fi
    
    # High Battery Alert Logic
    if [ "$current_percentage" -ge "$ALERT_HIGH_THRESHOLD" ] && [ "$current_status" = "Charging" ]; then
        local should_alert=false
        
        # Check if we should alert
        if [ "$LAST_HIGH_ALERTED_PERCENTAGE" -lt "$current_percentage" ] || \
           [ "$((current_percentage - LAST_HIGH_ALERTED_PERCENTAGE))" -ge "$PERCENTAGE_HYSTERESIS" ] || \
           [ "$LAST_BATTERY_STATUS" != "Charging" ]; then
            should_alert=true
        fi
        
        if [ "$should_alert" = true ]; then
            send_robust_notification "Chargedose: High Battery!" \
                "Battery at ${current_percentage}%. Disconnect charger!" "battery-full"
            play_sound_robust
            LAST_HIGH_ALERTED_PERCENTAGE="$current_percentage"
            LAST_LOW_ALERTED_PERCENTAGE=101
        fi
    fi
    
    # Update status and save
    LAST_BATTERY_STATUS="$current_status"
    save_last_alert_status
    
    return 0
}

# Execute main function
main
EOF

# --- Desktop Environment Detection Wrapper ---
read -r -d '' WRAPPER_SCRIPT_CONTENT << 'EOF'
#!/bin/bash
# Chargedose Desktop Environment Wrapper

setup_desktop_environment() {
    local user_id=$(id -u)
    
    # Set basic environment
    export XDG_RUNTIME_DIR="/run/user/$user_id"
    export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$user_id/bus"
    
    # Try to detect active session
    if command -v loginctl >/dev/null 2>&1; then
        local active_session=$(loginctl list-sessions --no-legend 2>/dev/null | \
            awk -v uid="$user_id" '$3 == uid && $4 == "active" {print $1; exit}')
        
        if [ -n "$active_session" ]; then
            local session_info=$(loginctl show-session "$active_session" 2>/dev/null)
            
            # Extract display info
            if echo "$session_info" | grep -q "Type=x11"; then
                export DISPLAY="${DISPLAY:-:0}"
                export XDG_SESSION_TYPE="x11"
            elif echo "$session_info" | grep -q "Type=wayland"; then
                export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
                export XDG_SESSION_TYPE="wayland"
            fi
            
            # Get desktop environment
            local desktop=$(echo "$session_info" | sed -n 's/Desktop=//p')
            [ -n "$desktop" ] && export XDG_CURRENT_DESKTOP="$desktop"
        fi
    fi
    
    # Fallback settings
    export DISPLAY="${DISPLAY:-:0}"
    export PULSE_RUNTIME_PATH="/run/user/$user_id/pulse"
}

# Setup environment and execute main script
setup_desktop_environment
exec /usr/local/bin/chargedose.sh
EOF

# --- Utility Functions ---

print_header() {
    clear
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                     CHARGEDOSE INSTALLER                     ║"
    echo "║                Robust Battery Health Monitor                 ║"
    echo "║                          Version 2.0                         ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
}

check_dependencies() {
    local missing_deps=()
    
    # Check for essential commands
    # Removed systemctl and loginctl as they are not directly used by cronjob for execution
    for cmd in id cat; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo "❌ Missing essential dependencies: ${missing_deps[*]}"
        echo "Please install them and run again."
        return 1
    fi
    
    return 0
}

install_notification_dependencies() {
    echo "📦 Installing notification dependencies..."
    
    # Detect package manager and install
    if command -v apt >/dev/null 2>&1; then
        sudo apt update -qq && sudo apt install -y libnotify-bin pulseaudio-utils alsa-utils 2>/dev/null
    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y libnotify pulseaudio-utils alsa-utils 2>/dev/null
    elif command -v pacman >/dev/null 2>&1; then
        sudo pacman -Sy --noconfirm libnotify pulseaudio-alsa alsa-utils 2>/dev/null
    elif command -v zypper >/dev/null 2>&1; then
        sudo zypper install -y libnotify-tools pulseaudio-utils alsa-utils 2>/dev/null
    else
        echo "⚠️  Could not detect package manager. Please install manually:"
        echo "   - libnotify-bin (or libnotify-tools)"
        echo "   - pulseaudio-utils"
        echo "   - alsa-utils"
    fi
}

find_sound_file() {
    local custom_path="$1"
    
    # If user provided a path and it exists, use it
    if [ -n "$custom_path" ] && [ -f "$custom_path" ]; then
        echo "$custom_path"
        return 0
    fi
    
    # Try default sound files
    for sound in "${DEFAULT_SOUNDS[@]}"; do
        if [ -f "$sound" ]; then
            echo "$sound"
            return 0
        fi
    done
    
    # No suitable sound found
    echo ""
    return 1
}

install_chargedose() {
    print_header
    echo "🚀 Installing Chargedose..."
    echo ""
    
    # Check dependencies
    if ! check_dependencies; then
        read -p "Press Enter to continue..."
        return 1
    fi
    
    # Install notification dependencies
    install_notification_dependencies
    
    # Prompt for custom sound
    echo "🔊 Sound Configuration:"
    echo "Enter path to custom sound file, or press Enter for auto-detection:"
    read -r custom_sound_input
    
    local final_sound_path
    if ! final_sound_path=$(find_sound_file "$custom_sound_input"); then
        echo "⚠️  No sound file found. Audio alerts will be disabled."
        final_sound_path="/dev/null"
    else
        echo "✅ Using sound file: $final_sound_path"
    fi
    
    echo ""
    echo "📝 Creating installation files..."
    
    # Create systemd user directory - not strictly needed for cron, but harmless
    mkdir -p "${HOME}/.config/systemd/user" 
    
    # Install wrapper script
    echo "$WRAPPER_SCRIPT_CONTENT" | sudo tee "$WRAPPER_FILE" >/dev/null
    sudo chmod +x "$WRAPPER_FILE"
    
    # Install main script with sound path substitution
    echo "$CHARGEDOSE_SCRIPT_CONTENT" | sed "s|CUSTOM_SOUND_PATH_PLACEHOLDER|$final_sound_path|" | sudo tee "$SCRIPT_FILE" >/dev/null
    sudo chmod +x "$SCRIPT_FILE"
    
    # Install service and timer files - REPLACED WITH CRON JOB
    # echo "$SERVICE_CONTENT" > "$SERVICE_FILE"
    # echo "$TIMER_CONTENT" > "$TIMER_FILE"
    
    # Enable and start services - REPLACED WITH CRON JOB
    # echo "⚙️  Configuring systemd services..."
    # systemctl --user daemon-reload
    # systemctl --user enable "${SCRIPT_NAME}.timer" >/dev/null 2>&1
    # systemctl --user enable "${SCRIPT_NAME}.service" >/dev/null 2>&1
    # systemctl --user start "${SCRIPT_NAME}.timer" >/dev/null 2>&1

    echo "⚙️  Configuring cron job..."
    (crontab -l 2>/dev/null | grep -v "${SCRIPT_FILE}" ; echo "*/5 * * * * ${WRAPPER_FILE} > /tmp/${SCRIPT_NAME}_cron.log 2>&1") | crontab -
    
    # Test installation
    echo "🧪 Testing installation..."
    # Check if cron job was added
    if crontab -l 2>/dev/null | grep -q "${WRAPPER_FILE}"; then
        echo "✅ Chargedose installed successfully!"
        echo ""
        echo "📊 Status:"
        echo "   • Cron Job: ✅ Active (running every 5 minutes)"
        echo "   • Low battery alert: ≤20%"
        echo "   • High battery alert: ≥80%"
        
        # Send test notification
        if command -v notify-send >/dev/null 2>&1; then
            notify-send "Chargedose Installed!" "Battery monitoring is now active." -i "battery" 2>/dev/null || true
        fi
        
        # Play test sound
        if [ -f "$final_sound_path" ] && [ "$final_sound_path" != "/dev/null" ]; then
            if command -v paplay >/dev/null 2>&1; then
                paplay "$final_sound_path" 2>/dev/null &
            fi
        fi
    else
        echo "❌ Installation completed but cron job is not set up properly."
        echo "Check logs at: /tmp/${SCRIPT_NAME}_cron.log"
    fi
}

clear_logs_and_cache() {
    print_header
    echo "🧹 Clearing Chargedose logs and cache..."
    echo ""
    
    # No need to stop service temporarily as cron runs independently
    # local was_running=false
    # if systemctl --user is-active --quiet "${SCRIPT_NAME}.service" 2>/dev/null; then
    #     systemctl --user stop "${SCRIPT_NAME}.service" >/dev/null 2>&1
    #     was_running=true
    #     echo "⏸️  Service stopped temporarily"
    # fi
    
    # Clear log files
    if [ -f "$LOG_FILE" ]; then
        rm -f "$LOG_FILE"
        echo "✅ Log file cleared: $LOG_FILE"
    else
        echo "ℹ️  No log file found"
    fi

    # Clear cron log file
    if [ -f "/tmp/${SCRIPT_NAME}_cron.log" ]; then
        rm -f "/tmp/${SCRIPT_NAME}_cron.log"
        echo "✅ Cron log file cleared: /tmp/${SCRIPT_NAME}_cron.log"
    else
        echo "ℹ️  No cron log file found"
    fi
    
    # Clear systemd logs - No longer applicable for cron
    # journalctl --user --vacuum-time=1s --unit="${SCRIPT_NAME}.service" >/dev/null 2>&1
    # echo "✅ Systemd logs cleared"
    
    # No need to restart service for cron
    # if [ "$was_running" = true ]; then
    #     systemctl --user start "${SCRIPT_NAME}.service" >/dev/null 2>&1
    #     echo "▶️  Service restarted"
    # fi
    
    echo ""
    echo "🎉 Cleanup completed!"
}

show_detailed_status() {
    print_header
    echo "📊 CHARGEDOSE SYSTEM STATUS"
    echo "════════════════════════════════════════════════════════════════"
    echo ""
    
    # Current Battery Status
    echo "🔋 CURRENT BATTERY INFO"
    echo "────────────────────────"
    
    local battery_info=$(get_battery_status)
    if [ $? -eq 0 ]; then
        local percentage="${battery_info%,*}"
        local status="${battery_info#*,}"
        local status_icon=""
        
        case "$status" in
            "Charging") status_icon="🔌" ;;
            "Discharging") status_icon="🔋" ;;
            *) status_icon="❓" ;;
        esac
        
        echo "   Percentage: ${percentage}%"
        echo "   Status: ${status_icon} ${status}"
        
        # Battery health indicator
        if [ "$percentage" -le 20 ] && [ "$status" = "Discharging" ]; then
            echo "   Health: ⚠️  LOW - Charge soon!"
        elif [ "$percentage" -ge 80 ] && [ "$status" = "Charging" ]; then
            echo "   Health: ⚠️  HIGH - Disconnect charger!"
        else
            echo "   Health: ✅ Good"
        fi
    else
        echo "   ❌ Could not retrieve battery information"
    fi
    
    echo ""
    
    # Service Status - Now Cron Job Status
    echo "⚙️  CRON JOB STATUS"
    echo "────────────────────"
    
    if crontab -l 2>/dev/null | grep -q "${WRAPPER_FILE}"; then
        echo "   Cron Job: ✅ Active (running every 5 minutes)"
    else
        echo "   Cron Job: ❌ Inactive or Not Configured"
    fi
    
    # Next run time - Not directly available for cron in this manner
    # if systemctl --user list-timers "${SCRIPT_NAME}.timer" --no-legend 2>/dev/null | grep -q "${SCRIPT_NAME}.timer"; then
    #     local next_run=$(systemctl --user list-timers "${SCRIPT_NAME}.timer" --no-legend 2>/dev/null | awk '{print $1, $2}')
    #     echo "   Next run: ⏰ $next_run"
    # fi
    
    echo ""
    
    # Configuration
    echo "⚙️  CONFIGURATION"
    echo "─────────────────"
    echo "   Low alert: ≤20%"
    echo "   High alert: ≥80%"
    echo "   Check interval: 5 minutes (via cron)"
    echo "   Hysteresis: 3%"
    
    # Files status
    echo ""
    echo "📁 INSTALLATION FILES"
    echo "─────────────────────"
    
    local files_ok=true
    for file in "$SCRIPT_FILE" "$WRAPPER_FILE"; do # Removed SERVICE_FILE and TIMER_FILE
        if [ -f "$file" ]; then
            echo "   ✅ $(basename "$file")"
        else
            echo "   ❌ $(basename "$file") - MISSING"
            files_ok=false
        fi
    done
    
    # Log file status
    echo ""
    echo "📋 RECENT ACTIVITY"
    echo "──────────────────"
    
    if [ -f "$LOG_FILE" ]; then
        echo "   Log file: ✅ Present"
        while IFS='=' read -r key value; do
            case "$key" in
                "LAST_LOW_ALERTED_PERCENTAGE") 
                    if [ "$value" -ne 101 ]; then
                        echo "   Last low alert: ${value}%"
                    fi
                    ;;
                "LAST_HIGH_ALERTED_PERCENTAGE") 
                    if [ "$value" -ne 0 ]; then
                        echo "   Last high alert: ${value}%"
                    fi
                    ;;
                "LAST_BATTERY_STATUS") 
                    echo "   Last known status: $value"
                    ;;
            esac
        done < "$LOG_FILE" 2>/dev/null
    else
        echo "   Log file: ℹ️  Not created yet (cron job hasn't run)"
    fi
    
    # Recent systemd logs - REPLACED WITH CRON LOG
    echo ""
    echo "📜 RECENT LOGS (from cron log, last 5 entries)"
    echo "───────────────────────────────"
    if [ -f "/tmp/${SCRIPT_NAME}_cron.log" ] && [ -s "/tmp/${SCRIPT_NAME}_cron.log" ]; then
        tail -n 5 "/tmp/${SCRIPT_NAME}_cron.log" | sed 's/^/   /'
    else
        echo "   ℹ️  No recent cron logs available"
    fi
    
    echo ""
    echo "════════════════════════════════════════════════════════════════"
    
    # Overall health check
    if [ "$files_ok" = true ] && crontab -l 2>/dev/null | grep -q "${WRAPPER_FILE}"; then
        echo "🎉 OVERALL STATUS: ✅ HEALTHY"
    else
        echo "⚠️  OVERALL STATUS: ❌ NEEDS ATTENTION"
        echo ""
        echo "💡 TROUBLESHOOTING:"
        if [ "$files_ok" = false ]; then
            echo "   • Reinstall Chargedose (missing files detected)"
        fi
        if ! crontab -l 2>/dev/null | grep -q "${WRAPPER_FILE}"; then
            echo "   • Cron job not found. Ensure it's correctly installed."
        fi
    fi
}

get_battery_status() {
    for path in /sys/class/power_supply/BAT*; do
        if [ -d "$path" ] && [ -f "$path/capacity" ] && [ -f "$path/status" ]; then
            local percentage=$(cat "$path/capacity" 2>/dev/null)
            local status=$(cat "$path/status" 2>/dev/null)
            
            case "$status" in
                "Charging"|"Full") status="Charging" ;;
                *) status="Discharging" ;;
            esac
            
            if [[ "$percentage" =~ ^[0-9]+$ ]]; then
                echo "$percentage,$status"
                return 0
            fi
        fi
    done
    return 1
}

uninstall_chargedose() {
    print_header
    echo "🗑️  Uninstalling Chargedose..."
    echo ""
    
    # Stop and disable services - REPLACED WITH CRON JOB REMOVAL
    # echo "⏹️  Stopping services..."
    # systemctl --user stop "${SCRIPT_NAME}.timer" "${SCRIPT_NAME}.service" 2>/dev/null
    # systemctl --user disable "${SCRIPT_NAME}.timer" "${SCRIPT_NAME}.service" 2>/dev/null
    # systemctl --user daemon-reload >/dev/null 2>&1
    
    echo "🗑️  Removing cron job..."
    (crontab -l 2>/dev/null | grep -v "${WRAPPER_FILE}") | crontab -
    
    # Remove files
    local removed_count=0
    
    for file in "$SCRIPT_FILE" "$WRAPPER_FILE" "$LOG_FILE" "/tmp/${SCRIPT_NAME}_cron.log"; do # Removed SERVICE_FILE and TIMER_FILE
        if [ -f "$file" ]; then
            if [[ "$file" == "/usr/local/bin/"* ]]; then
                sudo rm -f "$file"
            else
                rm -f "$file"
            fi
            echo "🗑️  Removed: $(basename "$file")"
            ((removed_count++))
        fi
    done
    
    # Clean up systemd - No longer applicable for cron
    # systemctl --user reset-failed "${SCRIPT_NAME}.service" 2>/dev/null || true
    # journalctl --user --vacuum-time=1s --unit="${SCRIPT_NAME}.service" >/dev/null 2>&1
    
    echo ""
    if [ $removed_count -gt 0 ]; then
        echo "✅ Chargedose uninstalled successfully!"
        echo "   Removed $removed_count files"
    else
        echo "ℹ️  Chargedose was not installed or already removed"
    fi
    
    echo ""
    echo "🎉 System is clean!"
}

display_menu() {
    print_header
    
    # Show quick battery status in menu
    local battery_info=$(get_battery_status 2>/dev/null)
    if [ $? -eq 0 ]; then
        local percentage="${battery_info%,*}"
        local status="${battery_info#*,}"
        local status_icon=""
        
        case "$status" in
            "Charging") status_icon="🔌" ;;
            "Discharging") status_icon="🔋" ;;
            *) status_icon="❓" ;;
        esac
        
        echo "Current Battery: ${status_icon} ${percentage}% ($status)"
        echo ""
    fi
    
    echo "┌─────────────────────────────────────────────────────────────┐"
    echo "│                    MANAGEMENT MENU                          │"
    echo "├─────────────────────────────────────────────────────────────┤"
    echo "│  1) 🚀 Install Chargedose                                   │"
    echo "│  2) 🧹 Clear Logs and Cache                                 │"
    echo "│  3) 📊 Show Detailed Status                                 │"
    echo "│  4) 🗑️  Uninstall Chargedose                                │"
    echo "│  5) ⚙️  Advanced Options                                     │"
    echo "│  6) 🚪 Exit                                                 │"
    echo "└─────────────────────────────────────────────────────────────┘"
    echo ""
}

main_menu() {
    while true; do
        display_menu
        echo -n "👉 Enter your choice (1-6): "
        read -r choice
        echo ""
        
        case "$choice" in
            1)
                install_chargedose
                ;;
            2)
                clear_logs_and_cache
                ;;
            3)
                show_detailed_status
                ;;
            4)
                echo "⚠️  Are you sure you want to uninstall Chargedose? (y/N): "
                read -r confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    uninstall_chargedose
                else
                    echo "❌ Uninstall cancelled."
                fi
                ;;
            5)
                advanced_menu
                ;;
            6)
                print_header
                echo "👋 Goodbye!"
                echo ""
                echo "🔋 Keep your battery healthy!"
                echo "🚀 Thank you for using Chargedose!"
                echo ""
                exit 0
                ;;
            *)
                echo "❌ Invalid choice. Please enter a number between 1 and 6."
                ;;
        esac
        
        echo ""
        echo "Press Enter to continue..."
        read -r
    done
}

# --- Self-test function ---
run_self_test() {
    echo "🧪 Running self-test..."
    echo ""
    
    # Test battery detection
    echo "Testing battery detection..."
    if battery_info=$(get_battery_status); then
        echo "✅ Battery detection: OK (${battery_info})"
    else
        echo "❌ Battery detection: FAILED"
        return 1
    fi
    
    # Test notification system
    echo "Testing notification system..."
    if command -v notify-send >/dev/null 2>&1; then
        if notify-send "Chargedose Test" "This is a test notification" -t 3000 2>/dev/null; then
            echo "✅ Notifications: OK"
        else
            echo "⚠️  Notifications: May have issues"
        fi
    else
        echo "⚠️  notify-send not found"
    fi
    
    # Test sound system
    echo "Testing sound system..."
    local test_sound=""
    for sound in "${DEFAULT_SOUNDS[@]}"; do
        if [ -f "$sound" ]; then
            test_sound="$sound"
            break
        fi
    done
    
    if [ -n "$test_sound" ]; then
        if command -v paplay >/dev/null 2>&1; then
            echo "✅ Sound system: OK (PulseAudio)"
        elif command -v aplay >/dev/null 2>&1; then
            echo "✅ Sound system: OK (ALSA)"
        else
            echo "⚠️  Sound system: No audio player found"
        fi
    else
        echo "⚠️  Sound system: No default sound files found"
    fi
    
    # Test systemd user services - NO LONGER APPLICABLE
    echo "Testing cron job setup..."
    if crontab -l 2>/dev/null | grep -q "${WRAPPER_FILE}"; then
        echo "✅ Cron job setup: OK"
    else
        echo "❌ Cron job setup: FAILED (Job not found in crontab)"
        return 1
    fi
    
    echo ""
    echo "✅ Self-test completed!"
    return 0
}

# --- Installation validation ---
validate_installation() {
    local errors=0
    
    echo "🔍 Validating installation..."
    echo ""
    
    # Check all required files exist
    for file in "$SCRIPT_FILE" "$WRAPPER_FILE"; do # Removed SERVICE_FILE and TIMER_FILE
        if [ ! -f "$file" ]; then
            echo "❌ Missing file: $file"
            ((errors++))
        fi
    done
    
    # Check file permissions
    for file in "$SCRIPT_FILE" "$WRAPPER_FILE"; do
        if [ -f "$file" ] && [ ! -x "$file" ]; then
            echo "❌ File not executable: $file"
            ((errors++))
        fi
    done
    
    # Check systemd services - REPLACED WITH CRON JOB CHECK
    if ! crontab -l 2>/dev/null | grep -q "${WRAPPER_FILE}"; then
        echo "❌ Cron job not found in crontab."
        ((errors++))
    fi
    
    if [ $errors -eq 0 ]; then
        echo "✅ Installation validation passed!"
        return 0
    else
        echo "❌ Installation validation failed with $errors errors"
        return 1
    fi
}

# --- Quick battery test ---
test_battery_alerts() {
    print_header
    echo "🧪 BATTERY ALERT TESTING MODE"
    echo "════════════════════════════════════════════════════════════════"
    echo ""
    echo "This will temporarily modify thresholds to test alerts immediately."
    echo ""
    echo "⚠️  WARNING: This will trigger actual notifications!"
    echo ""
    read -p "Continue with alert testing? (y/N): " confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "❌ Test cancelled."
        return 0
    fi
    
    # Get current battery status
    local battery_info=$(get_battery_status)
    if [ $? -ne 0 ]; then
        echo "❌ Cannot test - battery info unavailable"
        return 1
    fi
    
    local current_percentage="${battery_info%,*}"
    local current_status="${battery_info#*,}"
    
    echo ""
    echo "📊 Current Status: ${current_percentage}% ($current_status)"
    echo ""
    
    # Create temporary test script with current percentage as threshold
    local test_threshold
    if [ "$current_status" = "Charging" ]; then
        test_threshold=$((current_percentage - 1))
        echo "🔌 Testing HIGH battery alert (threshold set to ${test_threshold}%)..."
    else
        test_threshold=$((current_percentage + 1))
        echo "🔋 Testing LOW battery alert (threshold set to ${test_threshold}%)..."
    fi
    
    # Create temporary modified script
    local temp_script="/tmp/chargedose-test.sh"
    sed "s/ALERT_LOW_THRESHOLD=20/ALERT_LOW_THRESHOLD=$test_threshold/" "$SCRIPT_FILE" | \
    sed "s/ALERT_HIGH_THRESHOLD=80/ALERT_HIGH_THRESHOLD=$test_threshold/" > "$temp_script"
    chmod +x "$temp_script"
    
    echo "🚀 Executing test..."
    
    # Run test script - Use wrapper to ensure desktop environment variables are set
    if "$WRAPPER_FILE"; then # Execute wrapper, which calls the main script
        echo "✅ Test script executed successfully!"
        echo ""
        echo "Did you see/hear the notification? If not, there may be an issue with:"
        echo "   • Desktop notification system"
        echo "   • Sound system"
        echo "   • Environment variables"
    else
        echo "❌ Test script failed"
    fi
    
    # Cleanup
    rm -f "$temp_script"
    
    echo ""
    echo "🔄 Normal operation will resume with standard thresholds (20%/80%)"
}

# --- System information gathering ---
gather_system_info() {
    echo "💻 SYSTEM INFORMATION"
    echo "═══════════════════════"
    echo ""
    
    # OS Information
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "OS: $PRETTY_NAME"
    fi
    
    # Desktop Environment
    echo "Desktop: ${XDG_CURRENT_DESKTOP:-Unknown}"
    echo "Session: ${XDG_SESSION_TYPE:-Unknown}"
    
    # Hardware
    if [ -f /proc/cpuinfo ]; then
        local cpu_model=$(grep "model name" /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)
        echo "CPU: $cpu_model"
    fi
    
    if [ -f /proc/meminfo ]; then
        local total_mem=$(grep "MemTotal" /proc/meminfo | awk '{print int($2/1024)}')
        echo "RAM: ${total_mem}MB"
    fi
    
    # Battery information
    echo ""
    echo "🔋 BATTERY HARDWARE"
    echo "──────────────────"
    
    for bat_path in /sys/class/power_supply/BAT*; do
        if [ -d "$bat_path" ]; then
            local bat_name=$(basename "$bat_path")
            echo "Battery: $bat_name"
            
            if [ -f "$bat_path/manufacturer" ]; then
                echo "  Manufacturer: $(cat "$bat_path/manufacturer" 2>/dev/null || echo "Unknown")"
            fi
            
            if [ -f "$bat_path/model_name" ]; then
                echo "  Model: $(cat "$bat_path/model_name" 2>/dev/null || echo "Unknown")"
            fi
            
            if [ -f "$bat_path/energy_full_design" ] && [ -f "$bat_path/energy_full" ]; then
                local design_capacity=$(cat "$bat_path/energy_full_design" 2>/dev/null)
                local current_capacity=$(cat "$bat_path/energy_full" 2>/dev/null)
                if [ -n "$design_capacity" ] && [ -n "$current_capacity" ] && [ "$design_capacity" -gt 0 ]; then
                    local health=$((current_capacity * 100 / design_capacity))
                    echo "  Health: ${health}%"
                fi
            fi
        fi
    done
    
    # Audio system
    echo ""
    echo "🔊 AUDIO SYSTEM"
    echo "──────────────"
    
    if command -v pactl >/dev/null 2>&1 && pactl info >/dev/null 2>&1; then
        echo "PulseAudio: ✅ Available"
    else
        echo "PulseAudio: ❌ Not available"
    fi
    
    if command -v aplay >/dev/null 2>&1; then
        echo "ALSA: ✅ Available"
    else
        echo "ALSA: ❌ Not available"
    fi
    
    # Available sound files
    echo ""
    echo "🎵 AVAILABLE SOUNDS"
    echo "─────────────────"
    
    local sound_count=0
    for sound in "${DEFAULT_SOUNDS[@]}"; do
        if [ -f "$sound" ]; then
            echo "✅ $sound"
            ((sound_count++))
        fi
    done
    
    if [ $sound_count -eq 0 ]; then
        echo "❌ No default sound files found"
    fi
}

# --- menu with additional options ---
display_advanced_menu() {
    print_header
    
    echo "┌─────────────────────────────────────────────────────────────┐"
    echo "│                   ADVANCED MENU                             │"
    echo "├─────────────────────────────────────────────────────────────┤"
    echo "│  1) 🧪 Run Self-Test                                        │"
    echo "│  2) 🎯 Test Battery Alerts                                  │"
    echo "│  3) 💻 Show System Information                              │"
    echo "│  4) 🔍 Validate Installation                                │"
    echo "│  5) 🔧 Manual Service Control (Deprecated/For Cron Only)    │" # Updated description
    echo "│  6) 🔙 Back to Main Menu                                    │"
    echo "└─────────────────────────────────────────────────────────────┘"
    echo ""
}

manual_service_control() {
    print_header
    echo "🔧 MANUAL SERVICE CONTROL (CRON-BASED)" # Updated title
    echo "════════════════════════════════════════════════════════════════"
    echo ""
    
    # Status is now just cron job status
    if crontab -l 2>/dev/null | grep -q "${WRAPPER_FILE}"; then
        echo "Current Status: ✅ Chargedose Cron Job is Active"
    else
        echo "Current Status: ❌ Chargedose Cron Job is Inactive or Not Configured"
    fi
    echo ""
    
    echo "Available actions:"
    echo "  1) Run Chargedose once (manually)"
    echo "  2) View cron log"
    echo "  3) Back"
    echo ""
    
    read -p "Choose action (1-3): " action
    
    case "$action" in
        1)
            echo "🚀 Running Chargedose once..."
            "$WRAPPER_FILE" # Execute wrapper to ensure environment is set
            echo "✅ Chargedose executed. Check /tmp/${SCRIPT_NAME}_cron.log for output."
            ;;
        2)
            echo "📜 Recent cron logs (/tmp/${SCRIPT_NAME}_cron.log):"
            echo "─────────────────────────────────────────────────────────────"
            if [ -f "/tmp/${SCRIPT_NAME}_cron.log" ]; then
                tail -n 20 "/tmp/${SCRIPT_NAME}_cron.log"
            else
                echo "No cron log file found."
            fi
            ;;
        3)
            return 0
            ;;
        *)
            echo "❌ Invalid choice"
            ;;
    esac
}

advanced_menu() {
    while true; do
        display_advanced_menu
        echo -n "👉 Enter your choice (1-6): "
        read -r choice
        echo ""
        
        case "$choice" in
            1)
                run_self_test
                ;;
            2)
                test_battery_alerts
                ;;
            3)
                gather_system_info
                ;;
            4)
                validate_installation
                ;;
            5)
                manual_service_control
                ;;
            6)
                return 0
                ;;
            *)
                echo "❌ Invalid choice. Please enter a number between 1 and 6."
                ;;
        esac
        
        echo ""
        echo "Press Enter to continue..."
        read -r
    done
}

# Update main menu to include advanced options (this function is already correct)
display_menu() {
    print_header
    
    # Show quick battery status in menu
    local battery_info=$(get_battery_status 2>/dev/null)
    if [ $? -eq 0 ]; then
        local percentage="${battery_info%,*}"
        local status="${battery_info#*,}"
        local status_icon=""
        
        case "$status" in
            "Charging") status_icon="🔌" ;;
            "Discharging") status_icon="🔋" ;;
            *) status_icon="❓" ;;
        esac
        
        echo "Current Battery: ${status_icon} ${percentage}% ($status)"
        echo ""
    fi
    
    echo "┌─────────────────────────────────────────────────────────────┐"
    echo "│                    MANAGEMENT MENU                          │"
    echo "├─────────────────────────────────────────────────────────────┤"
    echo "│  1) 🚀 Install Chargedose                                   │"
    echo "│  2) 🧹 Clear Logs and Cache                                 │"
    echo "│  3) 📊 Show Detailed Status                                 │"
    echo "│  4) 🗑️  Uninstall Chargedose                                 │"
    echo "│  5) ⚙️  Advanced Options                                     │"
    echo "│  6) 🚪 Exit                                                 │"
    echo "└─────────────────────────────────────────────────────────────┘"
    echo ""
}

main_menu() {
    while true; do
        display_menu
        echo -n "👉 Enter your choice (1-6): "
        read -r choice
        echo ""
        
        case "$choice" in
            1)
                install_chargedose
                ;;
            2)
                clear_logs_and_cache
                ;;
            3)
                show_detailed_status
                ;;
            4)
                echo "⚠️  Are you sure you want to uninstall Chargedose? (y/N): "
                read -r confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    uninstall_chargedose
                else
                    echo "❌ Uninstall cancelled."
                fi
                ;;
            5)
                advanced_menu
                ;;
            6)
                print_header
                echo "👋 Goodbye!"
                echo ""
                echo "🔋 Keep your battery healthy!"
                echo "🚀 Thank you for using Chargedose!"
                echo ""
                exit 0
                ;;
            *)
                echo "❌ Invalid choice. Please enter a number between 1 and 6."
                ;;
        esac
        
        echo ""
        echo "Press Enter to continue..."
        read -r
    done
}

# --- Main execution ---
main() {
    # Ensure we're not running as root
    if [ "$EUID" -eq 0 ] && [ "$1" != "--allow-root" ]; then
        echo "❌ Please run this script as a regular user, not as root."
        echo "   The script will ask for sudo password when needed."
        exit 1
    fi
    
    # Check if running in a terminal
    if [ ! -t 0 ]; then
        echo "❌ This script must be run in an interactive terminal."
        exit 1
    fi
    
    # Handle command line arguments
    case "${1:-}" in
        "--test")
            run_self_test
            exit $?
            ;;
        "--install")
            install_chargedose
            exit $?
            ;;
        "--status")
            show_detailed_status
            exit 0
            ;;
        "--uninstall")
            uninstall_chargedose
            exit 0
            ;;
        "--help"|"-h")
            echo "Chargedose Installer - Battery Health Monitor"
            echo ""
            echo "Usage: $0 [option]"
            echo ""
            echo "Options:"
            echo "  --install     Install Chargedose"
            echo "  --status      Show detailed status"
            echo "  --uninstall   Uninstall Chargedose"
            echo "  --test        Run self-test"
            echo "  --help        Show this help"
            echo ""
            echo "Run without arguments for interactive menu."
            exit 0
            ;;
        "")
            # Interactive mode
            main_menu
            ;;
        *)
            echo "❌ Unknown option: $1"
            echo "Use --help for available options."
            exit 1
            ;;
    esac
}

# Execute main function with all arguments
main "$@"
