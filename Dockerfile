FROM ubuntu:22.04

LABEL org.opencontainers.image.authors="tigerblue77"

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ipmitool curl jq ca-certificates \
 && rm -rf /var/lib/apt/lists/*

ADD Dell_iDRAC_fan_controller.sh /Dell_iDRAC_fan_controller.sh

RUN chmod 0777 /Dell_iDRAC_fan_controller.sh

# you should override these default values when running. See README.md
#ENV IDRAC_HOST 192.168.1.100
ENV IDRAC_HOST local
#ENV IDRAC_USERNAME root
#ENV IDRAC_PASSWORD calvin
# Controls which API to use: ipmi | redfish | auto
ENV CONTROL_METHOD auto
ENV FAN_SPEED 5
ENV CPU_TEMPERATURE_TRESHOLD 50
ENV CHECK_INTERVAL 60

CMD ["/Dell_iDRAC_fan_controller.sh"]
