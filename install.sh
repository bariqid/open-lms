#!/bin/bash
#
# Vajar LMS - Single Script Installer
# https://github.com/bariqid/vajar-lms
#
# Usage: curl -fsSL https://raw.githubusercontent.com/bariqid/vajar-lms/master/deploy/install.sh | bash
#
# This script installs and configures Vajar LMS on a fresh Ubuntu 20.04+ server
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
DOCKER_IMAGE="bariqid/vajar_lms_image:latest"
APP_DIR="/opt/lms-app"
BACKUP_DIR="/opt/lms-backups"
LOG_FILE="/var/log/lms-install.log"
GITHUB_RAW_URL="https://raw.githubusercontent.com/bariqid/vajar-lms/master/deploy"

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
    echo "║          Learning Management System Installer v${SCRIPT_VERSION}          ║"
    echo "║                                                               ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_step() {
    local step=$1
    local total=$2
    local message=$3
    echo -e "\n${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}[${step}/${total}]${NC} ${BOLD}${message}${NC}"
    echo -e "${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

generate_password() {
    openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 24
}

generate_app_key() {
    echo "base64:$(openssl rand -base64 32)"
}

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

check_resources() {
    local mem_total=$(free -m | awk '/^Mem:/{print $2}')
    local cpu_cores=$(nproc)
    local disk_free=$(df -BG / | awk 'NR==2 {print $4}' | tr -d 'G')
    
    log_info "System Resources:"
    log_info "  CPU Cores: $cpu_cores"
    log_info "  RAM: ${mem_total}MB"
    log_info "  Free Disk: ${disk_free}GB"
    
    if [[ $mem_total -lt 1800 ]]; then
        log_error "Minimum 2GB RAM required. Available: ${mem_total}MB"
        exit 1
    fi
    
    if [[ $disk_free -lt 10 ]]; then
        log_error "Minimum 10GB free disk space required. Available: ${disk_free}GB"
        exit 1
    fi
    
    # Set performance tier based on RAM
    if [[ $mem_total -ge 14000 ]]; then
        PERFORMANCE_TIER="large"
        PHP_FPM_WORKERS=100
        MYSQL_BUFFER="2G"
        REDIS_MEMORY="1gb"
    elif [[ $mem_total -ge 6000 ]]; then
        PERFORMANCE_TIER="medium"
        PHP_FPM_WORKERS=50
        MYSQL_BUFFER="1G"
        REDIS_MEMORY="512mb"
    else
        PERFORMANCE_TIER="small"
        PHP_FPM_WORKERS=20
        MYSQL_BUFFER="512M"
        REDIS_MEMORY="256mb"
    fi
    
    log "✓ Performance tier: $PERFORMANCE_TIER (PHP workers: $PHP_FPM_WORKERS)"
}

# ============================================
# CONFIGURATION FILE HANDLING
# ============================================
CONFIG_FILE="./initial.config"

# Sample config file content for reference
create_sample_config() {
    cat << 'EOF'
# Vajar LMS Installation Configuration
# =====================================
# Create this file as 'initial.config' in the same directory as install.sh
# Then run: ./install.sh
#
# All fields are required unless marked as [optional]

# Domain name for the LMS (required)
DOMAIN=lms.yourschool.sch.id

# Admin credentials (required)
ADMIN_USERNAME=admin
ADMIN_EMAIL=admin@yourschool.sch.id
ADMIN_PASSWORD=YourSecurePassword123

# School/Institution name (required)
SCHOOL_NAME=SMK Example School

# School Level (required)
# SD = Elementary School (grades 1-6, Major: Umum)
# SMP = Junior High School (grades 7-9, Major: Umum)
# SMA = Senior High School (grades 10-12, Majors: IPA, IPS, Bahasa)
# SMK = Vocational High School (grades 10-12, Majors: RPL, TKJ, TEI, TE, TKR, AP)
SCHOOL_LEVEL=SMK

# Database password [optional - auto-generated if empty]
DB_PASSWORD=

# Timezone [optional - defaults to Asia/Jakarta]
TIMEZONE=Asia/Jakarta
EOF
}

validate_config() {
    local has_error=false
    
    # Validate DOMAIN
    if [[ -z "$DOMAIN" ]]; then
        log_error "DOMAIN is required in config file"
        has_error=true
    elif [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        log_error "Invalid DOMAIN format: $DOMAIN"
        has_error=true
    fi
    
    # Validate ADMIN_USERNAME
    if [[ -z "$ADMIN_USERNAME" ]]; then
        log_error "ADMIN_USERNAME is required in config file"
        has_error=true
    elif [[ ${#ADMIN_USERNAME} -lt 4 ]]; then
        log_error "ADMIN_USERNAME must be at least 4 characters"
        has_error=true
    elif [[ ! "$ADMIN_USERNAME" =~ ^[a-zA-Z0-9_]+$ ]]; then
        log_error "ADMIN_USERNAME can only contain letters, numbers, and underscores"
        has_error=true
    fi
    
    # Validate ADMIN_EMAIL
    if [[ -z "$ADMIN_EMAIL" ]]; then
        log_error "ADMIN_EMAIL is required in config file"
        has_error=true
    elif [[ ! "$ADMIN_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
        log_error "Invalid ADMIN_EMAIL format: $ADMIN_EMAIL"
        has_error=true
    fi
    
    # Validate ADMIN_PASSWORD
    if [[ -z "$ADMIN_PASSWORD" ]]; then
        log_error "ADMIN_PASSWORD is required in config file"
        has_error=true
    elif [[ ${#ADMIN_PASSWORD} -lt 8 ]]; then
        log_error "ADMIN_PASSWORD must be at least 8 characters"
        has_error=true
    fi
    
    # Validate SCHOOL_NAME
    if [[ -z "$SCHOOL_NAME" ]]; then
        log_error "SCHOOL_NAME is required in config file"
        has_error=true
    fi
    
    # Validate SCHOOL_LEVEL
    if [[ -z "$SCHOOL_LEVEL" ]]; then
        log_error "SCHOOL_LEVEL is required in config file (SD, SMP, SMA, or SMK)"
        has_error=true
    elif [[ ! "$SCHOOL_LEVEL" =~ ^(SD|SMP|SMA|SMK)$ ]]; then
        log_error "SCHOOL_LEVEL must be one of: SD, SMP, SMA, SMK (got: $SCHOOL_LEVEL)"
        has_error=true
    fi
    
    if [[ "$has_error" == "true" ]]; then
        echo ""
        log_error "Configuration validation failed. Please fix the errors above."
        echo ""
        echo -e "${YELLOW}Sample initial.config file:${NC}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        create_sample_config
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        exit 1
    fi
}

load_config_file() {
    log "Loading configuration from $CONFIG_FILE..."
    
    # Source the config file (reads KEY=VALUE pairs)
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    
    # Set defaults for optional fields
    DB_PASSWORD=${DB_PASSWORD:-$(generate_password)}
    TIMEZONE=${TIMEZONE:-"Asia/Jakarta"}
    
    # Generate APP_KEY
    APP_KEY=$(generate_app_key)
    
    # Validate all required fields
    validate_config
    
    log "✓ Configuration loaded successfully"
    
    # Show configuration summary
    echo -e "\n${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}                    CONFIGURATION FROM FILE${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  Domain:         ${CYAN}$DOMAIN${NC}"
    echo -e "  Admin Username: ${CYAN}$ADMIN_USERNAME${NC}"
    echo -e "  Admin Email:    ${CYAN}$ADMIN_EMAIL${NC}"
    echo -e "  School Name:    ${CYAN}$SCHOOL_NAME${NC}"
    echo -e "  School Level:   ${CYAN}$SCHOOL_LEVEL${NC}"
    echo -e "  DB Password:    ${CYAN}${DB_PASSWORD:0:4}****${NC}"
    echo -e "  Admin Password: ${CYAN}${ADMIN_PASSWORD:0:4}****${NC}"
    echo -e "  Timezone:       ${CYAN}$TIMEZONE${NC}"
    echo -e "  Performance:    ${CYAN}$PERFORMANCE_TIER${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    
    log "✓ Auto-proceeding with installation (config file mode)"
}

# ============================================
# INTERACTIVE PROMPTS (fallback if no config file)
# ============================================
get_user_input() {
    echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}                    CONFIGURATION SETUP${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    
    log_info "No initial.config file found. Starting interactive setup..."
    log_info "Tip: Create initial.config file for automated installation.\n"
    # Domain
    while true; do
        read -p "$(echo -e ${GREEN}?${NC}) Enter domain name (e.g., lms.school.sch.id): " DOMAIN
        if [[ -z "$DOMAIN" ]]; then
            log_error "Domain cannot be empty"
        elif [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            log_error "Invalid domain format"
        else
            break
        fi
    done
    
    # Admin Email (for password reset)
    while true; do
        read -p "$(echo -e ${GREEN}?${NC}) Enter admin email (for password reset): " ADMIN_EMAIL
        if [[ -z "$ADMIN_EMAIL" ]]; then
            log_error "Email cannot be empty"
        elif [[ ! "$ADMIN_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
            log_error "Invalid email format"
        else
            break
        fi
    done
    
    # Admin Username (for login)
    while true; do
        read -p "$(echo -e ${GREEN}?${NC}) Enter admin username (for login): " ADMIN_USERNAME
        if [[ -z "$ADMIN_USERNAME" ]]; then
            log_error "Username cannot be empty"
        elif [[ ${#ADMIN_USERNAME} -lt 4 ]]; then
            log_error "Username must be at least 4 characters"
        elif [[ ! "$ADMIN_USERNAME" =~ ^[a-zA-Z0-9_]+$ ]]; then
            log_error "Username can only contain letters, numbers, and underscores"
        else
            break
        fi
    done
    
    # School Name
    read -p "$(echo -e ${GREEN}?${NC}) Enter school name [LMS App]: " SCHOOL_NAME
    SCHOOL_NAME=${SCHOOL_NAME:-"LMS App"}
    
    # School Level
    while true; do
        echo -e "${YELLOW}School Level Options:${NC}"
        echo "  SD  = Elementary School (grades 1-6)"
        echo "  SMP = Junior High School (grades 7-9)"
        echo "  SMA = Senior High School (grades 10-12)"
        echo "  SMK = Vocational High School (grades 10-12)"
        read -p "$(echo -e ${GREEN}?${NC}) Enter school level [SMK]: " SCHOOL_LEVEL
        SCHOOL_LEVEL=${SCHOOL_LEVEL:-"SMK"}
        SCHOOL_LEVEL=$(echo "$SCHOOL_LEVEL" | tr '[:lower:]' '[:upper:]')
        if [[ "$SCHOOL_LEVEL" =~ ^(SD|SMP|SMA|SMK)$ ]]; then
            break
        else
            log_error "School level must be one of: SD, SMP, SMA, SMK"
        fi
    done
    
    # Database Password
    DEFAULT_DB_PASSWORD=$(generate_password)
    read -p "$(echo -e ${GREEN}?${NC}) Enter database password [auto-generated]: " DB_PASSWORD
    DB_PASSWORD=${DB_PASSWORD:-$DEFAULT_DB_PASSWORD}
    
    # Admin Password
    DEFAULT_ADMIN_PASSWORD=$(generate_password)
    read -p "$(echo -e ${GREEN}?${NC}) Enter admin password [auto-generated]: " ADMIN_PASSWORD
    ADMIN_PASSWORD=${ADMIN_PASSWORD:-$DEFAULT_ADMIN_PASSWORD}
    
    # Timezone
    read -p "$(echo -e ${GREEN}?${NC}) Enter timezone [Asia/Jakarta]: " TIMEZONE
    TIMEZONE=${TIMEZONE:-"Asia/Jakarta"}
    
    # Generate APP_KEY
    APP_KEY=$(generate_app_key)
    
    # Confirm
    echo -e "\n${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}                    CONFIGURATION SUMMARY${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  Domain:         ${CYAN}$DOMAIN${NC}"
    echo -e "  Admin Username: ${CYAN}$ADMIN_USERNAME${NC}"
    echo -e "  Admin Email:    ${CYAN}$ADMIN_EMAIL${NC}"
    echo -e "  School Name:    ${CYAN}$SCHOOL_NAME${NC}"
    echo -e "  School Level:   ${CYAN}$SCHOOL_LEVEL${NC}"
    echo -e "  DB Password:    ${CYAN}${DB_PASSWORD:0:4}****${NC}"
    echo -e "  Admin Password: ${CYAN}${ADMIN_PASSWORD:0:4}****${NC}"
    echo -e "  Timezone:       ${CYAN}$TIMEZONE${NC}"
    echo -e "  Performance:    ${CYAN}$PERFORMANCE_TIER${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    
    read -p "$(echo -e ${GREEN}?${NC}) Proceed with installation? [Y/n]: " CONFIRM
    CONFIRM=${CONFIRM:-Y}
    
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        log_error "Installation cancelled by user"
        exit 0
    fi
}

# ============================================
# INSTALLATION FUNCTIONS
# ============================================
install_dependencies() {
    print_step 1 10 "Installing system dependencies..."
    
    apt-get update -qq
    apt-get install -y -qq \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        software-properties-common \
        ufw \
        fail2ban \
        htop \
        ncdu \
        unzip \
        git \
        openssl \
        cron
    
    log "✓ System dependencies installed"
}

install_docker() {
    print_step 2 10 "Installing Docker..."
    
    if command -v docker &> /dev/null; then
        log "✓ Docker already installed: $(docker --version)"
    else
        curl -fsSL https://get.docker.com | sh
        systemctl enable docker
        systemctl start docker
        log "✓ Docker installed: $(docker --version)"
    fi
    
    # Install Docker Compose
    if command -v docker-compose &> /dev/null || docker compose version &> /dev/null; then
        log "✓ Docker Compose already installed"
    else
        apt-get install -y -qq docker-compose-plugin
        log "✓ Docker Compose installed"
    fi
    
    # Add common users to docker group (allows running docker without sudo)
    for user in ubuntu vagrant admin deploy; do
        if id "$user" &>/dev/null; then
            usermod -aG docker "$user" 2>/dev/null || true
            log "✓ Added $user to docker group"
        fi
    done
}

install_nginx() {
    print_step 3 10 "Installing Nginx..."
    
    if command -v nginx &> /dev/null; then
        log "✓ Nginx already installed"
    else
        apt-get install -y -qq nginx
        systemctl enable nginx
        log "✓ Nginx installed"
    fi
}

install_certbot() {
    print_step 4 10 "Installing Certbot for SSL..."
    
    if command -v certbot &> /dev/null; then
        log "✓ Certbot already installed"
    else
        apt-get install -y -qq certbot python3-certbot-nginx
        log "✓ Certbot installed"
    fi
}

setup_firewall() {
    print_step 5 10 "Configuring firewall..."
    
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp    # SSH
    ufw allow 80/tcp    # HTTP
    ufw allow 443/tcp   # HTTPS
    ufw --force enable
    
    log "✓ Firewall configured (ports: 22, 80, 443)"
}

create_app_structure() {
    print_step 6 10 "Creating application structure..."
    
    mkdir -p "$APP_DIR"
    mkdir -p "$APP_DIR/storage/logs"
    mkdir -p "$APP_DIR/storage/app/public"
    mkdir -p "$APP_DIR/storage/framework/cache"
    mkdir -p "$APP_DIR/storage/framework/sessions"
    mkdir -p "$APP_DIR/storage/framework/views"
    mkdir -p "$APP_DIR/public/storages"
    mkdir -p "$APP_DIR/public/storages/assets/images/users"
    mkdir -p "$APP_DIR/public/storages/assets/images/teachers"
    mkdir -p "$APP_DIR/public/storages/assets/images/students"
    mkdir -p "$APP_DIR/public/storages/course-thumbnails"
    mkdir -p "$APP_DIR/public/quiz-answers"
    mkdir -p "$APP_DIR/mysql/data"
    mkdir -p "$APP_DIR/redis/data"
    mkdir -p "$APP_DIR/docker/php"
    mkdir -p "$APP_DIR/docker/nginx"
    mkdir -p "$BACKUP_DIR"
    
    log "✓ Application directories created"
}

create_docker_configs() {
    log "Creating Docker configuration files for high-performance mode..."
    
    # Create PHP-FPM high-performance config
    cat > "$APP_DIR/docker/php/php-fpm-pool-highperf.conf" << 'EOFPHP'
; PHP-FPM Pool Configuration for HIGH CONCURRENCY (1000+ users)
[www]
pm = dynamic
pm.max_children = 150
pm.start_servers = 20
pm.min_spare_servers = 10
pm.max_spare_servers = 50
pm.max_requests = 1000
pm.process_idle_timeout = 10s
request_terminate_timeout = 3600s
request_slowlog_timeout = 30s
clear_env = no
user = www-data
group = www-data
listen = 127.0.0.1:9000
listen.backlog = 65535
access.log = /var/log/php-fpm-access.log
slowlog = /var/log/php-fpm-slow.log
php_admin_value[disable_functions] = passthru,shell_exec,system
php_admin_flag[allow_url_fopen] = on
php_admin_value[upload_max_filesize] = 10G
php_admin_value[post_max_size] = 10G
php_admin_value[max_execution_time] = 0
php_admin_value[max_input_time] = 0
php_admin_value[memory_limit] = 256M
php_admin_value[opcache.enable] = 1
php_admin_value[realpath_cache_size] = 4096K
php_admin_value[realpath_cache_ttl] = 600
php_admin_value[session.save_path] = /var/www/html/storage/framework/sessions
EOFPHP

    # Create Nginx high-performance main config
    cat > "$APP_DIR/docker/nginx/nginx-highperf.conf" << 'EOFNGINX'
worker_processes auto;
worker_rlimit_nofile 65535;
error_log /var/log/nginx/error.log warn;
pid /run/nginx.pid;

events {
    worker_connections 4096;
    use epoll;
    multi_accept on;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for" '
                    '$request_time $upstream_response_time';
    access_log /var/log/nginx/access.log main buffer=16k flush=2m;
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    keepalive_requests 1000;
    client_body_buffer_size 128k;
    client_header_buffer_size 4k;
    large_client_header_buffers 4 32k;
    client_body_timeout 3600s;
    client_header_timeout 60s;
    send_timeout 3600s;
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_min_length 1024;
    gzip_types text/plain text/css text/xml text/javascript application/json application/javascript application/x-javascript application/xml application/xml+rss application/vnd.ms-fontobject application/x-font-ttf font/opentype image/svg+xml;
    open_file_cache max=10000 inactive=20s;
    open_file_cache_valid 30s;
    open_file_cache_min_uses 2;
    open_file_cache_errors on;
    limit_req_zone $binary_remote_addr zone=login:10m rate=5r/s;
    limit_req_zone $binary_remote_addr zone=api:10m rate=30r/s;
    limit_conn_zone $binary_remote_addr zone=addr:10m;
    include /etc/nginx/http.d/*.conf;
}
EOFNGINX

    # Create Nginx high-performance server config
    cat > "$APP_DIR/docker/nginx/default-highperf.conf" << 'EOFNGINXDEF'
server {
    listen 80;
    server_name localhost;
    root /var/www/html/public;
    index index.php index.html;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer-when-downgrade" always;
    client_max_body_size 10G;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location = /login {
        limit_req zone=login burst=10 nodelay;
        try_files $uri $uri/ /index.php?$query_string;
    }

    location /api/ {
        limit_req zone=api burst=50 nodelay;
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        fastcgi_pass 127.0.0.1:9000;
        fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_hide_header X-Powered-By;
        fastcgi_read_timeout 3600s;
        fastcgi_send_timeout 3600s;
        fastcgi_connect_timeout 60s;
        fastcgi_buffer_size 32k;
        fastcgi_buffers 64 16k;
        fastcgi_busy_buffers_size 128k;
        fastcgi_temp_file_write_size 256k;
        fastcgi_keep_conn on;
    }

    location ~ /\. { deny all; }
    location ~ /(\.env|\.git|composer\.(json|lock)|package\.(json|lock)|yarn\.lock) { deny all; }

    location ~* \.(css|js|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
        add_header Vary Accept-Encoding;
        access_log off;
        try_files $uri =404;
    }

    location /storage { try_files $uri $uri/ /index.php?$query_string; }
    location /storages { try_files $uri $uri/ /index.php?$query_string; }
    location = /health { access_log off; try_files $uri /health.php; }
}
EOFNGINXDEF

    log "✓ Docker configuration files created"
}

create_docker_compose_highperf() {
    log "Creating Docker Compose high-performance configuration..."
    
    cat > "$APP_DIR/docker-compose.highperf.yml" << 'EOF'
# Docker Compose for HIGH PERFORMANCE (1000+ concurrent users)
# Use: docker compose -f docker-compose.highperf.yml up -d
services:
  mysql:
    image: mysql:8.0
    container_name: lms-mysql
    restart: unless-stopped
    ports:
      - "3306:3306"
    environment:
      MYSQL_ROOT_PASSWORD: ${DB_ROOT_PASSWORD}
      MYSQL_DATABASE: ${DB_DATABASE:-vajar_lms}
      MYSQL_USER: ${DB_USERNAME:-vajar_lms}
      MYSQL_PASSWORD: ${DB_PASSWORD}
    volumes:
      - mysql_data:/var/lib/mysql
    networks:
      - lms_network
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-u", "root", "-p${DB_ROOT_PASSWORD}"]
      interval: 10s
      timeout: 5s
      retries: 5
    command:
      - --innodb-buffer-pool-size=1G
      - --innodb-log-file-size=256M
      - --innodb-flush-log-at-trx-commit=2
      - --innodb-flush-method=O_DIRECT
      - --max-connections=500
      - --thread-cache-size=50
      - --performance-schema=OFF

  redis:
    image: redis:7-alpine
    container_name: lms-redis
    restart: unless-stopped
    ports:
      - "6379:6379"
    volumes:
      - redis_data:/data
    networks:
      - lms_network
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
    command: redis-server --maxmemory 256mb --maxmemory-policy allkeys-lru --appendonly yes

  app:
    image: ${DOCKER_IMAGE:-bariqid/vajar_lms_image:latest}
    container_name: lms-app
    restart: unless-stopped
    ports:
      - "8080:80"
    volumes:
      - app_storage:/var/www/html/storage
      - app_public:/var/www/html/public/storages
      - ./docker/php/php-fpm-pool-highperf.conf:/usr/local/etc/php-fpm.d/www.conf:ro
      - ./docker/nginx/nginx-highperf.conf:/etc/nginx/nginx.conf:ro
      - ./docker/nginx/default-highperf.conf:/etc/nginx/http.d/default.conf:ro
    environment:
      - APP_ENV=${APP_ENV:-production}
      - APP_DEBUG=${APP_DEBUG:-false}
      - APP_KEY=${APP_KEY}
      - APP_URL=${APP_URL}
      - DB_CONNECTION=mysql
      - DB_HOST=mysql
      - DB_PORT=3306
      - DB_DATABASE=${DB_DATABASE:-vajar_lms}
      - DB_USERNAME=${DB_USERNAME:-vajar_lms}
      - DB_PASSWORD=${DB_PASSWORD}
      - CACHE_DRIVER=redis
      - SESSION_DRIVER=redis
      - QUEUE_CONNECTION=redis
      - REDIS_CLIENT=predis
      - REDIS_HOST=redis
      - REDIS_PORT=6379
    networks:
      - lms_network
    depends_on:
      mysql:
        condition: service_healthy
      redis:
        condition: service_healthy
    ulimits:
      nofile:
        soft: 65535
        hard: 65535
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s

  queue:
    image: ${DOCKER_IMAGE:-bariqid/vajar_lms_image:latest}
    container_name: lms-queue
    restart: unless-stopped
    command: php artisan queue:work redis --sleep=3 --tries=3 --max-jobs=1000 --max-time=3600
    environment:
      - APP_ENV=${APP_ENV:-production}
      - APP_KEY=${APP_KEY}
      - DB_HOST=mysql
      - DB_DATABASE=${DB_DATABASE:-vajar_lms}
      - DB_USERNAME=${DB_USERNAME:-vajar_lms}
      - DB_PASSWORD=${DB_PASSWORD}
      - REDIS_HOST=redis
      - QUEUE_CONNECTION=redis
    volumes:
      - app_storage:/var/www/html/storage
    depends_on:
      - app
    networks:
      - lms_network

  scheduler:
    image: ${DOCKER_IMAGE:-bariqid/vajar_lms_image:latest}
    container_name: lms-scheduler
    restart: unless-stopped
    command: sh -c "while true; do php artisan schedule:run --verbose --no-interaction & sleep 60; done"
    environment:
      - APP_ENV=${APP_ENV:-production}
      - APP_KEY=${APP_KEY}
      - DB_HOST=mysql
      - DB_DATABASE=${DB_DATABASE:-vajar_lms}
      - DB_USERNAME=${DB_USERNAME:-vajar_lms}
      - DB_PASSWORD=${DB_PASSWORD}
      - REDIS_HOST=redis
    volumes:
      - app_storage:/var/www/html/storage
    depends_on:
      - app
    networks:
      - lms_network

volumes:
  mysql_data:
  redis_data:
  app_storage:
  app_public:

networks:
  lms_network:
    driver: bridge
EOF

    log "✓ Docker Compose high-performance configuration created"
}

create_env_file() {
    log "Creating environment file..."
    
    cat > "$APP_DIR/.env" << EOF
# Application
APP_NAME="${SCHOOL_NAME}"
APP_ENV=production
APP_KEY=${APP_KEY}
APP_DEBUG=false
APP_URL=https://${DOMAIN}
APP_TIMEZONE=${TIMEZONE}

# Database
DB_CONNECTION=mysql
DB_HOST=mysql
DB_PORT=3306
DB_DATABASE=vajar_lms
DB_USERNAME=vajar_lms
DB_PASSWORD=${DB_PASSWORD}
DB_ROOT_PASSWORD=${DB_PASSWORD}_root

# Cache & Session (using file driver until predis image is deployed)
# After running 'lms update' with new image, change to redis
CACHE_DRIVER=redis
SESSION_DRIVER=redis
SESSION_LIFETIME=120
QUEUE_CONNECTION=sync

# Redis (ready for when you switch to redis drivers)
REDIS_CLIENT=predis
REDIS_HOST=redis
REDIS_PASSWORD=null
REDIS_PORT=6379

# Logging
LOG_CHANNEL=daily
LOG_LEVEL=error

# Mail (configure as needed)
MAIL_MAILER=smtp
MAIL_HOST=smtp.mailtrap.io
MAIL_PORT=2525
MAIL_USERNAME=null
MAIL_PASSWORD=null
MAIL_ENCRYPTION=null
MAIL_FROM_ADDRESS="${ADMIN_EMAIL}"
MAIL_FROM_NAME="\${APP_NAME}"

# Filesystem
FILESYSTEM_DRIVER=local
EOF

    chmod 600 "$APP_DIR/.env"
    log "✓ Environment file created"
}

create_docker_compose() {
    log "Creating Docker Compose configuration..."
    
    cat > "$APP_DIR/docker-compose.yml" << 'EOF'
services:
  app:
    image: ${DOCKER_IMAGE:-bariqid/vajar_lms_image:latest}
    container_name: lms-app
    restart: unless-stopped
    environment:
      - APP_ENV=${APP_ENV:-production}
      - APP_DEBUG=${APP_DEBUG:-false}
      - APP_KEY=${APP_KEY}
      - APP_URL=${APP_URL}
      - DB_CONNECTION=mysql
      - DB_HOST=mysql
      - DB_PORT=3306
      - DB_DATABASE=${DB_DATABASE:-vajar_lms}
      - DB_USERNAME=${DB_USERNAME:-vajar_lms}
      - DB_PASSWORD=${DB_PASSWORD}
      - CACHE_DRIVER=redis
      - SESSION_DRIVER=redis
      - QUEUE_CONNECTION=sync
      - REDIS_CLIENT=predis
      - REDIS_HOST=redis
      - REDIS_PORT=6379
    volumes:
      - app_storage:/var/www/html/storage
      - app_public:/var/www/html/public/storages
    ports:
      - "8080:80"
    depends_on:
      mysql:
        condition: service_healthy
      redis:
        condition: service_healthy
    networks:
      - lms_network
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s

  queue:
    image: ${DOCKER_IMAGE:-bariqid/vajar_lms_image:latest}
    container_name: lms-queue
    restart: unless-stopped
    command: php artisan queue:work redis --sleep=3 --tries=3 --max-jobs=1000 --timeout=300
    environment:
      - APP_ENV=${APP_ENV:-production}
      - APP_KEY=${APP_KEY}
      - DB_HOST=mysql
      - DB_DATABASE=${DB_DATABASE:-vajar_lms}
      - DB_USERNAME=${DB_USERNAME:-vajar_lms}
      - DB_PASSWORD=${DB_PASSWORD}
      - REDIS_HOST=redis
    volumes:
      - app_storage:/var/www/html/storage
    depends_on:
      - app
    networks:
      - lms_network

  scheduler:
    image: ${DOCKER_IMAGE:-bariqid/vajar_lms_image:latest}
    container_name: lms-scheduler
    restart: unless-stopped
    command: sh -c "while true; do php artisan schedule:run --verbose --no-interaction & sleep 60; done"
    environment:
      - APP_ENV=${APP_ENV:-production}
      - APP_KEY=${APP_KEY}
      - DB_HOST=mysql
      - DB_DATABASE=${DB_DATABASE:-vajar_lms}
      - DB_USERNAME=${DB_USERNAME:-vajar_lms}
      - DB_PASSWORD=${DB_PASSWORD}
      - REDIS_HOST=redis
    volumes:
      - app_storage:/var/www/html/storage
    depends_on:
      - app
    networks:
      - lms_network

  mysql:
    image: mysql:8.0
    container_name: lms-mysql
    restart: unless-stopped
    command: >
      --default-authentication-plugin=mysql_native_password
      --innodb-buffer-pool-size=${MYSQL_BUFFER:-512M}
      --innodb-log-file-size=256M
      --innodb-flush-log-at-trx-commit=2
      --max-connections=500
      --slow-query-log=1
      --slow-query-log-file=/var/log/mysql/slow.log
      --long-query-time=2
    environment:
      MYSQL_ROOT_PASSWORD: ${DB_ROOT_PASSWORD}
      MYSQL_DATABASE: ${DB_DATABASE:-vajar_lms}
      MYSQL_USER: ${DB_USERNAME:-vajar_lms}
      MYSQL_PASSWORD: ${DB_PASSWORD}
    volumes:
      - mysql_data:/var/lib/mysql
    networks:
      - lms_network
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-u", "root", "-p${DB_ROOT_PASSWORD}"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 30s

  redis:
    image: redis:7-alpine
    container_name: lms-redis
    restart: unless-stopped
    command: >
      redis-server
      --appendonly yes
      --maxmemory ${REDIS_MEMORY:-256mb}
      --maxmemory-policy allkeys-lru
    volumes:
      - redis_data:/data
    networks:
      - lms_network
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5

volumes:
  mysql_data:
  redis_data:
  app_storage:
  app_public:

networks:
  lms_network:
    driver: bridge
EOF

    # Add environment variables for MySQL buffer
    echo "MYSQL_BUFFER=${MYSQL_BUFFER}" >> "$APP_DIR/.env"
    echo "REDIS_MEMORY=${REDIS_MEMORY}" >> "$APP_DIR/.env"
    echo "DOCKER_IMAGE=${DOCKER_IMAGE}" >> "$APP_DIR/.env"
    
    log "✓ Docker Compose configuration created"
}

create_nginx_config() {
    log "Creating Nginx configuration..."
    
    cat > "/etc/nginx/sites-available/${DOMAIN}" << EOF
# Rate limiting
limit_req_zone \$binary_remote_addr zone=general:10m rate=50r/s;
limit_conn_zone \$binary_remote_addr zone=addr:10m;

# Upstream
upstream lms_backend {
    server 127.0.0.1:8080;
    keepalive 32;
}

# HTTP - Redirect to HTTPS (will be updated by certbot)
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://\$server_name\$request_uri;
    }
}

# HTTPS - Main server (will be configured by certbot)
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${DOMAIN};

    # SSL will be configured by certbot
    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:50m;
    ssl_session_tickets off;
    
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;

    # HSTS
    add_header Strict-Transport-Security "max-age=63072000" always;

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;

    # Rate limiting
    limit_req zone=general burst=100 nodelay;
    limit_conn addr 50;

    # Client settings for large uploads
    client_max_body_size 500M;
    client_body_timeout 300s;

    location / {
        proxy_pass http://lms_backend;
        proxy_http_version 1.1;
        
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Connection "";
        
        proxy_connect_timeout 60s;
        proxy_send_timeout 300s;
        proxy_read_timeout 300s;
        proxy_buffering off;
        proxy_request_buffering off;
    }
}
EOF

    # Create temporary HTTP-only config for initial SSL setup
    cat > "/etc/nginx/sites-available/${DOMAIN}-temp" << EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

    mkdir -p /var/www/certbot
    
    # Enable temp config first
    ln -sf "/etc/nginx/sites-available/${DOMAIN}-temp" "/etc/nginx/sites-enabled/${DOMAIN}"
    rm -f /etc/nginx/sites-enabled/default
    
    nginx -t && systemctl reload nginx
    
    log "✓ Nginx configuration created"
}

pull_and_start_containers() {
    print_step 7 10 "Pulling Docker images and starting containers..."
    
    cd "$APP_DIR"
    
    # Pull images
    docker compose pull
    
    # Start containers
    docker compose up -d
    
    # Wait for containers to be healthy
    log "Waiting for containers to be healthy..."
    sleep 30
    
    # Check status
    docker compose ps
    
    log "✓ Containers started"
}

run_migrations() {
    print_step 8 10 "Running database migrations..."
    
    cd "$APP_DIR"
    
    # Wait for MySQL to be fully ready
    log "Waiting for MySQL to be ready..."
    local max_attempts=30
    local attempt=1
    
    while ! docker compose exec -T mysql mysqladmin ping -h localhost -u root -p"${DB_PASSWORD}_root" --silent 2>/dev/null; do
        if [[ $attempt -ge $max_attempts ]]; then
            log_error "MySQL failed to start after ${max_attempts} attempts"
            exit 1
        fi
        log_info "Waiting for MySQL... (attempt $attempt/$max_attempts)"
        sleep 5
        ((attempt++))
    done
    
    log "✓ MySQL is ready"
    
    # Run migrations
    docker compose exec -T app php artisan migrate --force
    
    log "✓ Database migrations completed"
}

run_seeders() {
    log "Running database seeders..."
    
    cd "$APP_DIR"
    
    # Run essential seeders with SCHOOL_LEVEL environment variable
    docker compose exec -T -e SCHOOL_LEVEL="${SCHOOL_LEVEL}" app php artisan db:seed --force
    
    # Update admin user with custom credentials (username for login, email for reset)
    docker compose exec -T app php artisan tinker --execute="
        \$user = \App\Models\User::where('email', 'root@gmail.com')->first();
        if (\$user) {
            \$user->update([
                'username' => '${ADMIN_USERNAME}',
                'email' => '${ADMIN_EMAIL}',
                'password' => bcrypt('${ADMIN_PASSWORD}')
            ]);
        }
    " 2>/dev/null || true
    
    # Fix storage permissions
    log "Fixing storage permissions..."
    docker compose exec -T app chown -R www-data:www-data /var/www/html/storage
    docker compose exec -T app chown -R www-data:www-data /var/www/html/public/storages
    docker compose exec -T app chmod -R 2775 /var/www/html/storage
    docker compose exec -T app chmod -R 2775 /var/www/html/public/storages
    
    # Create and fix permissions for new storage directories
    docker compose exec -T app mkdir -p /var/www/html/public/storages/assets/images/users
    docker compose exec -T app mkdir -p /var/www/html/public/storages/assets/images/teachers
    docker compose exec -T app mkdir -p /var/www/html/public/storages/assets/images/students
    docker compose exec -T app mkdir -p /var/www/html/public/storages/course-thumbnails
    docker compose exec -T app chown -R www-data:www-data /var/www/html/public/storages
    
    log "✓ Database seeded"
}

setup_ssl() {
    print_step 9 10 "Configuring SSL certificate..."
    
    # Check if domain is pointing to this server
    local server_ip=$(curl -s ifconfig.me)
    local domain_ip=$(dig +short "$DOMAIN" | head -n1)
    
    if [[ "$server_ip" != "$domain_ip" ]]; then
        log_warn "Domain $DOMAIN is not pointing to this server ($server_ip)"
        log_warn "Domain resolves to: $domain_ip"
        log_warn "SSL setup will be skipped. Run 'certbot --nginx -d $DOMAIN' manually after DNS propagation"
        return
    fi
    
    # Get SSL certificate
    certbot certonly --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$ADMIN_EMAIL" || {
        log_warn "SSL certificate generation failed. You can run it manually later."
        return
    }
    
    # Enable full HTTPS config
    ln -sf "/etc/nginx/sites-available/${DOMAIN}" "/etc/nginx/sites-enabled/${DOMAIN}"
    rm -f "/etc/nginx/sites-available/${DOMAIN}-temp"
    
    nginx -t && systemctl reload nginx
    
    # Setup auto-renewal
    (crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet --post-hook 'systemctl reload nginx'") | crontab -
    
    log "✓ SSL certificate configured with auto-renewal"
}

optimize_performance() {
    print_step 10 10 "Optimizing for production..."
    
    cd "$APP_DIR"
    
    # Clear and cache Laravel
    docker compose exec -T app php artisan optimize:clear
    docker compose exec -T app php artisan config:cache
    docker compose exec -T app php artisan route:cache
    docker compose exec -T app php artisan view:cache
    
    # Fix permissions
    docker compose exec -T app chown -R www-data:www-data /var/www/html/storage
    docker compose exec -T app chown -R www-data:www-data /var/www/html/public/storages
    docker compose exec -T app chmod -R 2775 /var/www/html/storage
    docker compose exec -T app chmod -R 2775 /var/www/html/public/storages
    
    # Ensure all storage subdirectories exist
    docker compose exec -T app mkdir -p /var/www/html/public/storages/assets/images/users
    docker compose exec -T app mkdir -p /var/www/html/public/storages/assets/images/teachers
    docker compose exec -T app mkdir -p /var/www/html/public/storages/assets/images/students
    docker compose exec -T app mkdir -p /var/www/html/public/storages/course-thumbnails
    docker compose exec -T app chown -R www-data:www-data /var/www/html/public/storages
    
    log "✓ Laravel optimized for production"
}

create_management_scripts() {
    log "Creating management scripts..."
    
    # Create lms CLI tool
    cat > "/usr/local/bin/lms" << 'EOFCLI'
#!/bin/bash
APP_DIR="/opt/lms-app"
BACKUP_DIR="/opt/lms-backups"

cd "$APP_DIR"

case "$1" in
    status)
        docker compose ps
        ;;
    logs)
        if [ -z "$2" ]; then
            docker compose logs -f --tail=100
        else
            docker compose logs -f --tail=100 "$2"
        fi
        ;;
    restart)
        docker compose restart
        ;;
    stop)
        docker compose down
        ;;
    start)
        docker compose up -d
        ;;
    update)
        echo "Pulling latest image..."
        docker compose pull
        echo "Restarting containers..."
        docker compose up -d
        echo "Clearing caches..."
        docker compose exec -T app php artisan optimize:clear
        docker compose exec -T app php artisan config:cache
        docker compose exec -T app php artisan route:cache
        docker compose exec -T app php artisan view:cache
        echo "✓ Update complete!"
        ;;
    backup)
        TIMESTAMP=$(date +%Y%m%d_%H%M%S)
        BACKUP_FILE="$BACKUP_DIR/backup_$TIMESTAMP.sql.gz"
        echo "Creating backup..."
        docker compose exec -T mysql mysqldump -u root -p"$(grep DB_ROOT_PASSWORD .env | cut -d '=' -f2)" vajar_lms | gzip > "$BACKUP_FILE"
        echo "✓ Backup created: $BACKUP_FILE"
        # Keep only last 7 backups
        ls -t "$BACKUP_DIR"/backup_*.sql.gz | tail -n +8 | xargs -r rm
        ;;
    restore)
        if [ -z "$2" ]; then
            echo "Usage: lms restore <backup_file>"
            exit 1
        fi
        echo "Restoring from $2..."
        gunzip -c "$2" | docker compose exec -T mysql mysql -u root -p"$(grep DB_ROOT_PASSWORD .env | cut -d '=' -f2)" vajar_lms
        echo "✓ Restore complete!"
        ;;
    artisan)
        shift
        docker compose exec -T app php artisan "$@"
        ;;
    shell)
        docker compose exec app sh
        ;;
    mysql)
        docker compose exec mysql mysql -u root -p"$(grep DB_ROOT_PASSWORD .env | cut -d '=' -f2)" vajar_lms
        ;;
    highperf)
        case "$2" in
            up)
                # Check system resources before enabling high-performance
                MEM_TOTAL=$(free -m | awk '/^Mem:/{print $2}')
                CPU_CORES=$(nproc)
                
                echo "📊 Checking system resources..."
                echo "   CPU Cores: $CPU_CORES (recommended: 4+)"
                echo "   RAM: ${MEM_TOTAL}MB (recommended: 8GB+)"
                echo ""
                
                if [[ $MEM_TOTAL -lt 4000 ]]; then
                    echo "❌ ERROR: Insufficient RAM for high-performance mode"
                    echo "   Required: 4GB minimum, 8GB recommended"
                    echo "   Available: ${MEM_TOTAL}MB"
                    echo ""
                    echo "High-performance mode requires more resources."
                    echo "Consider upgrading your server or use standard mode."
                    exit 1
                fi
                
                if [[ $CPU_CORES -lt 2 ]]; then
                    echo "❌ ERROR: Insufficient CPU cores for high-performance mode"
                    echo "   Required: 2 minimum, 4+ recommended"
                    echo "   Available: $CPU_CORES"
                    exit 1
                fi
                
                if [[ $MEM_TOTAL -lt 8000 ]] || [[ $CPU_CORES -lt 4 ]]; then
                    echo "⚠️  WARNING: Your system meets minimum but not recommended specs"
                    echo "   For optimal performance: 4+ CPU cores, 8GB+ RAM"
                    read -p "Continue anyway? [y/N]: " confirm
                    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                        echo "Cancelled."
                        exit 0
                    fi
                fi
                
                echo ""
                echo "🚀 Switching to HIGH PERFORMANCE mode..."
                echo "Stopping current containers..."
                docker compose down
                echo "Starting high-performance containers..."
                docker compose -f docker-compose.highperf.yml up -d
                echo "Waiting for containers to be healthy..."
                sleep 15
                docker compose -f docker-compose.highperf.yml ps
                echo ""
                echo "✓ HIGH PERFORMANCE mode activated!"
                echo "  - PHP-FPM: 150 max workers"
                echo "  - Nginx: 4096 connections per worker"
                echo "  - Redis: Required for sessions/cache"
                ;;
            down)
                echo "📉 Switching back to STANDARD mode..."
                echo "Stopping high-performance containers..."
                docker compose -f docker-compose.highperf.yml down
                echo "Starting standard containers..."
                docker compose up -d
                echo "Waiting for containers to be healthy..."
                sleep 15
                docker compose ps
                echo ""
                echo "✓ STANDARD mode activated!"
                ;;
            status)
                if docker compose -f docker-compose.highperf.yml ps 2>/dev/null | grep -q "lms-app"; then
                    echo "🚀 Currently running in HIGH PERFORMANCE mode"
                    docker compose -f docker-compose.highperf.yml ps
                else
                    echo "📦 Currently running in STANDARD mode"
                    docker compose ps
                fi
                ;;
            *)
                echo "Usage: lms highperf <up|down|status>"
                echo ""
                echo "Commands:"
                echo "  up      - Switch to high-performance mode (1000+ users)"
                echo "  down    - Switch back to standard mode"
                echo "  status  - Check current mode"
                ;;
        esac
        ;;
    *)
        echo "Vajar LMS Management CLI"
        echo ""
        echo "Usage: lms <command>"
        echo ""
        echo "Commands:"
        echo "  status    - Show container status"
        echo "  logs      - Show logs (optionally specify service: app, mysql, redis)"
        echo "  restart   - Restart all containers"
        echo "  stop      - Stop all containers"
        echo "  start     - Start all containers"
        echo "  update    - Pull latest image and restart"
        echo "  backup    - Create database backup"
        echo "  restore   - Restore from backup file"
        echo "  artisan   - Run artisan command"
        echo "  shell     - Enter app container shell"
        echo "  mysql     - Enter MySQL shell"
        echo "  highperf  - Switch between standard/high-performance mode"
        echo ""
        echo "High Performance Mode:"
        echo "  lms highperf up     - Enable high-performance (1000+ users)"
        echo "  lms highperf down   - Switch to standard mode"
        echo "  lms highperf status - Check current mode"
        ;;
esac
EOFCLI

    chmod +x /usr/local/bin/lms
    
    # Setup daily backup cron
    (crontab -l 2>/dev/null; echo "0 2 * * * /usr/local/bin/lms backup >> /var/log/lms-backup.log 2>&1") | crontab -
    
    log "✓ Management scripts created"
}

fix_app_ownership() {
    log "Fixing application directory ownership..."
    
    # Detect the non-root user who will manage the app
    # Priority: SUDO_USER > ubuntu > first non-root user with home dir
    local app_user=""
    
    if [[ -n "${SUDO_USER:-}" ]] && [[ "$SUDO_USER" != "root" ]]; then
        app_user="$SUDO_USER"
    elif id "ubuntu" &>/dev/null; then
        app_user="ubuntu"
    else
        # Find first non-root user with a home directory
        app_user=$(getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 {print $1; exit}')
    fi
    
    if [[ -n "$app_user" ]]; then
        log_info "Setting ownership to user: $app_user"
        
        # Change ownership of app directory (excluding docker volumes)
        chown -R "$app_user:$app_user" "$APP_DIR"
        chown -R "$app_user:$app_user" "$BACKUP_DIR"
        
        # Keep .env secure but accessible
        chmod 600 "$APP_DIR/.env"
        chmod 600 "$APP_DIR/CREDENTIALS.txt" 2>/dev/null || true
        
        log "✓ Ownership set to '$app_user' for $APP_DIR"
    else
        log_warn "Could not detect non-root user, keeping root ownership"
    fi
}

print_completion() {
    echo -e "\n${GREEN}"
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║                                                               ║"
    echo "║          ✅ INSTALLATION COMPLETED SUCCESSFULLY!              ║"
    echo "║                                                               ║"
    echo "╠═══════════════════════════════════════════════════════════════╣"
    echo "║                                                               ║"
    echo "║  🌐 URL:      https://${DOMAIN}"
    echo "║                                                               ║"
    echo "║  👤 Admin Username: ${ADMIN_USERNAME}"
    echo "║  📧 Admin Email:    ${ADMIN_EMAIL}"
    echo "║  🔑 Admin Password: ${ADMIN_PASSWORD}"
    echo "║                                                               ║"
    echo "║  📁 App Location:   ${APP_DIR}"
    echo "║  📊 Logs:           ${APP_DIR}/storage/logs"
    echo "║  💾 Backups:        ${BACKUP_DIR}"
    echo "║                                                               ║"
    echo "╠═══════════════════════════════════════════════════════════════╣"
    echo "║  MANAGEMENT COMMANDS:                                         ║"
    echo "║                                                               ║"
    echo "║  lms status   - Show container status                         ║"
    echo "║  lms logs     - Show live logs                                ║"
    echo "║  lms restart  - Restart containers                            ║"
    echo "║  lms update   - Update to latest version                      ║"
    echo "║  lms backup   - Create database backup                        ║"
    echo "║  lms artisan  - Run artisan commands                          ║"
    echo "║                                                               ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    # Save credentials to file
    cat > "$APP_DIR/CREDENTIALS.txt" << EOF
Vajar LMS Installation Credentials
===================================
Generated: $(date)

URL: https://${DOMAIN}

Admin Username: ${ADMIN_USERNAME}
Admin Email: ${ADMIN_EMAIL}
Admin Password: ${ADMIN_PASSWORD}

Note: Use USERNAME to login, EMAIL for password reset.

Database Name: vajar_lms
Database User: vajar_lms
Database Password: ${DB_PASSWORD}
Database Root Password: ${DB_PASSWORD}_root

App Key: ${APP_KEY}

IMPORTANT: Delete this file after saving credentials securely!
EOF
    chmod 600 "$APP_DIR/CREDENTIALS.txt"
    
    log "Credentials saved to: $APP_DIR/CREDENTIALS.txt"
    log_warn "Please save these credentials and delete the file!"
}

# ============================================
# MAIN EXECUTION
# ============================================
main() {
    # Print banner first (doesn't need root)
    print_banner
    
    # Pre-checks (check_root will exit if not root)
    check_root
    
    # Create log file (now we know we're root)
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    
    check_os
    check_resources
    
    # Load configuration from file or prompt interactively
    if [[ -f "$CONFIG_FILE" ]]; then
        load_config_file
    else
        get_user_input
    fi
    
    # Installation steps
    install_dependencies
    install_docker
    install_nginx
    install_certbot
    setup_firewall
    create_app_structure
    create_docker_configs
    create_docker_compose_highperf
    create_env_file
    create_docker_compose
    create_nginx_config
    pull_and_start_containers
    run_migrations
    run_seeders
    setup_ssl
    optimize_performance
    create_management_scripts
    fix_app_ownership
    
    # Done!
    print_completion
}

# Run main function
main "$@"
