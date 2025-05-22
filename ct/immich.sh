#!/usr/bin/env bash

# This script automates the creation and configuration of an Immich LXC container
# on Proxmox VE. It sets up a Debian 12 (Bookworm) LXC, installs Docker and
# Docker Compose, and then deploys Immich using its official Docker Compose setup.

# Strict mode: Exit immediately if a command exits with a non-zero status.
set -o errexit
set -o errtrace
set -o nounset
set -o pipefail

# --- Global Variables and Defaults ---
# Script information
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
readonly SCRIPT_VERSION="1.0.0"

# LXC Container Defaults
CTID="" # Will be dynamically assigned if not provided
CT_HOSTNAME="immich"
CT_DESCRIPTION="Immich LXC Container"
CT_TYPE="debian"
CT_OS_TYPE="debian"
CT_OS_VERSION="12" # Debian Bookworm
CT_ARCHITECTURE="amd64"
CT_TEMPLATE_URL="https://download.proxmox.com/images/rootfs/${CT_OS_TYPE}-bookworm-standard_12.0-1_amd64.tar.zst"
CT_STORAGE="local-lvm" # Default storage for root disk
CT_DISK_SIZE="32G"     # Default disk size for Immich
CT_MEMORY="4096"       # 4GB RAM
CT_SWAP="512"          # 512MB Swap
CT_CORES="2"           # 2 CPU cores
CT_UNPRIVILEGED="yes"  # Run as unprivileged container by default
CT_FEATURES="nesting=1,fuse=1" # Nesting for Docker, Fuse for potential future needs
CT_ROOTFS_MOUNTPOINT="mp0" # Mount point for the rootfs
CT_NETWORK_BRIDGE="vmbr0" # Default network bridge
CT_IP=""               # Will use DHCP if not set
CT_GATEWAY=""          # Required if CT_IP is static
CT_VLAN=""             # VLAN tag, if applicable
CT_PASSWORD=""         # Default password for the unprivileged user (will be generated if empty)
CT_USERNAME="immich-user" # Default user for Immich LXC

# Immich Specific Variables
IMMICH_DIR="/opt/immich" # Directory where Immich will be cloned inside the CT

# Script Execution Flags
DEBUG="false" # Set to true for debug output
FORCE="false" # Set to true to bypass some interactive prompts

# --- Utility Functions ---

# Function to print a header with script information
header() {
  local title="$1"
  printf "\n%s\n" "--- ${SCRIPT_NAME} v${SCRIPT_VERSION} - ${title} ---"
}

# Function to print informational messages
msg() {
  printf "\n%s\n" "$1"
}

# Function to print warning messages
warn() {
  printf "\n\e[33m[WARN]\e[0m %s\n" "$1" >&2
}

# Function to print error messages and exit
err() {
  printf "\n\e[31m[ERROR]\e[0m %s\n" "$1" >&2
  exit 1
}

# Function to handle script exit (cleanup)
exit_hook() {
  local exit_code=$?
  if [[ "$exit_code" -ne 0 ]]; then
    warn "Script exited with error code $exit_code."
  fi
  msg "Script finished. Exiting."
}
trap exit_hook EXIT

# Function to display usage information
usage() {
  header "Usage"
  cat <<EOF
This script creates and configures an Immich LXC container on Proxmox.

Usage: ${SCRIPT_NAME} [OPTIONS]

Options:
  -i, --ctid <ID>          Proxmox Container ID (e.g., 101). If not provided,
                           the script will find the next available ID.
  -H, --hostname <NAME>    Hostname for the LXC (default: ${CT_HOSTNAME})
  -s, --storage <STORAGE>  Proxmox storage for the LXC root disk (default: ${CT_STORAGE})
  -d, --disk-size <SIZE>   Disk size for the LXC root disk (e.g., 32G, 64G) (default: ${CT_DISK_SIZE})
  -m, --memory <MB>        Memory in MB for the LXC (default: ${CT_MEMORY})
  -c, --cores <COUNT>      Number of CPU cores for the LXC (default: ${CT_CORES})
  -u, --unprivileged       Create an unprivileged container (default: ${CT_UNPRIVILEGED})
  -p, --password <PASS>    Password for the LXC user (default: randomly generated)
  -I, --ip <IP/CIDR>       Static IP address and CIDR (e.g., 192.168.1.10/24).
                           If not set, DHCP will be used.
  -g, --gateway <IP>       Gateway IP address (required if --ip is set).
  -v, --vlan <ID>          VLAN tag for the network interface.
  -b, --bridge <BRIDGE>    Network bridge (default: ${CT_NETWORK_BRIDGE})
  -D, --debug              Enable debug mode (prints verbose output).
  -f, --force              Force execution, bypass some prompts.
  -h, --help               Display this help message and exit.
EOF
  exit 0
}

# Function to check if running on Proxmox VE
pve_check() {
  msg "Checking Proxmox VE environment..."
  if ! command -v pveversion &>/dev/null; then
    err "This script must be run on a Proxmox VE host."
  fi
  msg "Proxmox VE detected: $(pveversion)"
}

# Function to check system architecture
arch_check() {
  msg "Checking system architecture..."
  local detected_arch=$(dpkg --print-architecture)
  if [[ "$detected_arch" != "$CT_ARCHITECTURE" ]]; then
    warn "Detected architecture ($detected_arch) does not match target architecture ($CT_ARCHITECTURE)."
    warn "This script is primarily tested on $CT_ARCHITECTURE. Proceed with caution."
    if [[ "$FORCE" != "true" ]]; then
      read -r -p "Do you want to continue? (y/N): " response
      if [[ ! "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
        err "Architecture mismatch. Exiting."
      fi
    fi
  fi
  msg "Architecture check passed."
}

# Function to check for required dependencies
dependency_check() {
  msg "Checking for required dependencies..."
  if ! command -v getopt &>/dev/null; then
    err "The 'getopt' command is not found. Please install it (e.g., 'apt install util-linux')."
  fi
  msg "All required dependencies are present."
}

# Function to find the next available CTID
find_next_ctid() {
  msg "Finding next available Container ID..."
  local next_id=100
  while pct status "$next_id" &>/dev/null; do
    next_id=$((next_id + 1))
  done
  CTID="$next_id"
  msg "Next available Container ID: ${CTID}"
}

# Function to download the LXC template
download_lxc_template() {
  msg "Downloading LXC template for ${CT_OS_TYPE} ${CT_OS_VERSION}..."
  if ! pveam available --section system | grep -q "${CT_OS_TYPE}-bookworm-standard"; then
    msg "Template not found locally. Downloading from ${CT_TEMPLATE_URL}..."
    pveam update
    pveam download "$CT_STORAGE" "${CT_OS_TYPE}-bookworm-standard_${CT_OS_VERSION}.0-1_${CT_ARCHITECTURE}.tar.zst" || \
      err "Failed to download LXC template. Check URL and storage."
  else
    msg "LXC template already available locally."
  fi
}

# Function to create the LXC container
create_ct() {
  header "Creating LXC Container (ID: ${CTID})"

  local pct_create_cmd=(
    pct create "$CTID" "${CT_STORAGE}:vztmpl/${CT_OS_TYPE}-bookworm-standard_${CT_OS_VERSION}.0-1_${CT_ARCHITECTURE}.tar.zst"
    --hostname "$CT_HOSTNAME"
    --description "$CT_DESCRIPTION"
    --ostype "$CT_OS_TYPE"
    --arch "$CT_ARCHITECTURE"
    --cores "$CT_CORES"
    --memory "$CT_MEMORY"
    --swap "$CT_SWAP"
    --rootfs "${CT_STORAGE}:${CT_DISK_SIZE}"
    --unprivileged "$CT_UNPRIVILEGED"
    --features "$CT_FEATURES"
    --onboot "1" # Enable start on boot
  )

  # Add network configuration
  local network_args="name=eth0,bridge=${CT_NETWORK_BRIDGE},firewall=0"
  if [[ -n "$CT_IP" ]]; then
    network_args+=",ip=${CT_IP}"
    if [[ -n "$CT_GATEWAY" ]]; then
      network_args+=",gw=${CT_GATEWAY}"
    else
      warn "Static IP provided but no gateway. This might cause network issues."
    fi
  else
    network_args+=",ip=dhcp"
  fi
  if [[ -n "$CT_VLAN" ]]; then
    network_args+=",tag=${CT_VLAN}"
  fi
  pct_create_cmd+=(--net "$network_args")

  # Set password if provided, otherwise generate one
  if [[ -z "$CT_PASSWORD" ]]; then
    CT_PASSWORD=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)
    msg "Generated password for ${CT_USERNAME}: ${CT_PASSWORD}"
  fi
  pct_create_cmd+=(--password "$CT_PASSWORD")

  msg "Executing: ${pct_create_cmd[*]}"
  "${pct_create_cmd[@]}" || err "Failed to create LXC container."

  msg "LXC Container ${CTID} created successfully."
}

# Function to start the LXC container
start_ct() {
  header "Starting LXC Container (ID: ${CTID})"
  msg "Starting container ${CTID}..."
  pct start "$CTID" || err "Failed to start LXC container ${CTID}."
  msg "Waiting for container to boot..."
  sleep 10 # Give it a moment to boot up
  msg "LXC Container ${CTID} started."
}

# Function to execute commands inside the LXC container
exec_in_ct() {
  local cmd="$*"
  msg "Executing inside CT ${CTID}: $cmd"
  pct exec "$CTID" -- bash -c "$cmd" || err "Command failed inside CT ${CTID}: $cmd"
}

# Function to install Immich inside the LXC container
install_immich() {
  header "Installing Immich inside LXC Container (ID: ${CTID})"

  msg "Updating package lists and upgrading installed packages..."
  exec_in_ct "apt update && apt upgrade -y"

  msg "Installing essential packages: curl, git, sudo..."
  exec_in_ct "apt install -y curl git sudo apt-transport-https ca-certificates gnupg lsb-release"

  msg "Adding Docker's official GPG key..."
  exec_in_ct "install -m 0755 -d /etc/apt/keyrings"
  exec_in_ct "curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg"
  exec_in_ct "chmod a+r /etc/apt/keyrings/docker.gpg"

  msg "Adding Docker repository..."
  exec_in_ct "echo \"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo \"$VERSION_CODENAME\") stable\" | tee /etc/apt/sources.list.d/docker.list > /dev/null"
  exec_in_ct "apt update"

  msg "Installing Docker Engine, CLI, Containerd, Buildx, and Compose..."
  exec_in_ct "apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"

  msg "Adding user '${CT_USERNAME}' to the docker group..."
  exec_in_ct "usermod -aG docker ${CT_USERNAME}"

  msg "Cloning Immich repository into ${IMMICH_DIR}..."
  exec_in_ct "git clone https://github.com/immich-app/immich.git ${IMMICH_DIR}"
  exec_in_ct "chown -R ${CT_USERNAME}:${CT_USERNAME} ${IMMICH_DIR}"

  msg "Navigating to Immich directory and configuring .env file..."
  exec_in_ct "cd ${IMMICH_DIR}"
  exec_in_ct "cp .env.example .env"

  msg "Generating secrets for Immich..."
  local db_password=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 20)
  local jwt_secret=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 32)

  exec_in_ct "sed -i 's/^DB_PASSWORD=.*$/DB_PASSWORD=${db_password}/' ${IMMICH_DIR}/.env"
  exec_in_ct "sed -i 's/^JWT_SECRET=.*$/JWT_SECRET=${jwt_secret}/' ${IMMICH_DIR}/.env"

  msg "Pulling Immich Docker images and starting containers..."
  exec_in_ct "cd ${IMMICH_DIR} && docker compose pull"
  exec_in_ct "cd ${IMMICH_DIR} && docker compose up -d"

  msg "Immich installation complete!"
}

# --- Main Script Logic ---
main() {
  header "Starting Immich LXC Deployment"

  # Parse command line arguments
  local PARSED_OPTIONS
  PARSED_OPTIONS=$(getopt -o i:H:s:d:m:c:up:I:g:v:b:Dfh --long ctid:,hostname:,storage:,disk-size:,memory:,cores:,unprivileged,password:,ip:,gateway:,vlan:,bridge:,debug,force,help -n "${SCRIPT_NAME}" -- "$@")

  if [[ $? -ne 0 ]]; then
    err "Failed to parse options. Use --help for usage."
  fi

  eval set -- "$PARSED_OPTIONS"

  while true; do
    case "$1" in
    -i | --ctid)
      CTID="$2"
      shift 2
      ;;
    -H | --hostname)
      CT_HOSTNAME="$2"
      shift 2
      ;;
    -s | --storage)
      CT_STORAGE="$2"
      shift 2
      ;;
    -d | --disk-size)
      CT_DISK_SIZE="$2"
      shift 2
      ;;
    -m | --memory)
      CT_MEMORY="$2"
      shift 2
      ;;
    -c | --cores)
      CT_CORES="$2"
      shift 2
      ;;
    -u | --unprivileged)
      CT_UNPRIVILEGED="yes"
      shift
      ;;
    -p | --password)
      CT_PASSWORD="$2"
      shift 2
      ;;
    -I | --ip)
      CT_IP="$2"
      shift 2
      ;;
    -g | --gateway)
      CT_GATEWAY="$2"
      shift 2
      ;;
    -v | --vlan)
      CT_VLAN="$2"
      shift 2
      ;;
    -b | --bridge)
      CT_NETWORK_BRIDGE="$2"
      shift 2
      ;;
    -D | --debug)
      DEBUG="true"
      set -x # Enable xtrace for debug output
      shift
      ;;
    -f | --force)
      FORCE="true"
      shift
      ;;
    -h | --help)
      usage
      ;;
    --)
      shift
      break
      ;;
    *)
      err "Internal error! Unhandled option: $1"
      ;;
    esac
  done

  # Pre-checks
  pve_check
  arch_check
  dependency_check

  # Find CTID if not provided
  if [[ -z "$CTID" ]]; then
    find_next_ctid
  fi

  # Validate CTID
  if pct status "$CTID" &>/dev/null; then
    warn "Container ID ${CTID} already exists."
    if [[ "$FORCE" != "true" ]]; then
      read -r -p "Do you want to overwrite it? This will destroy the existing container! (y/N): " response
      if [[ ! "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
        err "Container ID ${CTID} exists. Exiting."
      fi
    fi
    msg "Destroying existing container ${CTID}..."
    pct destroy "$CTID" --force || warn "Failed to destroy existing container ${CTID}. Proceeding anyway, but this might cause issues."
  fi

  # Download template if not present
  download_lxc_template

  # Create, start, and install Immich
  create_ct
  start_ct
  install_immich

  # Post-installation summary
  header "Immich LXC Deployment Complete!"
  msg "Immich LXC Container ID: ${CTID}"
  msg "Hostname: ${CT_HOSTNAME}"
  msg "LXC Username: ${CT_USERNAME}"
  if [[ -n "$CT_PASSWORD" ]]; then
    msg "LXC Password (for ${CT_USERNAME}): ${CT_PASSWORD}"
  else
    msg "LXC Password was not set via --password. You can set it manually via 'pct set ${CTID} --password <YOUR_PASSWORD>'."
  fi

  local final_ip
  if [[ -n "$CT_IP" ]]; then
    final_ip=$(echo "$CT_IP" | cut -d'/' -f1)
  else
    msg "Attempting to retrieve DHCP assigned IP for ${CTID}..."
    # Loop to wait for IP to be assigned via DHCP
    local max_attempts=10
    local attempt=0
    while [[ "$attempt" -lt "$max_attempts" ]]; do
      final_ip=$(pct exec "$CTID" -- ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
      if [[ -n "$final_ip" ]]; then
        break
      fi
      sleep 5
      attempt=$((attempt + 1))
    done

    if [[ -z "$final_ip" ]]; then
      warn "Could not automatically retrieve IP address. You may need to check it manually using 'pct exec ${CTID} -- ip a'."
      final_ip="<LXC_IP_ADDRESS>"
    fi
  fi

  msg "Access Immich at: http://${final_ip}:2283"
  msg "You can also access the LXC via SSH: ssh ${CT_USERNAME}@${final_ip}"
  msg "Remember to configure your reverse proxy and SSL if you plan to expose Immich to the internet."
  msg "For further configuration, connect to the LXC and navigate to ${IMMICH_DIR}."
  msg "Consider setting up a bind mount for your Immich library outside the CT for persistent storage."
}

# Run the main function
main "$@"
