#!/usr/bin/env bash

# Script to create Proxmox LXC for Immich
# Based on tteck's Proxmox VE Helper Scripts: https://tteck.github.io/Proxmox/
# and community-scripts: https://github.com/community-scripts/ProxmoxVE

# Copyright (c) 2021-2024 tteck
# Author: tteck (tteckster)
# License: MIT
# https://github.com/tteck/Proxmox/raw/main/LICENSE

# Copyright (c) 2025 TranQUiL
# Adapted for Immich

# Source the build functions
source <(curl -s https://raw.githubusercontent.com/tteck/Proxmox/main/misc/build.func)

# Header
function header_info {
  clear
  cat <<"EOF"
  _____                     _   
 |_   _|                   | |  
   | |  _ __ ___  _ __ ___   ___| |__ 
   | | | '_ ` _ \ | '_ ` _ \ / __| '_ \
  _| |_| | | | | || | | | | | (__| | | |
 |_____|_| |_| |_||_| |_| |_|\___|_| |_|

EOF
}

header_info
echo -e "Loading..."

# Application Name
APP="Immich"
var_disk="32" # Immich can use a lot of storage for photos, videos, thumbnails, and database
var_cpu="4"   # Recommended 4 cores for transcoding and machine learning
var_ram="6144" # Recommended 6GB RAM (6144MB), minimum 4GB
var_os="debian"
var_version="12" # Debian 12 (Bookworm)

# Set variables
variables # This function is from build.func to process/display variables

# Color codes (from build.func)
color

# Error catching (from build.func)
catch_errors

# Default settings for LXC
function default_settings() {
  CT_TYPE="1" # Unprivileged container
  PW="" # Will be prompted by build_container if not set
  CT_ID=$NEXTID
  HN=$NSAPP # Hostname e.g., immich
  DISK_SIZE="$var_disk"
  CORE_COUNT="$var_cpu"
  RAM_SIZE="$var_ram"
  BRG="vmbr0" # Default bridge
  NET="dhcp"  # Default network
  GATE=""
  APT_CACHER=""
  APT_CACHER_IP=""
  DISABLEIP6="no"
  MTU=""
  SD=""
  NS=""
  MAC=""
  VLAN=""
  SSH="no" # Disable SSH by default, can be enabled in advanced
  VERB="no"
  echo_default # From build.func
}

# Update script function (placeholder, can be adapted for future updates)
# For now, this script is for initial installation.
function update_script() {
  if [[ ! -d /opt/immich ]]; then # A simple check if Immich directory exists
    msg_error "No ${APP} installation found to update."
    exit 1
  fi
  # Actual update logic would go here.
  # For Immich, updates are usually done by pulling the latest git release and re-running install/build steps.
  # This is complex and best handled by a dedicated update mechanism or manual steps from Immich docs.
  msg_info "Updating ${APP} is not yet automated by this script. Please refer to Immich documentation."
  exit 0
}

# Start the main process (dialogs, LXC creation)
start # From build.func - this will handle user input for basic/advanced setup

# Build the container
build_container # From build.func

# Install Immich inside the container
msg_info "Preparing to install ${APP} in LXC ID ${CTID}..."
msg_info "This process will take a significant amount of time (15-45+ minutes depending on system and network speed)."

# Commands to install Docker and Immich inside the LXC
# These commands are adapted from the original `immich.sh` and Immich documentation
pct exec $CTID -- bash -c "
  # Update and install dependencies
  apt-get update -qqy
  apt-get install -qqy --no-install-recommends curl git ca-certificates gnupg lsb-release

  # Install Docker
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo 'deb [arch=\"$(dpkg --print-architecture)\" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \"$(. /etc/os-release && echo \"$VERSION_CODENAME\")\" stable' | tee /etc/apt/sources.list.d/docker.list > /dev/null
  apt-get update -qqy
  apt-get install -qqy docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  # Prepare Immich directory
  mkdir -p /opt/immich
  cd /opt/immich

  # Download Immich Docker Compose files
  curl -sSL https://raw.githubusercontent.com/immich-app/immich/main/docker/docker-compose.yml -o docker-compose.yml
  curl -sSL https://raw.githubusercontent.com/immich-app/immich/main/docker/.env.example -o .env

  # Generate a random PostgreSQL password
  DB_PASSWORD=\$(openssl rand -base64 32)
  sed -i \"s|DB_PASSWORD=immich|DB_PASSWORD=\$DB_PASSWORD|\" .env

  # Start Immich containers
  docker compose up -d
"

if [ $? -eq 0 ]; then
  msg_ok "${APP} installation script executed."
else
  msg_error "Failed to execute ${APP} installation script. Check LXC console (pct enter ${CTID})."
  exit 1
fi

# Show description (IP address, etc.)
description # From build.func

msg_ok "Completed Successfully!\n"
echo -e "${APP} should be accessible at ${BL}http://${IP}:2283${CL}."
echo -e "The first user to register on the web interface will become the admin."
echo -e "Refer to the LXC console (${CYAN}pct enter ${CTID}${CL}) for detailed installation logs."
