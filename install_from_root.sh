#!/bin/bash
#
# Vajar LMS - DigitalOcean Installer
# https://github.com/bariqid/vajar-lms
#
# Usage: curl -fsSL https://raw.githubusercontent.com/bariqid/vajar-lms/master/deploy/install_do.sh | bash
#
# This script is designed for DigitalOcean droplets where default user is root.
# It creates an 'ubuntu' user with passwordless sudo and SSH key access,
# then runs the main installation as that user.
#

set -e

# ============================================
# COLORS & FORMATTING
# ============================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# ============================================
# GLOBAL VARIABLES
# ============================================
SCRIPT_VERSION="1.0.0"
TARGET_USER="ubuntu"
INSTALL_SCRIPT_URL="https://raw.githubusercontent.com/bariqid/open-lms/refs/heads/main/install.sh"
LOG_FILE="/var/log/lms-install-do.log"

# ============================================
# HELPER FUNCTIONS
# ============================================
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

log_warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$LOG_FILE"
}

print_banner() {
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║                                                               ║"
    echo "║   ██╗   ██╗ █████╗      ██╗ █████╗ ██████╗                    ║"
    echo "║   ██║   ██║██╔══██╗     ██║██╔══██╗██╔══██╗                   ║"
    echo "║   ██║   ██║███████║     ██║███████║██████╔╝                   ║"
    echo "║   ╚██╗ ██╔╝██╔══██║██   ██║██╔══██║██╔══██╗                   ║"
    echo "║    ╚████╔╝ ██║  ██║╚█████╔╝██║  ██║██║  ██║                   ║"
    echo "║     ╚═══╝  ╚═╝  ╚═╝ ╚════╝ ╚═╝  ╚═╝╚═╝  ╚═╝                   ║"
    echo "║                                                               ║"
    echo "║      DigitalOcean Installer v${SCRIPT_VERSION}                         ║"
    echo "║                                                               ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# ============================================
# USER CREATION FUNCTIONS
# ============================================
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

check_os() {
    if [[ ! -f /etc/os-release ]]; then
        log_error "Cannot detect OS. This script requires Ubuntu 20.04+"
        exit 1
    fi
    
    . /etc/os-release
    
    if [[ "$ID" != "ubuntu" ]]; then
        log_error "This script requires Ubuntu. Detected: $ID"
        exit 1
    fi
    
    if [[ "${VERSION_ID%%.*}" -lt 20 ]]; then
        log_error "This script requires Ubuntu 20.04+. Detected: $VERSION_ID"
        exit 1
    fi
    
    log "✓ Operating System: Ubuntu $VERSION_ID"
}

user_exists() {
    id "$TARGET_USER" &>/dev/null
}

create_ubuntu_user() {
    log_info "Creating user '$TARGET_USER'..."
    
    # Create user with home directory
    useradd -m -s /bin/bash "$TARGET_USER"
    
    # Add to sudo group
    usermod -aG sudo "$TARGET_USER"
    
    # Add to docker group (will be created later by Docker install)
    # We'll add this after Docker is installed
    
    log "✓ User '$TARGET_USER' created"
}

setup_passwordless_sudo() {
    log_info "Configuring passwordless sudo for '$TARGET_USER'..."
    
    # Create sudoers file for the user
    echo "$TARGET_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$TARGET_USER"
    chmod 440 "/etc/sudoers.d/$TARGET_USER"
    
    # Validate sudoers file
    if visudo -c -f "/etc/sudoers.d/$TARGET_USER" &>/dev/null; then
        log "✓ Passwordless sudo configured"
    else
        log_error "Failed to configure sudoers file"
        rm -f "/etc/sudoers.d/$TARGET_USER"
        exit 1
    fi
}

copy_ssh_keys() {
    log_info "Copying SSH authorized_keys from root to '$TARGET_USER'..."
    
    local root_ssh_dir="/root/.ssh"
    local user_ssh_dir="/home/$TARGET_USER/.ssh"
    
    # Check if root has SSH keys
    if [[ ! -f "$root_ssh_dir/authorized_keys" ]]; then
        log_warn "No authorized_keys found in /root/.ssh/"
        log_warn "You may need to manually configure SSH access for '$TARGET_USER'"
        return 0
    fi
    
    # Create .ssh directory for user
    mkdir -p "$user_ssh_dir"
    chmod 700 "$user_ssh_dir"
    
    # Copy authorized_keys
    cp "$root_ssh_dir/authorized_keys" "$user_ssh_dir/authorized_keys"
    chmod 600 "$user_ssh_dir/authorized_keys"
    
    # Set ownership
    chown -R "$TARGET_USER:$TARGET_USER" "$user_ssh_dir"
    
    # Count keys copied
    local key_count=$(wc -l < "$user_ssh_dir/authorized_keys")
    log "✓ Copied $key_count SSH key(s) to '$TARGET_USER'"
}

setup_user() {
    echo -e "\n${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}[1/3]${NC} ${BOLD}Setting up '$TARGET_USER' user${NC}"
    echo -e "${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    
    if user_exists; then
        log "✓ User '$TARGET_USER' already exists"
    else
        create_ubuntu_user
    fi
    
    setup_passwordless_sudo
    copy_ssh_keys
}

# ============================================
# DOCKER GROUP SETUP
# ============================================
add_user_to_docker_group() {
    if getent group docker &>/dev/null; then
        if ! groups "$TARGET_USER" | grep -q docker; then
            log_info "Adding '$TARGET_USER' to docker group..."
            usermod -aG docker "$TARGET_USER"
            log "✓ User added to docker group"
        fi
    fi
}

# ============================================
# INSTALLATION FUNCTIONS
# ============================================
download_install_script() {
    echo -e "\n${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}[2/3]${NC} ${BOLD}Downloading main installation script${NC}"
    echo -e "${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    
    local install_dir="/home/$TARGET_USER"
    local install_script="$install_dir/install.sh"
    
    log_info "Downloading install.sh..."
    
    if command -v curl &>/dev/null; then
        curl -fsSL "$INSTALL_SCRIPT_URL" -o "$install_script"
    elif command -v wget &>/dev/null; then
        wget -q "$INSTALL_SCRIPT_URL" -O "$install_script"
    else
        log_error "Neither curl nor wget is available. Please install one of them."
        exit 1
    fi
    
    chmod +x "$install_script"
    chown "$TARGET_USER:$TARGET_USER" "$install_script"
    
    log "✓ Installation script downloaded to $install_script"
}

copy_config_file() {
    # Check if config file exists in current directory
    if [[ -f "./initial.config" ]]; then
        log_info "Copying initial.config to user home..."
        cp "./initial.config" "/home/$TARGET_USER/initial.config"
        chown "$TARGET_USER:$TARGET_USER" "/home/$TARGET_USER/initial.config"
        log "✓ Config file copied"
    else
        log_warn "No initial.config found in current directory"
        log_info "You can create one in /home/$TARGET_USER/ before running install.sh"
    fi
}

run_installation_as_user() {
    echo -e "\n${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}[3/3]${NC} ${BOLD}Running installation as '$TARGET_USER'${NC}"
    echo -e "${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    
    log_info "Switching to '$TARGET_USER' and running installation..."
    log_info "Installation will continue with root privileges via sudo..."
    
    # Run the install script as the target user with sudo
    # The install script itself checks for root and runs with sudo internally
    cd "/home/$TARGET_USER"
    
    # Execute the script as the ubuntu user
    # The script will use sudo internally for privileged operations
    sudo -u "$TARGET_USER" bash -c "cd /home/$TARGET_USER && sudo ./install.sh"
    
    # After installation, add user to docker group
    add_user_to_docker_group
}

# ============================================
# POST INSTALLATION
# ============================================
print_post_install_info() {
    echo -e "\n${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}                    SETUP COMPLETE!                            ${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${CYAN}User '$TARGET_USER' has been created with:${NC}"
    echo -e "  • Passwordless sudo access"
    echo -e "  • SSH keys copied from root"
    echo -e "  • Docker group membership"
    echo ""
    echo -e "${YELLOW}You can now SSH as '$TARGET_USER':${NC}"
    echo -e "  ssh $TARGET_USER@<your-server-ip>"
    echo ""
    echo -e "${YELLOW}For security, consider disabling root SSH login:${NC}"
    echo -e "  1. Edit /etc/ssh/sshd_config"
    echo -e "  2. Set: PermitRootLogin no"
    echo -e "  3. Restart SSH: systemctl restart sshd"
    echo ""
}

# ============================================
# MAIN EXECUTION
# ============================================
main() {
    # Initialize log file
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    
    print_banner
    
    # Pre-flight checks
    check_root
    check_os
    
    # Check if we're on DigitalOcean (optional, just for info)
    if [[ -f /etc/digitalocean ]]; then
        log_info "DigitalOcean droplet detected"
    fi
    
    # Setup user
    setup_user
    
    # Download and prepare installation
    download_install_script
    copy_config_file
    
    # Run the main installation
    run_installation_as_user
    
    # Print completion info
    print_post_install_info
    
    log "✓ DigitalOcean setup completed successfully!"
}

# Run main function
main "$@"
