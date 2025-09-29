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
  local var_name=$1; shift
  local default_value=$1; shift
  local label=$1; shift || true
  if [[ -z "${!var_name+x}" || -z "${!var_name}" ]]; then
    printf -v "$var_name" "%s" "$default_value"
    if [[ -n "$label" ]]; then
      echo "Using default $label: ${!var_name}"
    fi
  fi
}

list_storages_by_content() {
  local pattern=$1; shift
  # Output: one storage id per line whose content column contains the pattern
  # pvesm status output includes a header; search the whole line for content keywords
  pvesm status 2>/dev/null | awk -v pat="$pattern" 'NR>1 && $0 ~ pat {print $1}'
}

select_storage_menu() {
  local var_name=$1; shift
  local title=$1; shift
  local pattern=$1; shift
  local detected_default=$1; shift

  local options idx choice
  mapfile -t options < <(list_storages_by_content "$pattern")
  if [[ ${#options[@]} -eq 0 ]]; then
    echo "No storages matching pattern '$pattern' found. Falling back to: $detected_default"
    printf -v "$var_name" "%s" "$detected_default"
    return 0
  fi

  echo "$title"
  for idx in "${!options[@]}"; do
    echo "  $((idx+1)). ${options[$idx]}"
  done
  echo -n "Select an option [1-${#options[@]}] (default 1): "
  read -r choice || true
  if [[ -z "$choice" ]]; then choice=1; fi
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#options[@]} )); then
    echo "Invalid choice. Using default 1."
    choice=1
  fi
  printf -v "$var_name" "%s" "${options[$((choice-1))]}"
}

prompt_var() {
  local var_name=$1; shift
  local prompt_text=$1; shift
  local default_value=${1:-}
  local input
  # If variable is already set and non-empty, do nothing
  if [[ -n "${!var_name+x}" && -n "${!var_name}" ]]; then
    return 0
  fi
  if [[ -n "$default_value" ]]; then
    read -r -p "$prompt_text [$default_value]: " input || true
    input=${input:-$default_value}
  else
    read -r -p "$prompt_text: " input || true
  fi
  printf -v "$var_name" "%s" "$input"
}

prompt_secret() {
  local var_name=$1; shift
  local prompt_text=$1; shift
  local input
  # If variable is already set and non-empty, do nothing
  if [[ -n "${!var_name+x}" && -n "${!var_name}" ]]; then
    return 0
  fi
  read -r -s -p "$prompt_text: " input || true
  echo ""
  printf -v "$var_name" "%s" "$input"
}

maybe_test_redfish() {
  local answer
  echo "Redfish is recommended for iDRAC9 v7.00+. We'll test connectivity with HTTPS:443 using current credentials."
  read -r -p "Test Redfish connectivity now? [y/N]: " answer || true
  case "$answer" in
    y|Y)
      echo "Testing Redfish: https://$IDRAC_HOST/redfish/v1/ (self-signed allowed)"
      if curl -k -s -S -u "$IDRAC_USERNAME:$IDRAC_PASSWORD" -o /dev/null -w "%{http_code}\n" "https://$IDRAC_HOST/redfish/v1/" | grep -qE '^(200|201|202|204)$'; then
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
  echo "Deploying controller script"
  push_into_container "$(dirname "$0")/../Dell_iDRAC_fan_controller.sh" "/usr/local/bin/Dell_iDRAC_fan_controller.sh"
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
    pct restart "$VMID"
  fi
}

main() {
  need_cmd pveam
  need_cmd pct
  echo "=== iDRAC Fan Controller LXC Setup ==="

  # Container basics
  prompt_var VMID "Enter container VMID" "902"
  prompt_var HOSTNAME "Enter container hostname" "idrac-fanctl"
  # Detect storages and offer menus
  local detected_tmpl detected_rootfs
  detected_tmpl=$(list_storages_by_content 'vztmpl' | head -1)
  detected_rootfs=$(list_storages_by_content 'rootdir|container' | head -1)
  if [[ -z "$detected_tmpl" ]]; then detected_tmpl="local"; fi
  if [[ -z "$detected_rootfs" ]]; then detected_rootfs="local-lvm"; fi
  select_storage_menu TEMPLATE_STORAGE "Select template storage (supports vztmpl):" 'vztmpl' "$detected_tmpl"
  select_storage_menu ROOTFS_STORAGE "Select rootfs storage (supports container/rootdir):" 'rootdir|container' "$detected_rootfs"
  assign_default BRIDGE "vmbr0" "network bridge"
  prompt_var CT_PASSWORD "Enter container root password" "changeme"
  assign_default CPU_CORES "1" "CPU cores"
  assign_default MEMORY_MB "256" "memory (MB)"
  assign_default ROOTFS_GB "4" "rootfs size (GB)"

  # Networking
  assign_default CT_IP_MODE "dhcp" "network mode"
  case "$CT_IP_MODE" in
    static)
      prompt_var CT_IP "Static IP address" "192.168.1.250"
      prompt_var CT_MASK "CIDR mask (e.g., 24)" "24"
      prompt_var CT_GW "Gateway" "192.168.1.1"
      ;;
    *) CT_IP_MODE="dhcp" ;;
  esac

  # Controller config
  prompt_var IDRAC_HOST "Enter iDRAC IP/hostname" "192.168.1.100"
  prompt_var IDRAC_USERNAME "Enter iDRAC username" "root"
  prompt_secret IDRAC_PASSWORD "Enter iDRAC password"

  local cm
  read -r -p "Control method [auto|redfish|ipmi] (default: auto): " cm || true
  cm=${cm:-auto}
  case "$cm" in
    auto|redfish|ipmi) CONTROL_METHOD=$cm ;;
    *) CONTROL_METHOD=auto ;;
  esac
  if [[ "$CONTROL_METHOD" == "redfish" || "$CONTROL_METHOD" == "auto" ]]; then
    maybe_test_redfish
  fi

  prompt_var FAN_SPEED "Fan speed percentage (0-100)" "20"
  prompt_var CPU_TEMPERATURE_TRESHOLD "CPU temp threshold (°C)" "60"
  prompt_var CHECK_INTERVAL "Check interval (s)" "30"

  # Optional IPMI device mapping
  local map
  read -r -p "Map host /dev/ipmi0 into container? [y/N]: " map || true
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


