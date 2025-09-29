#!/bin/bash

set -euo pipefail

# Proxmox 9 LXC provisioning script for Dell iDRAC fan controller
# Run this on the Proxmox host as root.

# -------- User-configurable variables --------
# Collected interactively via prompts below

# Controller configuration (env for the service inside the container)
# Intentionally not preset so prompts will appear
# shellcheck disable=SC2034
CONTROL_METHOD="auto" # ipmi|redfish|auto (can be changed via prompt)

# Template selection (auto-discover latest Debian 12 standard)
TEMPLATE_NAME=${TEMPLATE_NAME:-}

# -------- Helpers --------
need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }; }

assign_default() {
  local var_name=$1
  local default_value=$2
  local label=${3:-}
  if [[ -z "${!var_name+x}" || -z "${!var_name}" ]]; then
    printf -v "$var_name" "%s" "$default_value"
    if [[ -n "$label" ]]; then
      echo "Using default $label: ${!var_name}"
    fi
  fi
}

prompt_input() {
  local prompt_message="$1"
  local default_value="$2"
  local user_input
  read -p "$prompt_message [$default_value]: " user_input
  local result="${user_input:-$default_value}"
  echo "$result"
}

prompt_secret() {
  local prompt_message="$1"
  local user_input
  read -s -p "$prompt_message: " user_input || true
  echo ""
  # Return only the input without any extra characters
  echo -n "$user_input"
}

list_all_storages() {
  # Output: one storage id per line
  pvesm status 2>/dev/null | awk 'NR>1 {print $1}'
}

select_storage_menu() {
  local var_name=$1
  local title=$2
  local detected_default=$3

  local options idx choice
  mapfile -t options < <(list_all_storages)
  if [[ ${#options[@]} -eq 0 ]]; then
    echo "No storages found. Falling back to: $detected_default"
    printf -v "$var_name" "%s" "$detected_default"
    return 0
  fi

  echo "$title"
  for idx in "${!options[@]}"; do
    echo "  $((idx+1)). ${options[$idx]}"
  done
  read -p "Select an option [1-${#options[@]}] (default 1): " choice || true
  if [[ -z "$choice" ]]; then choice=1; fi
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#options[@]} )); then
    echo "Invalid choice. Using default 1."
    choice=1
  fi
  printf -v "$var_name" "%s" "${options[$((choice-1))]}"
}

maybe_test_redfish() {
  local host="$1" user="$2" pass="$3"
  local answer
  echo "Redfish is recommended for iDRAC9 v7.00+. We'll test connectivity with HTTPS:443 using current credentials."
  read -p "Test Redfish connectivity now? [y/N]: " answer || true
  case "$answer" in
    y|Y)
      echo "Testing Redfish: https://$host/redfish/v1/ (self-signed allowed)"
      echo "DEBUG: Using credentials user='$user', pass_length=${#pass}"
      echo "DEBUG: Running curl command..."
      local curl_output
      curl_output=$(curl -k -s -S -u "$user:$pass" -o /dev/null -w "%{http_code}" "https://$host/redfish/v1/" 2>&1)
      echo "DEBUG: Curl output: $curl_output"
      if echo "$curl_output" | grep -qE '^(200|201|202|204)$'; then
        echo "Redfish reachable."
      else
        echo "WARNING: Redfish not reachable or credentials invalid. You can continue; IPMI may still work or fix connectivity."
      fi
      ;;
    *) ;;
  esac
}

ensure_template() {
  if [[ -n "$TEMPLATE_NAME" ]]; then
    return 0
  fi
  local latest
  latest=$(pveam available | awk '/debian-12-standard_.*_amd64.tar.zst/ {print $2}' | sort -V | tail -1)
  if [[ -z "$latest" ]]; then
    echo "Could not find a Debian 12 standard template via pveam available" >&2
    exit 1
  fi
  TEMPLATE_NAME=$latest
  if ! pveam list "$TEMPLATE_STORAGE" | awk '{print $2}' | grep -q "$(basename "$TEMPLATE_NAME")"; then
    echo "Downloading template to $TEMPLATE_STORAGE: $TEMPLATE_NAME"
    pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_NAME"
  fi
}

create_container() {
  local netconf
  if [[ "$CT_IP_MODE" == "static" ]]; then
    netconf="name=eth0,bridge=$BRIDGE,ip=$CT_IP/$CT_MASK,gw=$CT_GW"
  else
    netconf="name=eth0,bridge=$BRIDGE,ip=dhcp"
  fi

  if pct status "$VMID" >/dev/null 2>&1; then
    echo "Container $VMID already exists. Skipping create."
    return 0
  fi

  echo "Creating LXC $VMID using template storage $TEMPLATE_STORAGE and rootfs on $ROOTFS_STORAGE"
  pct create "$VMID" "$TEMPLATE_STORAGE:vztmpl/$(basename "$TEMPLATE_NAME")" \
    --hostname "$HOSTNAME" \
    --password "$CT_PASSWORD" \
    --cores "$CPU_CORES" \
    --memory "$MEMORY_MB" \
    --rootfs "$ROOTFS_STORAGE:$ROOTFS_GB" \
    --unprivileged 1 \
    --features "nesting=1,keyctl=1" \
    --net0 "$netconf"
}

start_container() {
  echo "Starting LXC $VMID"
  pct start "$VMID" || true
  # Wait for init
  sleep 3
}

exec_in_container() {
  pct exec "$VMID" -- bash -lc "$*"
}

push_into_container() {
  local src=$1 dst=$2
  pct push "$VMID" "$src" "$dst"
}

install_dependencies() {
  echo "Installing dependencies in container"
  exec_in_container "export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get install -y --no-install-recommends ipmitool curl jq ca-certificates && apt-get clean && rm -rf /var/lib/apt/lists/*"
}

deploy_controller() {
  echo "Deploying controller script from GitHub"
  
  # Download the controller script directly from GitHub into the container
  local github_url="https://raw.githubusercontent.com/rpbush/Dell_iDRAC_fan_controller_Docker/master/Dell_iDRAC_fan_controller.sh"
  
  echo "DEBUG: Downloading controller script from $github_url"
  exec_in_container "curl -fsSL '$github_url' -o /usr/local/bin/Dell_iDRAC_fan_controller.sh"
  exec_in_container "chmod 0755 /usr/local/bin/Dell_iDRAC_fan_controller.sh"

  echo "Writing environment file"
  exec_in_container "install -d -m 0755 /etc/default"
  exec_in_container "cat > /etc/default/idrac-fan-controller <<'EOF'
IDRAC_HOST=$IDRAC_HOST
IDRAC_USERNAME=$IDRAC_USERNAME
IDRAC_PASSWORD=$IDRAC_PASSWORD
CONTROL_METHOD=$CONTROL_METHOD
FAN_SPEED=$FAN_SPEED
CPU_TEMPERATURE_TRESHOLD=$CPU_TEMPERATURE_TRESHOLD
CHECK_INTERVAL=$CHECK_INTERVAL
EOF"

  echo "Creating systemd service"
  exec_in_container "cat > /etc/systemd/system/idrac-fan-controller.service <<'EOF'
[Unit]
Description=Dell iDRAC Fan Controller
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/default/idrac-fan-controller
ExecStart=/usr/local/bin/Dell_iDRAC_fan_controller.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF"

  exec_in_container "systemctl daemon-reload && systemctl enable --now idrac-fan-controller.service"
}

# Optional: Map host IPMI device into container (for local IPMI control). Disabled by default.
# To enable, set MAP_IPMI_DEVICE=1 and ensure host has /dev/ipmi0
map_ipmi_device_if_requested() {
  local cfg="/etc/pve/lxc/$VMID.conf"
  if [[ "${MAP_IPMI_DEVICE:-0}" == "1" ]]; then
    if [[ ! -e /dev/ipmi0 ]]; then
      echo "/dev/ipmi0 not found on host; cannot map device." >&2
      return 1
    fi
    echo "Mapping /dev/ipmi0 into container $VMID"
    # Append device allowances and mount entry
    {
      echo "lxc.cgroup2.devices.allow: c 244:0 rwm"
      echo "lxc.mount.entry: /dev/ipmi0 dev/ipmi0 none bind,create=file,optional"
    } >> "$cfg"
    echo "Restarting container to apply device mapping"
    pct stop "$VMID"
    pct start "$VMID"
  fi
}

main() {
  need_cmd pveam
  need_cmd pct
  echo "=== iDRAC Fan Controller LXC Setup ==="

  # Container basics
  VMID=$(prompt_input "Enter container VMID" "902")
  HOSTNAME=$(prompt_input "Enter container hostname" "idrac-fanctl")
  # Prompt for storages with menu
  select_storage_menu TEMPLATE_STORAGE "Select template storage:" "local"
  select_storage_menu ROOTFS_STORAGE "Select rootfs storage:" "local-lvm"
  assign_default BRIDGE "vmbr0" "network bridge"
  CT_PASSWORD=$(prompt_input "Enter container root password" "changeme")
  assign_default CPU_CORES "1" "CPU cores"
  assign_default MEMORY_MB "256" "memory (MB)"
  assign_default ROOTFS_GB "4" "rootfs size (GB)"

  # Networking
  assign_default CT_IP_MODE "dhcp" "network mode"
  case "$CT_IP_MODE" in
    static)
      CT_IP=$(prompt_input "Static IP address" "192.168.1.250")
      CT_MASK=$(prompt_input "CIDR mask (e.g., 24)" "24")
      CT_GW=$(prompt_input "Gateway" "192.168.1.1")
      ;;
    *) CT_IP_MODE="dhcp" ;;
  esac

  # Controller config
  echo "DEBUG: About to prompt for iDRAC host"
  IDRAC_HOST=$(prompt_input "Enter iDRAC IP/hostname" "192.168.1.100")
  echo "DEBUG: iDRAC_HOST = '$IDRAC_HOST'"
  echo "Using iDRAC host: $IDRAC_HOST"
  
  echo "DEBUG: About to prompt for iDRAC username"
  IDRAC_USERNAME=$(prompt_input "Enter iDRAC username" "root")
  echo "DEBUG: iDRAC_USERNAME = '$IDRAC_USERNAME'"
  echo "Using iDRAC username: $IDRAC_USERNAME"
  
  echo "DEBUG: About to prompt for iDRAC password"
  printf "Enter iDRAC password: "
  read -s IDRAC_PASSWORD
  echo ""
  # Clean any leading/trailing whitespace and newlines
  IDRAC_PASSWORD=$(echo -n "$IDRAC_PASSWORD" | tr -d '\n\r')
  echo "DEBUG: iDRAC_PASSWORD length: ${#IDRAC_PASSWORD}"
  echo "DEBUG: iDRAC_PASSWORD content: '${IDRAC_PASSWORD}'"

  local cm
  read -p "Control method [auto|redfish|ipmi] (default: auto): " cm || true
  cm=${cm:-auto}
  case "$cm" in
    auto|redfish|ipmi) CONTROL_METHOD=$cm ;;
    *) CONTROL_METHOD=auto ;;
  esac
  if [[ "$CONTROL_METHOD" == "redfish" || "$CONTROL_METHOD" == "auto" ]]; then
    echo "DEBUG: Testing Redfish with host=$IDRAC_HOST, user=$IDRAC_USERNAME, pass_length=${#IDRAC_PASSWORD}"
    maybe_test_redfish "$IDRAC_HOST" "$IDRAC_USERNAME" "$IDRAC_PASSWORD"
  fi

  FAN_SPEED=$(prompt_input "Fan speed percentage (0-100)" "20")
  CPU_TEMPERATURE_TRESHOLD=$(prompt_input "CPU temp threshold (°C)" "60")
  CHECK_INTERVAL=$(prompt_input "Check interval (s)" "30")

  # Optional IPMI device mapping
  local map
  read -p "Map host /dev/ipmi0 into container? [y/N]: " map || true
  case "$map" in
    y|Y) MAP_IPMI_DEVICE=1 ;;
    *) MAP_IPMI_DEVICE=0 ;;
  esac

  ensure_template
  create_container
  start_container
  install_dependencies
  deploy_controller
  map_ipmi_device_if_requested || true
  echo "Done. Container $VMID is running $HOSTNAME. Service: idrac-fan-controller"
}

main "$@"


