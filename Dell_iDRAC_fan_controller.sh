#!/bin/bash

# Define global functions
# Control method selection: ipmi | redfish | auto (try ipmi then redfish)
CONTROL_METHOD=${CONTROL_METHOD:-auto}

# Helper: Redfish POST with multiple fallback endpoints/payloads
redfish_post () {
  local endpoint
  local payload="$2"
  local -a endpoints=(
    "https://$IDRAC_HOST/redfish/v1/Managers/iDRAC.Embedded.1/Oem/Dell/DellLCService/Actions/DellLCService.$1"
    "https://$IDRAC_HOST/redfish/v1/Dell/Managers/iDRAC.Embedded.1/DellLCService/Actions/DellLCService.$1"
  )
  for endpoint in "${endpoints[@]}"; do
    curl -k -s -S -u "$IDRAC_USERNAME:$IDRAC_PASSWORD" \
      -H "Content-Type: application/json" \
      -X POST "$endpoint" -d "$payload" -o /dev/null -w "%{http_code}" | grep -qE '^(200|201|202|204)$' && return 0
  done
  return 1
}

# Redfish: enable manual control and set speed
redfish_apply_user_profile () {
  # Try to enable manual override (best-effort; ignore failure if not required on model)
  redfish_post SetFanControlOverride '{"Enable": true}' || true

  # Try multiple payload shapes for SetFanSpeed across firmware variants
  if redfish_post SetFanSpeed "{\"FanSpeed\": $DECIMAL_FAN_SPEED}"; then
    CURRENT_FAN_CONTROL_PROFILE="User static fan control profile ($DECIMAL_FAN_SPEED%)"
    return 0
  fi
  if redfish_post SetFanSpeed "{\"Percent\": $DECIMAL_FAN_SPEED}"; then
    CURRENT_FAN_CONTROL_PROFILE="User static fan control profile ($DECIMAL_FAN_SPEED%)"
    return 0
  fi
  if redfish_post SetFanSpeed "{\"Target\": \"All\", \"Percent\": $DECIMAL_FAN_SPEED}"; then
    CURRENT_FAN_CONTROL_PROFILE="User static fan control profile ($DECIMAL_FAN_SPEED%)"
    return 0
  fi
  return 1
}

# Redfish: restore iDRAC automatic control
redfish_apply_dell_profile () {
  # Try explicit override disable
  if redfish_post SetFanControlOverride '{"Enable": false}'; then
    CURRENT_FAN_CONTROL_PROFILE="Dell default dynamic fan control profile"
    return 0
  fi
  # Some firmwares accept a special value to clear manual speed
  if redfish_post SetFanSpeed '{"FanSpeed": null}'; then
    CURRENT_FAN_CONTROL_PROFILE="Dell default dynamic fan control profile"
    return 0
  fi
  return 1
}
# This function applies Dell's default dynamic fan control profile
apply_Dell_profile () {
  case "$CONTROL_METHOD" in
    ipmi)
      ipmitool -I $LOGIN_STRING raw 0x30 0x30 0x01 0x01 > /dev/null && {
        CURRENT_FAN_CONTROL_PROFILE="Dell default dynamic fan control profile"; return 0; }
      return 1
      ;;
    redfish)
      redfish_apply_dell_profile
      return $?
      ;;
    auto|*)
      ipmitool -I $LOGIN_STRING raw 0x30 0x30 0x01 0x01 > /dev/null && {
        CURRENT_FAN_CONTROL_PROFILE="Dell default dynamic fan control profile"; return 0; }
      redfish_apply_dell_profile
      return $?
      ;;
  esac
}

# This function applies a user-specified static fan control profile
apply_user_profile () {
  case "$CONTROL_METHOD" in
    ipmi)
      ipmitool -I $LOGIN_STRING raw 0x30 0x30 0x01 0x00 > /dev/null && \
      ipmitool -I $LOGIN_STRING raw 0x30 0x30 0x02 0xff $HEXADECIMAL_FAN_SPEED > /dev/null && {
        CURRENT_FAN_CONTROL_PROFILE="User static fan control profile ($DECIMAL_FAN_SPEED%)"; return 0; }
      return 1
      ;;
    redfish)
      redfish_apply_user_profile
      return $?
      ;;
    auto|*)
      ipmitool -I $LOGIN_STRING raw 0x30 0x30 0x01 0x00 > /dev/null && \
      ipmitool -I $LOGIN_STRING raw 0x30 0x30 0x02 0xff $HEXADECIMAL_FAN_SPEED > /dev/null && {
        CURRENT_FAN_CONTROL_PROFILE="User static fan control profile ($DECIMAL_FAN_SPEED%)"; return 0; }
      redfish_apply_user_profile
      return $?
      ;;
  esac
}

# Prepare traps in case of container exit
gracefull_exit () {
  apply_Dell_profile
  echo "/!\ WARNING /!\ Container stopped, Dell default dynamic fan control profile applied for safety."
  exit 0
}

# Trap the signals for container exit and run gracefull_exit function
trap 'gracefull_exit' SIGQUIT SIGKILL SIGTERM

# Prepare, format and define initial variables

# Check if FAN_SPEED variable is in hexadecimal format, if not convert it to hexadecimal
if [[ $FAN_SPEED == 0x* ]]
then
  DECIMAL_FAN_SPEED=$(printf '%d' $FAN_SPEED)
  HEXADECIMAL_FAN_SPEED=$FAN_SPEED
else
  DECIMAL_FAN_SPEED=$FAN_SPEED
  HEXADECIMAL_FAN_SPEED=$(printf '0x%02x' $FAN_SPEED)
fi

# Log main informations given to the container
echo "Idrac host: $IDRAC_HOST"
echo "Control method: $CONTROL_METHOD"

# Check if the Idrac host is set to 'local', and set the LOGIN_STRING accordingly
if [[ $IDRAC_HOST == "local" ]]
then
  LOGIN_STRING='open'
else
  echo "Idrac username: $IDRAC_USERNAME"
  echo "Idrac password: $IDRAC_PASSWORD"
  LOGIN_STRING="lanplus -H $IDRAC_HOST -U $IDRAC_USERNAME -P $IDRAC_PASSWORD"
fi

# Log the fan speed objective, CPU temperature threshold, and check interval
echo "Fan speed objective: $DECIMAL_FAN_SPEED%"
echo "CPU temperature treshold: $CPU_TEMPERATURE_TRESHOLD°C"
echo "Check interval: ${CHECK_INTERVAL}s"
echo ""

# Define the interval for printing
readonly TABLE_HEADER_PRINT_INTERVAL=10
i=$TABLE_HEADER_PRINT_INTERVAL
IS_DELL_PROFILE_APPLIED=true

# Start monitoring
while true; do
  # Sleep for the specified interval before taking another reading
  sleep $CHECK_INTERVAL &
  SLEEP_PROCESS_PID=$!

  # Retrieve sensor data using ipmitool
  DATA=$(ipmitool -I $LOGIN_STRING sdr type temperature | grep degrees)
  INLET_TEMPERATURE=$(echo "$DATA" | grep Inlet | grep -Po '\d{2}' | tail -1)
  EXHAUST_TEMPERATURE=$(echo "$DATA" | grep Exhaust | grep -Po '\d{2}' | tail -1)
  CPU_DATA=$(echo "$DATA" | grep "3\." | grep -Po '\d{2}')
  CPU1_TEMPERATURE=$(echo $CPU_DATA | awk '{print $1;}')
  CPU2_TEMPERATURE=$(echo $CPU_DATA | awk '{print $2;}')

  # Define functions to check if CPU1 and CPU2 temperatures are above the threshold
  CPU1_OVERHEAT () { [ $CPU1_TEMPERATURE -gt $CPU_TEMPERATURE_TRESHOLD ]; }
  CPU2_OVERHEAT () { [ $CPU2_TEMPERATURE -gt $CPU_TEMPERATURE_TRESHOLD ]; }

  # Initialize a variable to store comments
  COMMENT=" -"
  # Check if CPU1 is overheating and apply Dell profile if true
  if CPU1_OVERHEAT
  then
    apply_Dell_profile
    # Set the flag to indicate that Dell profile is applied
    if ! $IS_DELL_PROFILE_APPLIED
    then
      IS_DELL_PROFILE_APPLIED=true
    fi

    if CPU2_OVERHEAT
    then
      COMMENT="CPU 1 and CPU 2 temperatures are too high, Dell default dynamic fan control profile applied for safety"
    else
      COMMENT="CPU 1 temperature is too high, Dell default dynamic fan control profile applied for safety"
    fi
  else
    # Check if CPU2 is overheating and apply Dell profile if true
    if CPU2_OVERHEAT
    then
      apply_Dell_profile
      if ! $IS_DELL_PROFILE_APPLIED
      then
        IS_DELL_PROFILE_APPLIED=true
      fi
      COMMENT="CPU 2 temperature is too high, Dell default dynamic fan control profile applied for safety"
    else
      # Check if user profile is applied and apply it if not
      if $IS_DELL_PROFILE_APPLIED
      then
        apply_user_profile
        IS_DELL_PROFILE_APPLIED=false
      fi
    fi
  fi
  # Print the results, including the current fan control profile and comment
  if [ $i -eq $TABLE_HEADER_PRINT_INTERVAL ]
  then
    echo "Time                CPU1    CPU2    Inlet    Exhaust    Fan Control Profile                                 Comment"
    i=0
  fi
  echo "$(date +%T)    $CPU1_TEMPERATURE°C    $CPU2_TEMPERATURE°C    $INLET_TEMPERATURE°C    $EXHAUST_TEMPERATURE°C    $CURRENT_FAN_CONTROL_PROFILE    $COMMENT"
  i=$(($i+1))
  wait $SLEEP_PROCESS_PID
done

