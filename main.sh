#!/bin/bash

# Define colors for better terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[0;37m'
RESET='\033[0m' # No Color
BOLD_GREEN='\033[1;32m' # Bold Green for menu title


if [[ "${BASH_SOURCE[0]}" =~ ^/dev/fd/ ]] || [[ "${BASH_SOURCE[0]}" =~ ^/proc/ ]]; then
    FRP_SCRIPT_PATH="$(pwd)/main.sh"
else
    FRP_SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
fi
SCRIPT_DIR="$(dirname "$FRP_SCRIPT_PATH")"
SETUP_MARKER_FILE="/var/lib/frp/.setup_complete"
FRP_COMMAND_PATH="/usr/local/bin/frp"

# --- Basic Functions ---

# Function to clean old proxy configurations
clean_old_proxy_configs() {
    [ ! -f "$1" ] && return 1
    echo -e "${CYAN}🧹 Cleaning old proxy configurations...${RESET}"
    sed -i '/transport.useEncryption\|transport.useCompression\|healthCheck/d' "$1"
    print_success "Proxy configurations cleaned!"
}

# Function to create high-performance frp server configuration (TOML format)
create_server_config() {
    local config_file="$1" listen_port="$2" auth_token="$3"
    
    cat <<EOF > "$config_file"
bindAddr = "0.0.0.0"
bindPort = $listen_port
kcpBindPort = $listen_port
quicBindPort = $((listen_port + 2))
maxPortsPerClient = 0
userConnTimeout = 10

auth.method = "token"
auth.token = "$auth_token"

webServer.addr = "0.0.0.0"
webServer.port = $((listen_port + 1))
webServer.user = "admin"
webServer.password = "$auth_token"

log.to = "/var/log/frps_${listen_port}.log"
log.level = "warn"
log.maxDays = 3

transport.tcpMux = true
transport.tcpMuxKeepaliveInterval = 20
transport.maxPoolCount = 50
transport.tcpKeepalive = 7200
EOF
}

# Function to create high-performance frp client configuration (TOML format)
create_client_config() {
    local config_file="$1" server_addr="$2" password="$3" client_name="$4" protocol="${5:-tcp}"
    local server_host=$(echo "$server_addr" | cut -d':' -f1)
    local server_port=$(echo "$server_addr" | cut -d':' -f2)
    local admin_port=$((7400 + $(echo "$client_name" | cksum | cut -d' ' -f1) % 1000))
    
    cat <<EOF > "$config_file"
user = "$client_name"
serverAddr = "$server_host"
serverPort = $server_port
loginFailExit = false

auth.method = "token"
auth.token = "$password"

log.to = "/var/log/frpc_${client_name}.log"
log.level = "info"
log.maxDays = 3

transport.protocol = "$protocol"
transport.poolCount = 16
transport.tcpMux = true
transport.tcpMuxKeepaliveInterval = 20
transport.dialServerTimeout = 10
transport.dialServerKeepalive = 7200
transport.heartbeatInterval = 30
transport.heartbeatTimeout = 90

webServer.addr = "127.0.0.1"
webServer.port = $admin_port
webServer.user = "admin"
webServer.password = "$password"
EOF
}

# Hot-reloading functions for FRP v0.63.0
hot_reload_client() {
    local client_name="$1"
    local config_file="/root/rstun/frpc_${client_name}.toml"
    
    if [ ! -f "$config_file" ]; then
        print_error "Configuration file not found: $config_file"
        return 1
    fi
    
    echo -e "${CYAN}🔄 Hot-reloading client '$client_name'...${RESET}"
    
    # Verify configuration first
    echo -e "${CYAN}🔍 Verifying configuration...${RESET}"
    if ! /root/rstun/frpc verify -c "$config_file" >/dev/null 2>&1; then
        print_error "Configuration verification failed! Please check your config file."
        echo -e "${YELLOW}You can run: /root/rstun/frpc verify -c $config_file${RESET}"
        return 1
    fi
    
    echo -e "${GREEN}✅ Configuration verified successfully${RESET}"
    
    # Perform hot-reload using official FRP command
    echo -e "${CYAN}🔄 Performing hot-reload...${RESET}"
    if /root/rstun/frpc reload -c "$config_file" >/dev/null 2>&1; then
        echo -e "${GREEN}✅ Waiting for changes to take effect (10 seconds)...${RESET}"
        sleep 10
        print_success "Client '$client_name' reloaded successfully!"
        return 0
    else
        print_error "Hot-reload failed! Please check the configuration or service status."
        return 1
    fi
}

# Function to add ports to existing client without restart
add_ports_to_client() {
    local client_name="$1"
    local new_ports="$2"
    local tunnel_mode="$3"
    local config_file="/root/rstun/frpc_${client_name}.toml"
    
    if [ ! -f "$config_file" ]; then
        print_error "Client '$client_name' not found!"
        return 1
    fi
    
    # Parse new ports
    local ports_array=()
    if ! parse_ports "$new_ports" ports_array; then
        print_error "Invalid port format!"
        return 1
    fi
    
    echo -e "${CYAN}🔧 Adding ${#ports_array[@]} ports to client '$client_name'...${RESET}"
    
    # Add new port configurations
    for port in "${ports_array[@]}"; do
        # Check if port already exists
        if grep -q "name = \"tcp_$port\"" "$config_file" || grep -q "name = \"udp_$port\"" "$config_file"; then
            echo -e "${YELLOW}⚠️ Port $port already exists, skipping...${RESET}"
            continue
        fi
        
        if [[ "$tunnel_mode" == "tcp" || "$tunnel_mode" == "both" ]]; then
            cat <<EOF >> "$config_file"
[[proxies]]
name = "tcp_$port"
type = "tcp"
localIP = "127.0.0.1"
localPort = $port
remotePort = $port

EOF
        fi
        
        if [[ "$tunnel_mode" == "udp" || "$tunnel_mode" == "both" ]]; then
            cat <<EOF >> "$config_file"
[[proxies]]
name = "udp_$port"
type = "udp"
localIP = "127.0.0.1"
localPort = $port
remotePort = $port

EOF
        fi
    done
    
    # Try hot-reload first, if it fails, restart the service
    echo -e "${CYAN}🔄 Attempting hot-reload...${RESET}"
    if ! hot_reload_client "$client_name"; then
        echo -e "${YELLOW}⚠️ Hot-reload failed, restarting service...${RESET}"
        sudo systemctl restart "frp-client-$client_name"
        
        # Wait for service to start
        sleep 3
        
        # Check if service is running
        if systemctl is-active --quiet "frp-client-$client_name"; then
            print_success "Service restarted successfully!"
        else
            print_error "Service restart failed!"
            return 1
        fi
    fi
    
    # Verify ports were added
    echo -e "${CYAN}✅ Verifying added ports...${RESET}"
    list_client_ports "$client_name"
}

# Function to remove ports from existing client without restart
remove_ports_from_client() {
    local client_name="$1"
    local remove_ports="$2"
    local config_file="/root/rstun/frpc_${client_name}.toml"
    
    if [ ! -f "$config_file" ]; then
        print_error "Client '$client_name' not found!"
        return 1
    fi
    
    # Parse ports to remove
    local ports_array=()
    if ! parse_ports "$remove_ports" ports_array; then
        print_error "Invalid port format!"
        return 1
    fi
    
    echo -e "${CYAN}🗑️ Removing ${#ports_array[@]} ports from client '$client_name'...${RESET}"
    
    # Remove port configurations
    for port in "${ports_array[@]}"; do
        # Remove TCP proxy
        sed -i "/^\[\[proxies\]\]$/,/^$/{ /name = \"tcp_$port\"/,/^$/d; }" "$config_file"
        # Remove UDP proxy
        sed -i "/^\[\[proxies\]\]$/,/^$/{ /name = \"udp_$port\"/,/^$/d; }" "$config_file"
    done
    
    # Hot-reload the client
    hot_reload_client "$client_name"
}

# Function to list client ports
list_client_ports() {
    local client_name="$1"
    local config_file="/root/rstun/frpc_${client_name}.toml"
    
    if [ ! -f "$config_file" ]; then
        print_error "Client '$client_name' not found!"
        return 1
    fi
    
    echo -e "${CYAN}📋 Active ports for client '$client_name':${RESET}"
    
    # Extract and display ports
    local tcp_ports=$(grep -A 10 '\[\[proxies\]\]' "$config_file" | grep 'name = "tcp_' | sed 's/.*tcp_\([0-9]*\)".*/\1/' | sort -n)
    local udp_ports=$(grep -A 10 '\[\[proxies\]\]' "$config_file" | grep 'name = "udp_' | sed 's/.*udp_\([0-9]*\)".*/\1/' | sort -n)
    
    if [ -n "$tcp_ports" ]; then
        echo -e "${GREEN}🔗 TCP Ports:${RESET} $(echo $tcp_ports | tr '\n' ' ')"
    fi
    
    if [ -n "$udp_ports" ]; then
        echo -e "${BLUE}📡 UDP Ports:${RESET} $(echo $udp_ports | tr '\n' ' ')"
    fi
    
    # Count total ports
    local total_tcp=$(echo "$tcp_ports" | wc -w)
    local total_udp=$(echo "$udp_ports" | wc -w)
    local total=$((total_tcp + total_udp))
    
    echo -e "${WHITE}📊 Total: $total ports ($total_tcp TCP, $total_udp UDP)${RESET}"
}

# Function to get health status of client
get_client_health() {
    local client_name="$1"
    local config_file="/root/rstun/frpc_${client_name}.toml"
    
    if [ ! -f "$config_file" ]; then
        print_error "Client '$client_name' not found!"
        return 1
    fi
    
    echo -e "${CYAN}🏥 Checking health of client '$client_name'...${RESET}"
    
    # Check if service is running
    if ! systemctl is-active --quiet "frp-client-$client_name"; then
        echo -e "${RED}❌ Service is not running${RESET}"
        return 1
    fi
    
    # Verify configuration
    if ! /root/rstun/frpc verify -c "$config_file" >/dev/null 2>&1; then
        echo -e "${RED}❌ Configuration has errors${RESET}"
        return 1
    fi
    
    # Check recent logs for errors
    local recent_errors=$(sudo journalctl -u "frp-client-$client_name" -n 20 --no-pager | grep -i error | wc -l)
    
    if [ "$recent_errors" -gt 0 ]; then
        echo -e "${YELLOW}⚠️ Found $recent_errors recent errors in logs${RESET}"
        echo -e "${YELLOW}Use 'Show Client Log' to see details${RESET}"
        return 1
    fi
    
    echo -e "${GREEN}✅ Client '$client_name' is healthy${RESET}"
    echo -e "${WHITE}  • Service: Running${RESET}"
    echo -e "${WHITE}  • Config: Valid${RESET}"
    echo -e "${WHITE}  • Logs: No recent errors${RESET}"
    return 0
}

# Protocol Selection Functions
get_protocol_selection() {
    echo -e "${CYAN}🌐 Select Connection Protocol:${RESET}"
    echo -e "  ${WHITE}1)${RESET} ${GREEN}TCP${RESET} - Traditional, reliable"
    echo -e "  ${WHITE}2)${RESET} ${YELLOW}QUIC${RESET} - Fast, modern (UDP-based)"
    echo -e "  ${WHITE}3)${RESET} ${BLUE}KCP${RESET} - Low latency (UDP-based)"
    echo -e "  ${WHITE}4)${RESET} ${MAGENTA}WebSocket${RESET} - Firewall-friendly"
}

# Function to validate protocol support
validate_protocol() {
    local protocol="$1"
    
    case "$protocol" in
        "tcp"|"quic"|"kcp"|"websocket")
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Function to update client protocol without restart
update_client_protocol() {
    local client_name="$1"
    local new_protocol="$2"
    local config_file="/root/rstun/frpc_${client_name}.toml"
    
    if [ ! -f "$config_file" ]; then
        print_error "Client '$client_name' not found!"
        return 1
    fi
    
    if ! validate_protocol "$new_protocol"; then
        print_error "Invalid protocol: $new_protocol"
        return 1
    fi
    
    # Get current protocol
    local current_protocol=$(grep 'transport.protocol = ' "$config_file" | cut -d'"' -f2)
    
    if [ "$current_protocol" = "$new_protocol" ]; then
        print_success "Protocol is already set to $new_protocol"
        return 0
    fi
    
    echo -e "${CYAN}🔧 Updating client '$client_name' from '$current_protocol' to '$new_protocol'...${RESET}"
    
    local current_server_port=$(grep 'serverPort = ' "$config_file" | cut -d' ' -f3)
    local new_server_port=$current_server_port
    
    if [ "$current_protocol" = "quic" ] && [ "$new_protocol" != "quic" ]; then
        new_server_port=$((current_server_port - 2))
    elif [ "$current_protocol" != "quic" ] && [ "$new_protocol" = "quic" ]; then
        new_server_port=$((current_server_port + 2))
    fi
    
    sed -i "s/transport.protocol = \".*\"/transport.protocol = \"$new_protocol\"/" "$config_file"
    sed -i "s/serverPort = .*/serverPort = $new_server_port/" "$config_file"
    
    print_success "Protocol updated to $new_protocol"
    
    echo -e "${CYAN}🔄 Restarting service for protocol change...${RESET}"
    sudo systemctl restart "frp-client-$client_name"
    
    sleep 3
    
    if systemctl is-active --quiet "frp-client-$client_name"; then
        print_success "Service restarted successfully with new protocol!"
    else
        print_error "Service restart failed!"
        return 1
    fi
}

# --- Helper Functions ---

# Function to draw a colored line for menu separation
draw_line() {
  local color="$1"
  local char="$2"
  local length=${3:-40} # Default length 40 if not provided
  printf "${color}"
  for ((i=0; i<length; i++)); do
    printf "$char"
  done
  printf "${RESET}\n"
}

# Function to print success messages in green
print_success() {
  local message="$1"
  echo -e "\033[0;32m✅ $message\033[0m" # Green color for success messages
}

# Function to print error messages in red
print_error() {
  local message="$1"
  echo -e "\033[0;31m❌ $message\033[0m" # Red color for error messages
}

# Function to show service logs and return to a "menu"
show_service_logs() {
  local service_name="$1"
  clear # Clear the screen before showing logs
  echo -e "\033[0;34m--- Displaying logs for $service_name ---\033[0m" # Blue color for header

  # Display the last 50 lines of logs for the specified service
  # --no-pager ensures the output is direct to the terminal without opening 'less'
  sudo journalctl -u "$service_name" -n 50 --no-pager

  echo ""
  echo -e "\033[1;33mPress any key to return to the previous menu...\033[0m" # Yellow color for prompt
  read -n 1 -s -r # Read a single character, silent, raw input

  clear
}

# Function to draw a green line (used for main menu border)
draw_green_line() {
  echo -e "${GREEN}+--------------------------------------------------------+${RESET}"
}

# --- Validation Functions ---

# Function to validate an email address
validate_email() {
  [[ "$1" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,4}$ ]]
}

validate_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 ))
}

validate_host() {
  local ip_regex="^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$"
  local domain_regex="^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,6}$"
  [[ "$1" =~ $ip_regex ]] || [[ "$1" =~ $domain_regex ]]
}

# --- Function to ensure 'frp' command symlink exists ---
ensure_frp_command_available() {
  echo -e "${CYAN}Checking 'frp' command symlink status...${RESET}"
  local current_symlink_target=$(readlink "$FRP_COMMAND_PATH" 2>/dev/null)
  
  if [[ "$current_symlink_target" == /dev/fd/* ]]; then
    print_error "❌ Warning: The existing 'frp' symlink points to a temporary location ($current_symlink_target)."
    print_error "   Attempting to fix it by recreating the symlink to the permanent script path."
  fi

  mkdir -p "$(dirname "$FRP_COMMAND_PATH")"
  if ln -sf "$FRP_SCRIPT_PATH" "$FRP_COMMAND_PATH" && [ -L "$FRP_COMMAND_PATH" ] && [ "$(readlink "$FRP_COMMAND_PATH" 2>/dev/null)" = "$FRP_SCRIPT_PATH" ]; then
    print_success "'frp' command symlink is correctly set up."
    return 0
  else
    print_error "❌ Critical Error: The 'frp' command symlink is not properly set up or accessible."
    return 1
  fi
}

# --- New: delete_cron_job_action to remove scheduled restarts ---
delete_cron_job_action() {
  clear
  echo ""
  draw_line "$RED" "=" 40
  echo -e "${RED} 🗑️ Delete Scheduled Restart (Cron)${RESET}"
  draw_line "$RED" "=" 40
  echo ""

  echo -e "${CYAN}🔍 Searching for FRP related services with scheduled restarts...${RESET}"

  # List active FRP related services (both server and clients)
  mapfile -t services_with_cron < <(sudo crontab -l 2>/dev/null | grep "# FRP automated restart for" | awk '{print $NF}' | sort -u)

  # Extract service names from the cron job comments
  local service_names=()
  for service_comment in "${services_with_cron[@]}"; do
    # The service name is the last word in the comment, which is the service name itself
    # We need to strip the "# FRP automated restart for " part
    local extracted_name=$(echo "$service_comment" | sed 's/# FRP automated restart for //')
    service_names+=("$extracted_name")
  done

  if [ ${#service_names[@]} -eq 0 ]; then
    print_error "No FRP services with scheduled cron jobs found."
    echo -e "${YELLOW}Press Enter to return to previous menu...${RESET}"
    read -p ""
    return 1
  fi

  echo -e "${CYAN}📋 Please select a service to delete its scheduled restart:${RESET}"
  # Add a "Back to previous menu" option
  service_names+=("Back to previous menu")
  select selected_service_name in "${service_names[@]}"; do
    if [[ "$selected_service_name" == "Back to previous menu" ]]; then
      echo -e "${YELLOW}Returning to previous menu...${RESET}"
      echo ""
      return 0
    elif [ -n "$selected_service_name" ]; then
      break # Exit the select loop if a valid option is chosen
    else
      print_error "Invalid selection. Please enter a valid number."
    fi
  done
  echo ""

  if [[ -z "$selected_service_name" ]]; then
    print_error "No service selected. Aborting."
    echo -e "${YELLOW}Press Enter to return to previous menu...${RESET}"
    read -p ""
    return 1
  fi

  echo -e "${CYAN}Attempting to delete cron job for '$selected_service_name'...${RESET}"

  # --- Start of improved cron job management for deletion ---
  local temp_cron_file=$(mktemp)
  if ! sudo crontab -l &> /dev/null; then
      # If crontab is empty or doesn't exist, nothing to delete
      print_error "Crontab is empty or not accessible. Nothing to delete."
      rm -f "$temp_cron_file"
      echo ""
      echo -e "${YELLOW}Press Enter to return to previous menu...${RESET}"
      read -p ""
      return 1
  fi
  sudo crontab -l > "$temp_cron_file"

  # Remove the cron job for the selected service using the unique identifier
  sed -i "/# FRP automated restart for $selected_service_name$/d" "$temp_cron_file"

  # Load the modified crontab
  if sudo crontab "$temp_cron_file"; then
    print_success "Successfully removed scheduled restart for '$selected_service_name'."
    echo -e "${WHITE}You can verify with: ${YELLOW}sudo crontab -l${RESET}"
  else
    print_error "Failed to delete cron job. It might not exist or there's a permission issue."
  fi

  # Clean up the temporary file
  rm -f "$temp_cron_file"
  # --- End of improved cron job management ---

  echo ""
  echo -e "${YELLOW}Press Enter to return to previous menu...${RESET}"
  read -p ""
}

# --- Uninstall FRP Action ---
uninstall_frp_action() {
  clear
  echo ""
  echo -e "${RED}⚠️ Are you sure you want to uninstall FRP and remove all associated files and services? (y/N): ${RESET}"
  read -p "" confirm
  echo ""

  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    echo "🧹 Uninstalling FRP..."

    # --- Handle all frp-server-* services ---
    echo "🔍 Searching for FRP server services..."
    mapfile -t frp_server_services < <(sudo systemctl list-unit-files --full --no-pager | grep '^frp-server-.*\.service' | awk '{print $1}')

    if [ ${#frp_server_services[@]} -gt 0 ]; then
      echo "🛑 Stopping and disabling FRP server services..."
      for service_file in "${frp_server_services[@]}"; do
        local service_name=$(basename "$service_file")
        echo "  - Processing $service_name..."
        sudo systemctl stop "$service_name" > /dev/null 2>&1
        sudo systemctl disable "$service_name" > /dev/null 2>&1
        sudo rm -f "/etc/systemd/system/$service_name" > /dev/null 2>&1
      done
      print_success "All FRP server services have been stopped, disabled, and removed."
    else
      echo "⚠️ No FRP server services found to remove."
    fi

    echo "Searching for FRP client services to remove..."
    mapfile -t frp_client_services < <(sudo systemctl list-unit-files --full --no-pager | grep '^frp-client-.*\.service' | awk '{print $1}')

    if [ ${#frp_client_services[@]} -gt 0 ]; then
      echo "🛑 Stopping and disabling FRP client services..."
      for service_file in "${frp_client_services[@]}"; do
        local service_name=$(basename "$service_file")
        echo "  - Processing $service_name..."
        sudo systemctl stop "$service_name" > /dev/null 2>&1
        sudo systemctl disable "$service_name" > /dev/null 2>&1
        sudo rm -f "/etc/systemd/system/$service_name" > /dev/null 2>&1
      done
      print_success "All FRP client services have been stopped, disabled, and removed."
    else
      echo "⚠️ No FRP client services found to remove."
    fi

    sudo systemctl daemon-reload

    # Remove rstun folder if exists
    if [ -d "rstun" ]; then
      echo "🗑️ Removing 'rstun' folder..."
      rm -rf rstun
      print_success "'rstun' folder removed successfully."
    else
      echo "⚠️ 'rstun' folder not found."
    fi

    # Remove all FRP logs and configs
    echo -e "${CYAN}🧹 Removing all FRP logs and configs...${RESET}"
    rm -f /var/log/frps*.log > /dev/null 2>&1
    rm -f /var/log/frpc*.log > /dev/null 2>&1
    rm -f "$(pwd)"/rstun/frps*.toml > /dev/null 2>&1
    rm -f /root/rstun/frpc*.toml > /dev/null 2>&1
    
    echo -e "${CYAN}🗑️ Cleaning all FRP systemd journal logs...${RESET}"
    sudo journalctl --rotate > /dev/null 2>&1
    for service in "${frp_server_services[@]}" "${frp_client_services[@]}"; do
      sudo journalctl --vacuum-time=1s --unit="$(basename "$service")" > /dev/null 2>&1
    done
    sudo journalctl --flush > /dev/null 2>&1
    print_success "All FRP logs removed."

    echo -e "${CYAN}🧹 Removing any associated FRP cron jobs...${RESET}"
    (sudo crontab -l 2>/dev/null | grep -v "# FRP automated restart for") | sudo crontab -
    print_success "Associated cron jobs removed."

    if [ -L "$FRP_COMMAND_PATH" ]; then
      echo "🗑️ Removing 'frp' command symlink..."
      sudo rm -f "$FRP_COMMAND_PATH"
      print_success "'frp' command symlink removed."
    fi
    # Remove setup marker file
    if [ -f "$SETUP_MARKER_FILE" ]; then
      echo "🗑️ Removing setup marker file..."
      sudo rm -f "$SETUP_MARKER_FILE"
      print_success "Setup marker file removed."
    fi

    print_success "FRP uninstallation complete."
  else
    echo -e "${YELLOW}❌ Uninstall cancelled.${RESET}"
  fi
  echo ""
  echo -e "${YELLOW}Press Enter to return to main menu...${RESET}"
  read -p ""
}

# --- Install FRP Action ---
install_frp_action() {
  clear
  echo ""
  draw_line "$CYAN" "=" 40
  echo -e "${CYAN} 📥 Installing FRP${RESET}"
  draw_line "$CYAN" "=" 40
  echo ""

  # Delete existing rstun folder if it exists
  if [ -d "rstun" ]; then
    echo -e "${YELLOW}🧹 Removing existing 'rstun' folder...${RESET}"
    rm -rf rstun
    print_success "Existing 'rstun' folder removed."
  fi

  echo -e "${CYAN}🚀 Detecting system architecture...${RESET}"
  local arch=$(uname -m)
  local download_url=""
  local filename=""
  local supported_arch=true # Flag to track if architecture is directly supported

  case "$arch" in
    "x86_64")
      filename="frp_0.63.0_linux_amd64.tar.gz"
      ;;
    "aarch64" | "arm64")
      filename="frp_0.63.0_linux_arm64.tar.gz"
      ;;
    "armv7l")
      filename="frp_0.63.0_linux_arm.tar.gz"
      ;;
    *)
      supported_arch=false # Mark as unsupported
      echo -e "${RED}❌ Error: Unsupported architecture detected: $arch${RESET}"
      echo -e "${YELLOW}Do you want to try installing the x86_64 version as a fallback? (y/N): ${RESET}"
      read -p "" fallback_confirm
      echo ""
      if [[ "$fallback_confirm" =~ ^[Yy]$ ]]; then
        filename="frp_0.63.0_linux_amd64.tar.gz"
        echo -e "${CYAN}Proceeding with x86_64 version as requested.${RESET}"
      else
        echo -e "${YELLOW}Installation cancelled. Please download frp manually for your system from https://github.com/fatedier/frp/releases${RESET}"
        echo ""
        echo -e "${YELLOW}Press Enter to return to main menu...${RESET}"
        read -p ""
        return 1 # Indicate failure
      fi
      ;;
  esac

  download_url="https://github.com/fatedier/frp/releases/download/v0.63.0/${filename}"

  echo -e "${CYAN}Downloading $filename for $arch...${RESET}"
  if wget -q --show-progress "$download_url" -O "$filename"; then
    print_success "Download complete!"
  else
    echo -e "${RED}❌ Error: Failed to download $filename. Please check your internet connection or the URL.${RESET}"
    echo ""
    echo -e "${YELLOW}Press Enter to return to main menu...${RESET}"
    read -p ""
    return 1 # Indicate failure
  fi

  echo -e "${CYAN}📦 Extracting files...${RESET}"
  if tar -xzf "$filename"; then
    mv "${filename%.tar.gz}" rstun # Rename extracted folder to 'rstun' for compatibility
    print_success "Extraction complete!"
  else
    echo -e "${RED}❌ Error: Failed to extract $filename. Corrupted download?${RESET}"
    echo ""
    echo -e "${YELLOW}Press Enter to return to main menu...${RESET}"
    read -p ""
    return 1 # Indicate failure
  fi

  echo -e "${CYAN}➕ Setting execute permissions...${RESET}"
  find rstun -type f -exec chmod +x {} \;
  print_success "Permissions set."

  echo -e "${CYAN}🗑️ Cleaning up downloaded archive...${RESET}"
  rm "$filename"
  print_success "Cleanup complete."

  echo ""
  print_success "FRP installation complete!"
  # Ensure the 'frp' command is available after installation
  ensure_frp_command_available # Call the new function here
  
  echo ""
  echo -e "${YELLOW}Press Enter to return to main menu...${RESET}"
  read -p ""
}

# --- Add New Server Action (Beautified) ---
add_frp_server_action() {
  clear
  echo ""
  draw_line "$CYAN" "=" 40
  echo -e "${CYAN} ➕ Add New FRP Server${RESET}"
  draw_line "$CYAN" "=" 40
  echo ""

  if [ ! -f "rstun/frps" ]; then
    echo -e "${RED}❗ Server build (frps) not found.${RESET}"
    echo -e "${YELLOW}Please run 'Install FRP' option from the main menu first.${RESET}"
    echo ""
    echo -e "${YELLOW}Press Enter to return to main menu...${RESET}"
    read -p ""
    return
  fi

  echo -e "${CYAN}⚙️ Server Configuration:${RESET}"
  echo -e "  ${WHITE}• Multiple Servers:${RESET} You can run multiple servers on different ports"
  echo -e "  ${WHITE}• Auto Protocol Support:${RESET} Automatically supports all protocols (TCP, KCP, QUIC, WebSocket)"
  echo -e "  ${WHITE}• Client Flexibility:${RESET} Clients can choose any protocol to connect"
  echo -e "  ${WHITE}• Dashboard:${RESET} Web interface (port+1)"
  echo ""

  # Validate Listen Port
  local listen_port
  while true; do
    echo -e "👉 ${WHITE}Enter server port (1-65535, default 7000):${RESET} "
    read -p "" listen_port_input
    listen_port=${listen_port_input:-7000}
    
    if validate_port "$listen_port"; then
      if netstat -tuln | grep -q ":$listen_port "; then
        print_error "Port $listen_port is already in use. Please choose another port."
        continue
      fi
      local service_name="frp-server-$listen_port"
      local service_file="/etc/systemd/system/${service_name}.service"
      if [ -f "$service_file" ]; then
        print_error "Server with port $listen_port already exists! Please choose another port."
        continue
      fi
      break
    else
      print_error "Invalid port number. Please enter a number between 1 and 65535."
    fi
  done

  echo -e "👉 ${WHITE}Enter authentication token:${RESET} "
  read -p "" auth_token
    echo ""

  if [[ -z "$auth_token" ]]; then
    echo -e "${RED}❌ Authentication token cannot be empty!${RESET}"
      echo ""
    echo -e "${YELLOW}Press Enter to return to main menu...${RESET}"
      read -p ""
    return
  fi

  local config_file="$(pwd)/rstun/frps_${listen_port}.toml"

  create_server_config "$config_file" "$listen_port" "$auth_token"

    # Create systemd service file
    cat <<EOF | sudo tee "$service_file" > /dev/null
[Unit]
Description=FRP Server - Port $listen_port
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=$(pwd)/rstun/frps -c $(pwd)/rstun/frps_${listen_port}.toml
Restart=always
RestartSec=2
User=$(whoami)

[Install]
WantedBy=multi-user.target
EOF

  echo -e "${CYAN}🔧 Reloading systemd daemon...${RESET}"
    sudo systemctl daemon-reload

  echo -e "${CYAN}🚀 Enabling and starting FRP server service...${RESET}"
  sudo systemctl enable "$service_name" > /dev/null 2>&1
  sudo systemctl start "$service_name" > /dev/null 2>&1

  print_success "FRP server on port '$listen_port' started successfully!"
  echo -e "${GREEN}📊 Server Info:${RESET}"
  echo -e "  ${WHITE}Server Port: ${YELLOW}$listen_port${RESET}"
  echo -e "  ${WHITE}Dashboard: ${YELLOW}http://YOUR_SERVER_IP:$((listen_port + 1))${RESET}"
  echo -e "  ${WHITE}Auth Token: ${YELLOW}$auth_token${RESET}"
  echo -e "  ${WHITE}Supported Protocols: ${GREEN}TCP, KCP, QUIC, WEBSOCKET${RESET}"
  echo -e "  ${WHITE}Service Name: ${CYAN}$service_name${RESET}"
  echo -e "  ${CYAN}💡 Note: Clients must use one of the supported protocols${RESET}"

  echo ""
  echo -e "${YELLOW}Do you want to view the logs for $service_name now? (y/N): ${RESET}"
  read -p "" view_logs_choice
  echo ""

  if [[ "$view_logs_choice" =~ ^[Yy]$ ]]; then
    show_service_logs "$service_name"
  fi

  echo ""
  echo -e "${YELLOW}Press Enter to return to previous menu...${RESET}"
  read -p ""
}

# Function to parse port ranges and lists
parse_ports() {
  local input="$1"
  local -n result_array=$2
  
  # Clear the result array
  result_array=()
  
  # Remove all spaces from input
  input=$(echo "$input" | tr -d ' ')
  
  # Split by comma
  IFS=',' read -ra parts <<< "$input"
  
  for part in "${parts[@]}"; do
    if [[ "$part" =~ ^[0-9]+-[0-9]+$ ]]; then
      # This is a range (e.g., 1000-1300)
      local start_port=$(echo "$part" | cut -d'-' -f1)
      local end_port=$(echo "$part" | cut -d'-' -f2)
      
      # Validate range
      if ! validate_port "$start_port" || ! validate_port "$end_port"; then
        print_error "Invalid port range: $part"
        return 1
      fi
      
      if (( start_port > end_port )); then
        print_error "Invalid range: start port ($start_port) must be less than or equal to end port ($end_port)"
        return 1
      fi
      
      # Add all ports in the range
      for ((port=start_port; port<=end_port; port++)); do
        result_array+=("$port")
      done
      
    elif [[ "$part" =~ ^[0-9]+$ ]]; then
      # This is a single port
      if validate_port "$part"; then
        result_array+=("$part")
      else
        print_error "Invalid port: $part"
        return 1
      fi
    else
      # Invalid format
      print_error "Invalid format: $part"
      return 1
    fi
  done
  
  # Check if we have any ports
  if [ ${#result_array[@]} -eq 0 ]; then
    return 1
  fi
  
  # Remove duplicates and sort
  IFS=$'\n' result_array=($(printf '%s\n' "${result_array[@]}" | sort -n | uniq))
  
  return 0
}

# --- Add New Client Action ---
add_frp_client_action() {
  clear
  echo ""
  draw_line "$CYAN" "=" 40
  echo -e "${CYAN} ➕ Add New FRP Client${RESET}"
  draw_line "$CYAN" "=" 40
  echo ""

  echo -e "${CYAN}🌐 Server Connection Details:${RESET}"
  echo -e "  (e.x., server.yourdomain.com:6060)"
  
  # Validate Server Address
  local server_addr
  while true; do
    echo -e "👉 ${WHITE}Server address and port (e.g., server.yourdomain.com:6060 or 192.168.1.1:6060):${RESET} "
    read -p "" server_addr_input
    local host_part=$(echo "$server_addr_input" | cut -d':' -f1)
    local port_part=$(echo "$server_addr_input" | cut -d':' -f2)

    if validate_host "$host_part" && validate_port "$port_part"; then
      server_addr="$server_addr_input"
      break
    else
      print_error "Invalid server address or port format. Please use 'host:port' (e.g., example.com:6060)."
    fi
  done

  local client_name=$(echo "$server_addr" | sed 's/[:.]/-/g')
  service_name="frp-client-$client_name"
  service_file="/etc/systemd/system/${service_name}.service"

  if [ -f "$service_file" ]; then
    echo -e "${RED}❌ Client for server '$server_addr' already exists!${RESET}"
    echo -e "${YELLOW}Service name: $service_name${RESET}"
    echo ""
    echo -e "${YELLOW}Press Enter to return to previous menu...${RESET}"
    read -p ""
    return
  fi
  echo ""

  echo -e "${CYAN}📡 Tunnel Mode:${RESET}"
  echo -e "  (tcp/udp/both)"
  echo -e "👉 ${WHITE}Tunnel mode ? (tcp/udp/both):${RESET} "
  read -p "" tunnel_mode
  echo ""

  echo -e "🔑 ${WHITE}Password:${RESET} "
  read -p "" password
  echo ""

  echo -e "${CYAN}🔢 Port Mapping Configuration:${RESET}"
  echo -e "  ${WHITE}Supported formats:${RESET}"
  echo -e "    ${GREEN}Range:${RESET} 1000-1300 (ports 1000 to 1300)"
  echo -e "    ${GREEN}List:${RESET} 1000,1001,1002 (specific ports)"
  echo -e "    ${GREEN}Mixed:${RESET} 1000-1010,2000,3000-3005"
  echo ""
  
  local port_input
  local ports_array=()

    while true; do
    echo -e "👉 ${WHITE}Enter ports (range/list):${RESET} "
      read -p "" port_input

    # Parse the input and extract ports
    if parse_ports "$port_input" ports_array; then
      if [ ${#ports_array[@]} -gt 0 ]; then
        echo -e "${GREEN}✅ Found ${#ports_array[@]} ports to tunnel.${RESET}"
        break
      else
        print_error "No valid ports found. Please try again."
      fi
    else
      print_error "Invalid port format. Please use ranges (1000-1300) or comma-separated list (1000,1001)."
      fi
    done
    echo ""

  # Get protocol selection
  echo -e "${CYAN}🌐 Protocol Selection:${RESET}"
  get_protocol_selection
  echo ""
  echo -e "👉 ${WHITE}Your choice (1-4, default: 1):${RESET} "
  read -p "" protocol_choice

  local selected_protocol=""
  case "${protocol_choice:-1}" in
    1)
      selected_protocol="tcp"
      ;;
    2)
      selected_protocol="quic"
      local server_host=$(echo "$server_addr" | cut -d':' -f1)
      local server_port=$(echo "$server_addr" | cut -d':' -f2)
      server_addr="$server_host:$((server_port + 2))"
      ;;
    3)
      selected_protocol="kcp"
      ;;
    4)
      selected_protocol="websocket"
      ;;
    *)
      print_error "Invalid choice. Using TCP as default."
      selected_protocol="tcp"
      ;;
  esac
  echo ""

  rm -f "/root/rstun/frpc_${client_name}."{ini,toml} > /dev/null 2>&1
  local config_file="/root/rstun/frpc_${client_name}.toml"
  create_client_config "$config_file" "$server_addr" "$password" "$client_name" "$selected_protocol"

  # Add port mappings to config (TOML format)

  # Create configuration entries for each port
  for port in "${ports_array[@]}"; do
    if [[ "$tunnel_mode" == "tcp" || "$tunnel_mode" == "both" ]]; then
      cat <<EOF >> "$config_file"
[[proxies]]
name = "tcp_$port"
type = "tcp"
localIP = "127.0.0.1"
localPort = $port
remotePort = $port

EOF
    fi

    if [[ "$tunnel_mode" == "udp" || "$tunnel_mode" == "both" ]]; then
      cat <<EOF >> "$config_file"
[[proxies]]
name = "udp_$port"
type = "udp"
localIP = "127.0.0.1"
localPort = $port
remotePort = $port

EOF
    fi
  done

  # Create the systemd service file using a here-document
  cat <<EOF | sudo tee "$service_file" > /dev/null
[Unit]
Description=FRP Client - $client_name
After=network.target

[Service]
Type=simple
ExecStart=/root/rstun/frpc -c /root/rstun/frpc_${client_name}.toml
Restart=always
RestartSec=2
User=root

[Install]
WantedBy=multi-user.target
EOF

  echo -e "${CYAN}🔧 Reloading systemd daemon...${RESET}"
  sudo systemctl daemon-reload

  echo -e "${CYAN}🚀 Enabling and starting FRP client service...${RESET}"
  sudo systemctl enable "$service_name" > /dev/null 2>&1
  sudo systemctl start "$service_name" > /dev/null 2>&1

  print_success "Client for '$server_addr' started successfully!"
  echo -e "${GREEN}📊 Client Info:${RESET}"
  echo -e "  ${WHITE}Server: ${YELLOW}$server_addr${RESET}"
  echo -e "  ${WHITE}Service Name: ${CYAN}$service_name${RESET}"
  echo -e "  ${WHITE}Ports: ${YELLOW}${#ports_array[@]} configured${RESET}"
  echo -e "  ${WHITE}Protocol: ${YELLOW}$selected_protocol${RESET}"

  echo ""
  echo -e "${YELLOW}Do you want to view the logs for this client now? (y/N): ${RESET}"
  read -p "" view_logs_choice
  echo ""

  if [[ "$view_logs_choice" =~ ^[Yy]$ ]]; then
    show_service_logs "$service_name"
  fi

  echo ""
  echo -e "${YELLOW}Press Enter to return to previous menu...${RESET}"
  read -p ""
}

clear_service_logs_completely() {
    local service_name="$1"
    
    if [ -z "$service_name" ]; then
        print_error "Service name is required"
        return 1
    fi
    
    echo -e "${CYAN}🧹 Completely clearing logs for service '$service_name'...${RESET}"
    
    if systemctl is-active --quiet "$service_name"; then
        echo -e "${YELLOW}⚠️ Service is running, stopping temporarily...${RESET}"
        sudo systemctl stop "$service_name"
        local was_running=true
    else
        local was_running=false
    fi
    
    sudo journalctl --rotate > /dev/null 2>&1
    sudo journalctl --vacuum-time=1s --unit="$service_name" > /dev/null 2>&1
    sudo journalctl --vacuum-time=1s --identifier="$service_name" > /dev/null 2>&1
    sudo journalctl --flush > /dev/null 2>&1
    sudo journalctl --sync > /dev/null 2>&1
    sudo rm -f /var/log/journal/*/user-*.journal > /dev/null 2>&1
    sudo rm -f /var/log/journal/*/system@*.journal > /dev/null 2>&1
    sudo systemctl restart systemd-journald > /dev/null 2>&1
    
    if [ "$was_running" = true ]; then
        echo -e "${CYAN}🚀 Restarting service...${RESET}"
        sudo systemctl start "$service_name"
    fi
    
    print_success "Logs completely cleared for service '$service_name'"
}

perform_initial_setup() {
  if [ -f "$SETUP_MARKER_FILE" ]; then
    echo -e "${YELLOW}Initial setup already performed. Skipping prerequisites installation.${RESET}"
    ensure_frp_command_available
    return 0
  fi

  echo -e "${CYAN}Performing initial setup (installing dependencies and setting up 'frp' command)...${RESET}"

  # Install required tools
  echo -e "${CYAN}Updating package lists and installing dependencies...${RESET}"
  sudo apt update
  sudo apt install -y build-essential curl pkg-config libssl-dev git figlet cron

  # Ensure 'frp' command symlink is created/updated after initial setup
  if ensure_frp_command_available; then # Call the function and check its return status
      sudo mkdir -p "$(dirname "$SETUP_MARKER_FILE")" # Ensure directory exists for marker file
      sudo touch "$SETUP_MARKER_FILE" # Create marker file only if all initial setup steps (including symlink) succeed
    print_success "Initial setup complete and 'frp' command is ready."
      return 0
    else
    print_error "Failed to set up 'frp' command symlink during initial setup. Please fix manually as instructed above."
      return 1 # Propagate failure
  fi
  echo ""
  return 0
}

# --- Main Script Execution ---
set -e # Exit immediately if a command exits with a non-zero status

# Perform initial setup (will run only once)
perform_initial_setup || { echo "Initial setup failed. Exiting."; exit 1; }

# Show initialization splash screen
echo -e "${CYAN}🚀 FRP Tunnel Manager${RESET}"
echo -e "${WHITE}Loading...${RESET}"
sleep 1

# Start main menu
while true; do
  # Clear terminal and show logo
  clear
  echo -e "${CYAN}"
  
  # Check if figlet is available, if not show a simple banner
  if command -v figlet &> /dev/null; then
    figlet -f slant "FRP Tunnel"
  else
    # Fallback ASCII banner if figlet is not available
    echo "███████ ██████  ██████      ████████ ██    ██ ███    ██ ███    ██ ███████ ██      "
    echo "██      ██   ██ ██   ██        ██    ██    ██ ████   ██ ████   ██ ██      ██      "
    echo "█████   ██████  ██████         ██    ██    ██ ██ ██  ██ ██ ██  ██ █████   ██      "
    echo "██      ██   ██ ██             ██    ██    ██ ██  ██ ██ ██  ██ ██ ██      ██      "
    echo "██      ██   ██ ██             ██     ██████  ██   ████ ██   ████ ███████ ███████ "
    echo ""
  fi
  
  echo -e "${CYAN}"
  echo -e "\033[1;33m=========================================================="
  echo -e "\033[0m${WHITE}Fast Reverse Proxy Manager${WHITE}${RESET}"
  draw_green_line
  echo -e "${GREEN}${RESET}       ${WHITE}FRP Tunnel Manager${RESET}       ${GREEN}${RESET}"
  echo -e "${YELLOW}You can also run this script anytime by typing: ${WHITE}frp${RESET}"
  draw_green_line
  # Menu
  echo "Select an option:"
  echo -e "${MAGENTA}1) Install FRP${RESET}"
  echo -e "${CYAN}2) Server Management${RESET}"
  echo -e "${BLUE}3) Client Management${RESET}"
  echo -e "${RED}4) Uninstall FRP${RESET}"
  echo -e "${WHITE}5) Exit${RESET}"
  read -p "👉 Your choice: " choice

  case $choice in
    1)
      install_frp_action
      ;;
    2) # Server Management
          clear
          # Server Management Sub-menu
          while true; do
            clear # Clear screen for a fresh menu display
            echo ""
            draw_line "$GREEN" "=" 40 # Top border
        echo -e "${CYAN} 🔧 FRP Server Management${RESET}"
            draw_line "$GREEN" "=" 40 # Separator
            echo ""
        echo -e "  ${YELLOW}1)${RESET} ${WHITE}Add new server${RESET}"
        echo -e "  ${YELLOW}2)${RESET} ${WHITE}Show service logs${RESET}"
        echo -e "  ${YELLOW}3)${RESET} ${WHITE}Delete service${RESET}"
        echo -e "  ${YELLOW}4)${RESET} ${WHITE}Back to main menu${RESET}"
            echo ""
            draw_line "$GREEN" "-" 40 # Bottom border
        echo -e "👉 ${CYAN}Your choice:${RESET} "
            read -p "" srv_choice
            echo ""
            case $srv_choice in
              1)
                add_frp_server_action
              ;;
              2)
                clear
                  echo ""
            draw_line "$CYAN" "=" 40
            echo -e "${CYAN} 📊 Server Logs${RESET}"
            draw_line "$CYAN" "=" 40
            echo ""

            echo -e "${CYAN}🔍 Searching for servers...${RESET}"

            # List all server services
            mapfile -t servers < <(systemctl list-units --type=service --all | grep 'frp-server-' | awk '{print $1}' | sed 's/.service$//')

            if [ ${#servers[@]} -eq 0 ]; then
              echo -e "${RED}❌ No servers found.${RESET}"
              echo ""
              echo -e "${YELLOW}Press Enter to return to previous menu...${RESET}"
                  read -p ""
            else
              echo -e "${CYAN}📋 Please select a server to see logs:${RESET}"
              servers+=("Back to previous menu")
              select selected_server in "${servers[@]}"; do
                if [[ "$selected_server" == "Back to previous menu" ]]; then
                  echo -e "${YELLOW}Returning to previous menu...${RESET}"
                  echo ""
                  break 2
                elif [ -n "$selected_server" ]; then
                  show_service_logs "$selected_server"
                  break
                else
                  echo -e "${RED}⚠️ Invalid selection. Please enter a valid number.${RESET}"
                fi
              done
                fi
              ;;
              3)
                clear
            echo ""
            draw_line "$CYAN" "=" 40
            echo -e "${CYAN} 🗑️ Delete Server${RESET}"
            draw_line "$CYAN" "=" 40
            echo ""

            echo -e "${CYAN}🔍 Searching for servers...${RESET}"

            # List all server services
            mapfile -t servers < <(systemctl list-units --type=service --all | grep 'frp-server-' | awk '{print $1}' | sed 's/.service$//')

            if [ ${#servers[@]} -eq 0 ]; then
              echo -e "${RED}❌ No servers found.${RESET}"
              echo ""
              echo -e "${YELLOW}Press Enter to return to previous menu...${RESET}"
              read -p ""
            else
              echo -e "${CYAN}📋 Please select a server to delete:${RESET}"
              servers+=("Back to previous menu")
              select selected_server in "${servers[@]}"; do
                if [[ "$selected_server" == "Back to previous menu" ]]; then
                  echo -e "${YELLOW}Returning to previous menu...${RESET}"
                  echo ""
                  break 2
                elif [ -n "$selected_server" ]; then
                  service_file="/etc/systemd/system/${selected_server}.service"
                  echo -e "${YELLOW}🛑 Stopping and deleting $selected_server...${RESET}"
                  sudo systemctl stop "$selected_server" > /dev/null 2>&1
                  sudo systemctl disable "$selected_server" > /dev/null 2>&1
                  sudo rm -f "$service_file" > /dev/null 2>&1
                  
                  server_port=$(echo "$selected_server" | sed 's/frp-server-//')
                  echo -e "${CYAN}🧹 Removing config and logs for server port '$server_port'...${RESET}"
                  rm -f "$(pwd)/rstun/frps_${server_port}.toml" "/var/log/frps_${server_port}.log"* > /dev/null 2>&1
                  
                  # Complete journal cleanup for this service
                  clear_service_logs_completely "$selected_server"
                  
                  sudo systemctl daemon-reload > /dev/null 2>&1
                  print_success "Server on port '$server_port' and its specific logs deleted."
                  break
                else
                  echo -e "${RED}⚠️ Invalid selection. Please enter a valid number.${RESET}"
                fi
              done
                echo ""
              echo -e "${YELLOW}Press Enter to return to previous menu...${RESET}"
                  read -p ""
            fi
            ;;
          4)
                break
              ;;
              *)
            echo -e "${RED}❌ Invalid option.${RESET}"
                echo ""
            echo -e "${YELLOW}Press Enter to continue...${RESET}"
                read -p ""
              ;;
            esac
          done
          ;;
    3) # Client Management
          clear
          while true; do
            clear # Clear screen for a fresh menu display
            echo ""
            draw_line "$GREEN" "=" 40 # Top border
        echo -e "${CYAN} 📱 FRP Client Management${RESET}"
            draw_line "$GREEN" "=" 40 # Separator
            echo ""
        echo -e "  ${YELLOW}1)${RESET} ${WHITE}Add new client${RESET}"
        echo -e "  ${YELLOW}2)${RESET} ${WHITE}Show Client Log${RESET}"
        echo -e "  ${YELLOW}3)${RESET} ${WHITE}Delete a client${RESET}"
        echo -e "  ${YELLOW}4)${RESET} ${GREEN}🏥 Health Check${RESET}"
        echo -e "  ${YELLOW}5)${RESET} ${CYAN}🔄 Hot-reload Management${RESET}"
        echo -e "  ${YELLOW}6)${RESET} ${MAGENTA}🌐 Protocol Management${RESET}"
        echo -e "  ${YELLOW}7)${RESET} ${WHITE}Back to main menu${RESET}"
            echo ""
            draw_line "$GREEN" "-" 40 # Bottom border
        echo -e "👉 ${CYAN}Your choice:${RESET} "
            read -p "" client_choice
            echo ""

            case $client_choice in
              1)
                add_frp_client_action
              ;;
              2)
                clear
                echo ""
                draw_line "$CYAN" "=" 40
            echo -e "${CYAN} 📊 FRP Client Logs${RESET}"
                draw_line "$CYAN" "=" 40
                echo ""

            echo -e "${CYAN}🔍 Searching for all FRP clients (including old naming format)...${RESET}"
                mapfile -t services < <(systemctl list-units --type=service --all | grep 'frp-client-' | awk '{print $1}' | sed 's/.service$//')

                if [ ${#services[@]} -eq 0 ]; then
              echo -e "${RED}❌ No clients found.${RESET}"
                  echo ""
              echo -e "${YELLOW}Press Enter to return to previous menu...${RESET}"
              read -p ""
                else
              echo -e "${CYAN}📋 Please select a service to see log:${RESET}"
                  # Add "Back to previous menu" option
                  services+=("Back to previous menu")
                  select selected_service in "${services[@]}"; do
                    if [[ "$selected_service" == "Back to previous menu" ]]; then
                  echo -e "${YELLOW}Returning to previous menu...${RESET}"
                      echo ""
                      break 2 # Exit both the select and the outer while loop
                    elif [ -n "$selected_service" ]; then
                      show_service_logs "$selected_service"
                      break # Exit the select loop
                    else
                  echo -e "${RED}⚠️ Invalid selection. Please enter a valid number.${RESET}"
                    fi
                  done
                  echo "" # Add a blank line after selection
              echo -e "${YELLOW}Press Enter to return to previous menu...${RESET}"
                  read -p ""
                fi
              ;;
              3)
                clear
                echo ""
                draw_line "$CYAN" "=" 40
            echo -e "${CYAN} 🗑️ Delete FRP Client${RESET}"
                draw_line "$CYAN" "=" 40
                echo ""

            echo -e "${CYAN}🔍 Searching for all FRP clients (including old naming format)...${RESET}"
                mapfile -t services < <(systemctl list-units --type=service --all | grep 'frp-client-' | awk '{print $1}' | sed 's/.service$//')

                if [ ${#services[@]} -eq 0 ]; then
              echo -e "${RED}❌ No clients found.${RESET}"
                  echo ""
              echo -e "${YELLOW}Press Enter to return to previous menu...${RESET}"
              read -p ""
                else
              echo -e "${CYAN}📋 Please select a service to delete:${RESET}"
                  # Add "Back to previous menu" option
                  services+=("Back to previous menu")
                  select selected_service in "${services[@]}"; do
                    if [[ "$selected_service" == "Back to previous menu" ]]; then
                  echo -e "${YELLOW}Returning to previous menu...${RESET}"
                      echo ""
                      break 2 # Exit both the select and the outer while loop
                    elif [ -n "$selected_service" ]; then
                      service_file="/etc/systemd/system/${selected_service}.service"
                  echo -e "${YELLOW}🛑 Stopping $selected_service...${RESET}"
                      sudo systemctl stop "$selected_service" > /dev/null 2>&1
                      sudo systemctl disable "$selected_service" > /dev/null 2>&1
                      sudo rm -f "$service_file" > /dev/null 2>&1
                  
                  client_identifier=$(echo "$selected_service" | sed 's/frp-client-//')
                  
                  # Check if it's new format (contains server-port pattern) or old format (custom name)
                  if echo "$client_identifier" | grep -q ".*-.*-.*-[0-9]*$"; then
                    # New format: convert back to readable server address
                    readable_server=$(echo "$client_identifier" | sed 's/-/:/2' | sed 's/-/./g' | sed 's/:/-/' | sed 's/-/:/')
                    echo -e "${CYAN}🧹 Removing config and logs for client '$readable_server'...${RESET}"
                  else
                    # Old format: show as is
                    echo -e "${CYAN}🧹 Removing config and logs for client '$client_identifier'...${RESET}"
                  fi
                  
                  rm -f "/root/rstun/frpc_${client_identifier}.toml" "/var/log/frpc_${client_identifier}.log"* > /dev/null 2>&1
                  
                  # Complete journal cleanup for this service
                  clear_service_logs_completely "$selected_service"
                  
                      sudo systemctl daemon-reload > /dev/null 2>&1
                  
                  # Display appropriate success message
                  if echo "$client_identifier" | grep -q ".*-.*-.*-[0-9]*$"; then
                    print_success "Client for '$readable_server' and its specific logs deleted."
                  else
                    print_success "Client '$client_identifier' and its specific logs deleted."
                  fi
                      break # Exit the select loop
                    else
                  echo -e "${RED}⚠️ Invalid selection. Please enter a valid number.${RESET}"
                    fi
                  done
                  echo "" # Add a blank line after selection
              echo -e "${YELLOW}Press Enter to return to previous menu...${RESET}"
                  read -p ""
                fi
              ;;
                    4) # Health Check
                clear
                echo ""
            draw_line "$CYAN" "=" 50
            echo -e "${CYAN}        🏥 Health Check${RESET}"
            draw_line "$CYAN" "=" 50
                echo ""

            mapfile -t client_services < <(systemctl list-units --type=service --all | grep 'frp-client-' | grep -v 'frp-server-' | awk '{print $1}' | sed 's/.service$//')
            
            if [ ${#client_services[@]} -eq 0 ]; then
              echo -e "${RED}❌ No clients found.${RESET}"
              echo ""
              echo -e "${YELLOW}Press Enter to return...${RESET}"
              read -p ""
              continue
            fi
            
            # Create display names for clients
            declare -a display_names=()
            declare -a client_identifiers=()
            
            for service in "${client_services[@]}"; do
              client_id=$(echo "$service" | sed 's/frp-client-//')
              client_identifiers+=("$client_id")
              
              # Check if it's new format or old format
              if echo "$client_id" | grep -q ".*-.*-.*-[0-9]*$"; then
                # New format: convert to readable server address
                readable=$(echo "$client_id" | sed 's/-/:/2' | sed 's/-/./g' | sed 's/:/-/' | sed 's/-/:/')
                display_names+=("$readable (Server)")
              else
                # Old format: show as is
                display_names+=("$client_id (Custom)")
              fi
            done
            
            echo -e "${CYAN}📋 Select client:${RESET}"
            display_names+=("Back to previous menu")
                          select selected_display in "${display_names[@]}"; do
                if [[ "$selected_display" == "Back to previous menu" ]]; then
                  break 2
                elif [ -n "$selected_display" ]; then
                  # Get the actual client identifier based on selection
                  selected_index=$((REPLY - 1))
                  selected_client="${client_identifiers[$selected_index]}"
                  
                  get_client_health "$selected_client"
                  echo ""
                echo -e "${YELLOW}Press Enter to continue...${RESET}"
                  read -p ""
                break
              else
                echo -e "${RED}Invalid selection.${RESET}"
                    fi
                  done
              ;;
          5) # Hot-reload Management
                clear
                echo ""
                draw_line "$CYAN" "=" 50
                echo -e "${CYAN}        🔄 Hot-reload Management${RESET}"
                draw_line "$CYAN" "=" 50
                echo ""
                
                mapfile -t client_services < <(systemctl list-units --type=service --all | grep 'frp-client-' | grep -v 'frp-server-' | awk '{print $1}' | sed 's/.service$//')
                
                if [ ${#client_services[@]} -eq 0 ]; then
                  echo -e "${RED}❌ No clients found.${RESET}"
                  echo ""
                  echo -e "${YELLOW}Press Enter to return...${RESET}"
                  read -p ""
                  continue
                fi
                
                # Create display names for clients
                declare -a display_names=()
                declare -a client_identifiers=()
                
                for service in "${client_services[@]}"; do
                  client_id=$(echo "$service" | sed 's/frp-client-//')
                  client_identifiers+=("$client_id")
                  
                  # Check if it's new format or old format
                  if echo "$client_id" | grep -q ".*-.*-.*-[0-9]*$"; then
                    # New format: convert to readable server address
                    readable=$(echo "$client_id" | sed 's/-/:/2' | sed 's/-/./g' | sed 's/:/-/' | sed 's/-/:/')
                    display_names+=("$readable (Server)")
                  else
                    # Old format: show as is
                    display_names+=("$client_id (Custom)")
                  fi
                done
                
                echo -e "${CYAN}📋 Select client:${RESET}"
                display_names+=("Back to previous menu")
                                  select selected_display in "${display_names[@]}"; do
                    if [[ "$selected_display" == "Back to previous menu" ]]; then
                      break 2
                    elif [ -n "$selected_display" ]; then
                      # Get the actual client identifier based on selection
                      selected_index=$((REPLY - 1))
                      selected_client="${client_identifiers[$selected_index]}"
                    while true; do
                      echo ""
                      echo -e "${GREEN}🔄 Hot-reload options for '$selected_client':${RESET}"
                      echo -e "  ${WHITE}1)${RESET} Add ports"
                      echo -e "  ${WHITE}2)${RESET} Remove ports"
                      echo -e "  ${WHITE}3)${RESET} List active ports"
                      echo -e "  ${WHITE}4)${RESET} Reload configuration"
                      echo -e "  ${WHITE}5)${RESET} Back"
                      echo ""
                      echo -e "👉 ${CYAN}Your choice:${RESET} "
                      read -p "" hotreload_choice
                      
                      case $hotreload_choice in
                        1)
                          echo -e "👉 ${WHITE}Enter ports to add (e.g., 8080-8090,9000):${RESET} "
                          read -p "" new_ports
                          echo -e "👉 ${WHITE}Tunnel mode (tcp/udp/both):${RESET} "
                          read -p "" tunnel_mode
                          add_ports_to_client "$selected_client" "$new_ports" "$tunnel_mode"
                          ;;
                        2)
                          echo -e "👉 ${WHITE}Enter ports to remove (e.g., 8080-8090,9000):${RESET} "
                          read -p "" remove_ports
                          remove_ports_from_client "$selected_client" "$remove_ports"
                          ;;
                        3)
                          list_client_ports "$selected_client"
                          ;;
                        4)
                          hot_reload_client "$selected_client"
                          ;;
                        5)
                break
              ;;
              *)
                          print_error "Invalid option"
                          ;;
                      esac
                echo ""
                      echo -e "${YELLOW}Press Enter to continue...${RESET}"
                read -p ""
                    done
                    break
                  else
                    echo -e "${RED}Invalid selection.${RESET}"
                  fi
                done
              ;;
          6) # Protocol Management
                clear
                echo ""
                draw_line "$CYAN" "=" 50
                echo -e "${CYAN}        🌐 Protocol Management${RESET}"
                draw_line "$CYAN" "=" 50
                echo ""
                
                mapfile -t client_services < <(systemctl list-units --type=service --all | grep 'frp-client-' | grep -v 'frp-server-' | awk '{print $1}' | sed 's/.service$//')
                
                if [ ${#client_services[@]} -eq 0 ]; then
                  echo -e "${RED}❌ No clients found.${RESET}"
                  echo ""
                  echo -e "${YELLOW}Press Enter to return...${RESET}"
                  read -p ""
                  continue
                fi
                
                # Create display names for clients
                declare -a display_names=()
                declare -a client_identifiers=()
                
                for service in "${client_services[@]}"; do
                  client_id=$(echo "$service" | sed 's/frp-client-//')
                  client_identifiers+=("$client_id")
                  
                  # Check if it's new format or old format
                  if echo "$client_id" | grep -q ".*-.*-.*-[0-9]*$"; then
                    # New format: convert to readable server address
                    readable=$(echo "$client_id" | sed 's/-/:/2' | sed 's/-/./g' | sed 's/:/-/' | sed 's/-/:/')
                    display_names+=("$readable (Server)")
                  else
                    # Old format: show as is
                    display_names+=("$client_id (Custom)")
                  fi
                done
                
                echo -e "${CYAN}📋 Select client:${RESET}"
                display_names+=("Back to previous menu")
                                  select selected_display in "${display_names[@]}"; do
                    if [[ "$selected_display" == "Back to previous menu" ]]; then
                      break 2
                    elif [ -n "$selected_display" ]; then
                      # Get the actual client identifier based on selection
                      selected_index=$((REPLY - 1))
                      selected_client="${client_identifiers[$selected_index]}"
                      
                      # Get current protocol
                      config_file="/root/rstun/frpc_${selected_client}.toml"
                    
                    # Check if config file exists
                    if [ ! -f "$config_file" ]; then
                      print_error "Configuration file not found for client '$selected_client'"
                      echo ""
                      echo -e "${YELLOW}Press Enter to continue...${RESET}"
                      read -p ""
                      break
                    fi
                    
                    current_protocol=$(grep 'transport.protocol = ' "$config_file" | cut -d'"' -f2)
                    
                    echo ""
                    echo -e "${GREEN}📡 Current Protocol: ${YELLOW}${current_protocol^^}${RESET}"
                    echo ""
                    echo -e "${WHITE}Select new protocol:${RESET}"
                    echo ""
                    get_protocol_selection
                    echo ""
                    echo -e "👉 ${WHITE}Enter your choice (1-4, default: 1):${RESET} "
                    read -p "" user_protocol_choice
                    
                    case "${user_protocol_choice:-1}" in
                      1)
                        new_protocol="tcp"
                        ;;
                      2)
                        new_protocol="quic"
                        ;;
                      3)
                        new_protocol="kcp"
                        ;;
                      4)
                        new_protocol="websocket"
                        ;;
                      *)
                        print_error "Invalid choice. Using TCP as default."
                        new_protocol="tcp"
              ;;
            esac
                    
                    echo ""
                    update_client_protocol "$selected_client" "$new_protocol"
                    echo ""
                    echo -e "${YELLOW}Press Enter to continue...${RESET}"
                    read -p ""
                    break
                  else
                    echo -e "${RED}Invalid selection.${RESET}"
                  fi
          done
          ;;
          7)
                break
          ;;
        *)
            echo -e "${RED}❌ Invalid option.${RESET}"
          echo ""
            echo -e "${YELLOW}Press Enter to continue...${RESET}"
          read -p ""
          ;;
      esac
          done
    ;;
    4)
      uninstall_frp_action
      ;;
    5)
      exit 0
    ;;
    *)
      echo -e "${RED}❌ Invalid choice. Exiting.${RESET}"
      echo ""
      echo -e "${YELLOW}Press Enter to continue...${RESET}"
      read -p ""
    ;;
  esac
  echo ""
done