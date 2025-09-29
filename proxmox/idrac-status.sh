#!/bin/bash
set -euo pipefail

# Load environment variables
if [[ -f /etc/default/idrac-fan-controller ]]; then
  source /etc/default/idrac-fan-controller
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== iDRAC Fan Controller Status ===${NC}"
echo "Host: $IDRAC_HOST"
echo "Username: $IDRAC_USERNAME"
echo "Control Method: $CONTROL_METHOD"
echo "Target Fan Speed: $FAN_SPEED%"
echo "CPU Temperature Threshold: $CPU_TEMPERATURE_TRESHOLD°C"
echo "Check Interval: $CHECK_INTERVAL seconds"
echo ""

# Check service status
echo -e "${BLUE}=== Service Status ===${NC}"
if systemctl is-active --quiet idrac-fan-controller; then
  echo -e "Service Status: ${GREEN}RUNNING${NC}"
else
  echo -e "Service Status: ${RED}STOPPED${NC}"
fi

if systemctl is-enabled --quiet idrac-fan-controller; then
  echo -e "Service Enabled: ${GREEN}YES${NC}"
else
  echo -e "Service Enabled: ${RED}NO${NC}"
fi

# Show recent logs
echo -e "\n${BLUE}=== Recent Logs (last 10 lines) ===${NC}"
journalctl -u idrac-fan-controller --no-pager -n 10 --since "5 minutes ago" || echo "No recent logs"

echo -e "\n${BLUE}=== Current Readings ===${NC}"

# Function to get all temperature and fan readings via Redfish
get_thermal_data_redfish() {
  local thermal_data
  thermal_data=$(curl -k -s -u "$IDRAC_USERNAME:$IDRAC_PASSWORD" "https://$IDRAC_HOST/redfish/v1/Chassis/System.Embedded.1/Thermal" 2>/dev/null)
  
  if [[ -n "$thermal_data" ]]; then
    echo "=== Temperature Sensors ==="
    echo "$thermal_data" | jq -r '.Temperatures[]? | "\(.Name): \(.ReadingCelsius)°C"' 2>/dev/null || echo "Failed to parse temperature data"
    
    echo -e "\n=== Fan Sensors ==="
    # Show RPM values (since .Reading contains RPM, not percentage)
    echo "$thermal_data" | jq -r '.Fans[]? | "\(.Name): \(.Reading // "n/a") RPM"' 2>/dev/null || echo "Failed to parse fan data"
    
    # Get the highest CPU temperature
    local max_cpu_temp
    max_cpu_temp=$(echo "$thermal_data" | jq -r '.Temperatures[]? | select(.Name | test("CPU"; "i")) | .ReadingCelsius' 2>/dev/null | sort -n | tail -1)
    
    # Get average fan RPM (since .Reading contains RPM values)
    local avg_fan_rpm
    avg_fan_rpm=$(echo "$thermal_data" | jq -r '.Fans[]? | .Reading' 2>/dev/null | awk '{sum+=$1; count++} END {if(count>0) print sum/count; else print "N/A"}')
    
    # Calculate approximate percentage from RPM (assuming max RPM is around 15000)
    local avg_fan_percent
    if [[ "$avg_fan_rpm" != "N/A" && "$avg_fan_rpm" =~ ^[0-9]+\.?[0-9]*$ ]]; then
      avg_fan_percent=$(echo "scale=1; ($avg_fan_rpm / 15000) * 100" | bc 2>/dev/null || echo "N/A")
    else
      avg_fan_percent="N/A"
    fi
    
    echo "$max_cpu_temp|$avg_fan_percent|$avg_fan_rpm"
  else
    echo "N/A|N/A|N/A"
  fi
}

# Function to get temperature via IPMI
get_temp_ipmi() {
  local temp
  temp=$(ipmitool -I lanplus -H "$IDRAC_HOST" -U "$IDRAC_USERNAME" -P "$IDRAC_PASSWORD" sdr type temperature 2>/dev/null | grep -E "CPU|Ambient" | head -1 | awk '{print $4}' | sed 's/[^0-9.]//g')
  if [[ -n "$temp" && "$temp" != "" ]]; then
    echo "$temp"
  else
    echo "N/A"
  fi
}

# Function to get fan speed via IPMI (returns percentage)
get_fan_ipmi() {
  local fan_speed
  fan_speed=$(ipmitool -I lanplus -H "$IDRAC_HOST" -U "$IDRAC_USERNAME" -P "$IDRAC_PASSWORD" sdr type fan 2>/dev/null | head -1 | awk '{print $4}' | sed 's/[^0-9.]//g')
  if [[ -n "$fan_speed" && "$fan_speed" != "" ]]; then
    echo "$fan_speed"
  else
    echo "N/A"
  fi
}

# Try to get readings based on control method
if [[ "$CONTROL_METHOD" == "redfish" ]]; then
  echo "Using Redfish method..."
  thermal_result=$(get_thermal_data_redfish)
  temp=$(echo "$thermal_result" | cut -d'|' -f1)
  fan_percent=$(echo "$thermal_result" | cut -d'|' -f2)
  fan_rpm=$(echo "$thermal_result" | cut -d'|' -f3)
elif [[ "$CONTROL_METHOD" == "ipmi" ]]; then
  echo "Using IPMI method..."
  temp=$(get_temp_ipmi)
  fan_percent=$(get_fan_ipmi)
  fan_rpm="N/A"
else
  # Auto mode - try Redfish first, then IPMI
  echo "Using auto mode (trying Redfish first)..."
  thermal_result=$(get_thermal_data_redfish)
  temp=$(echo "$thermal_result" | cut -d'|' -f1)
  fan_percent=$(echo "$thermal_result" | cut -d'|' -f2)
  fan_rpm=$(echo "$thermal_result" | cut -d'|' -f3)
  
  if [[ "$temp" == "N/A" || "$fan_percent" == "N/A" ]]; then
    echo "Redfish failed, trying IPMI..."
    temp=$(get_temp_ipmi)
    fan_percent=$(get_fan_ipmi)
    fan_rpm="N/A"
  fi
fi

# Display readings with color coding
if [[ "$temp" != "N/A" ]]; then
  if command -v bc >/dev/null 2>&1 && [[ "$temp" =~ ^[0-9]+\.?[0-9]*$ ]]; then
    if (( $(echo "$temp > $CPU_TEMPERATURE_TRESHOLD" | bc -l) )); then
      echo -e "Max CPU Temperature: ${RED}${temp}°C${NC} (above threshold)"
    else
      echo -e "Max CPU Temperature: ${GREEN}${temp}°C${NC}"
    fi
  else
    echo -e "Max CPU Temperature: ${GREEN}${temp}°C${NC}"
  fi
else
  echo -e "Max CPU Temperature: ${YELLOW}N/A${NC}"
fi

if [[ "$fan_percent" != "N/A" ]]; then
  echo -e "Average Fan Speed: ${GREEN}${fan_percent}%${NC}"
else
  echo -e "Average Fan Speed: ${YELLOW}N/A${NC}"
fi

if [[ "$fan_rpm" != "N/A" ]]; then
  echo -e "Average Fan RPM: ${GREEN}${fan_rpm}${NC}"
else
  echo -e "Average Fan RPM: ${YELLOW}N/A${NC}"
fi

echo -e "\n${BLUE}=== Usage ===${NC}"
echo "Run 'idrac-status' to see this status information"
echo "Run 'journalctl -u idrac-fan-controller -f' to follow live logs"
echo "Run 'systemctl status idrac-fan-controller' for detailed service status"
