#!/bin/bash

set -euo pipefail  # Exit on error, undefined variables, and pipe failures

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

readonly DOCKER_PLUGIN_REPO="https://github.com/28Pollux28/zync"
readonly DOCKER_INSTANCER_REPO="https://github.com/28Pollux28/galvanize"

declare -A CONFIG=(
    [GENERATE_CERTS]="true"
    [CONFIGURE_DOCKER]="true"
    [WORKING_DIR]="/home/${SUDO_USER:-$USER}"
    [THEME]=""
    [BACKUP_SCHEDULE]="daily"
    [JWT_SECRET_KEY]=""
    [DOCKER_ENV_FILE]="env.production"
)

# ============================================================================
# Logging and Error Handling
# ============================================================================

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

error_exit() {
    log_error "$1"
    exit "${2:-1}"
}

# ============================================================================
# Utility Functions
# ============================================================================

generate_password() {
    local length="${1:-15}"
    openssl rand -base64 "$((length * 3 / 4))" | tr -d '+/=' | head -c "$length"
}

is_ip_address() {
    local input="$1"
    
    if [[ $input =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        local IFS='.'
        local -a octets=($input)
        for octet in "${octets[@]}"; do
            if ((octet > 255)); then
                return 1
            fi
        done
        return 0
    fi
    
    if [[ $input =~ : ]]; then
        return 0
    fi
    
    return 1
}

is_git_url() {
    local input="$1"
    # Check if input looks like a git URL
    if [[ $input =~ ^(https?|git|ssh):// ]] || [[ $input =~ \.git$ ]] || [[ $input =~ ^git@ ]]; then
        return 0
    fi
    return 1
}

setup_env_key() {
    local key="$1"
    local value="$2"
    local env_file="${CONFIG[WORKING_DIR]}/infra/.env"
    
    if [[ ! -f "$env_file" ]]; then
        cp "${CONFIG[WORKING_DIR]}/infra/${CONFIG[DOCKER_ENV_FILE]}" "$env_file"
    fi
    
    if grep -q "^${key}=" "$env_file"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$env_file"
    else
        echo "${key}=${value}" >> "$env_file"
    fi
}

# ============================================================================
# Argument Parsing and Validation
# ============================================================================

show_usage() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS]

Options:
    --ctfd-url URL          Set CTFd URL (mandatory)
                            Note: IP addresses automatically enable --no-https
    --working-folder DIR    Set working directory (default: /home/\$USER)
    --theme PATH_OR_URL     Path to local theme folder or Git URL to clone
                            Examples:
                              --theme /path/to/my-theme
                              --theme https://github.com/user/ctfd-theme.git
    --backup-schedule TYPE  Set backup schedule: daily, hourly, or 10min (default: daily)
    --help                  Show this help message
    --instancer-url         Set instancer URL (default: local instancer)
    --no-https              Disable HTTPS configuration for CTFd
                            (automatically enabled for IP addresses)

Examples:
    $SCRIPT_NAME --ctfd-url example.com
    $SCRIPT_NAME --ctfd-url 192.168.1.100  # Automatically uses --no-https
    $SCRIPT_NAME --ctfd-url example.com --working-folder /opt/ctfd
    $SCRIPT_NAME --ctfd-url example.com --theme /home/user/my-custom-theme
    $SCRIPT_NAME --ctfd-url example.com --theme https://github.com/user/theme.git
    $SCRIPT_NAME --ctfd-url example.com --backup-schedule hourly
    $SCRIPT_NAME --ctfd-url example.com --instancer-url http://instancer.example.com:1234
EOF
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --ctfd-url)
                [[ -n ${2:-} ]] || error_exit "Missing value for --ctfd-url"
                CONFIG[CTFD_URL]="$2"
                shift 2
                ;;
            --working-folder)
                [[ -n ${2:-} ]] || error_exit "Missing value for --working-folder"
                CONFIG[WORKING_DIR]="$2"
                shift 2
                ;;
            --theme)
                [[ -n ${2:-} ]] || error_exit "Missing value for --theme (provide path or git URL)"
                CONFIG[THEME]="$2"
                shift 2
                ;;
            --backup-schedule)
                [[ -n ${2:-} ]] || error_exit "Missing value for --backup-schedule"
                case ${2,,} in
                    daily|hourly|10min)
                        CONFIG[BACKUP_SCHEDULE]="${2,,}"
                        ;;
                    *)
                        error_exit "Invalid backup schedule: $2. Must be one of: daily, hourly, 10min"
                        ;;
                esac
                shift 2
                ;;
            --instancer-url)
                [[ -n ${2:-} ]] || error_exit "Missing value for --instancer-url"
                CONFIG[INSTANCER_URL]="$2"
                shift 2
                ;;
            --no-https)
                CONFIG[NO_HTTPS]="true"
                CONFIG[DOCKER_ENV_FILE]="env.local"
                shift
                ;;
            --help)
                show_usage
                exit 0
                ;;
            *)
                error_exit "Unknown parameter: $1"
                ;;
        esac
    done

    [[ -n ${CONFIG[CTFD_URL]:-} ]] || error_exit "Error: --ctfd-url is mandatory and must be specified."
    
    if [[ -z ${CONFIG[NO_HTTPS]:-} ]] && is_ip_address "${CONFIG[CTFD_URL]}"; then
        log_info "Detected IP address in --ctfd-url, automatically enabling --no-https"
        CONFIG[NO_HTTPS]="true"
        CONFIG[DOCKER_ENV_FILE]="env.local"
    fi
}

# ============================================================================
# System Initialization
# ============================================================================

ensure_root() {
    if [[ $EUID -ne 0 ]]; then
        log_info "This script must be run as root. Re-executing with sudo..."
        exec sudo bash "$0" "$@"
    fi
    log_info "Running script as root..."
}

identify_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case $ID in
            ubuntu)
                echo "ubuntu"
                ;;
            debian)
                echo "debian"
                ;;
            *)
                error_exit "Unsupported OS: $ID. Please check the official Docker documentation before running the setup again."
                ;;
        esac
    else
        error_exit "Unable to identify the OS. Please check the official Docker documentation before running the setup again."
    fi
}

# ============================================================================
# System Package Installation
# ============================================================================

install_python_venv() {
    local python_version
    python_version=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null)
    local venv_package="python${python_version}-venv"

    log_info "Detected Python version: $python_version"
    log_info "Installing $venv_package..."

    # Try to install the version-specific venv package
    if apt install -qq -y "$venv_package" 2>/dev/null; then
        log_success "Successfully installed $venv_package"
        return 0
    fi

    # If that fails, try some common alternatives
    log_warning "Failed to install $venv_package, trying alternatives..."

    local alternatives=("python3-venv" "python3.13-venv" "python3.12-venv" "python3.11-venv")

    for alt in "${alternatives[@]}"; do
        log_info "Trying $alt..."
        if apt install -qq -y "$alt" 2>/dev/null; then
            log_success "Successfully installed $alt"
            return 0
        fi
    done

    error_exit "Failed to install any Python venv package. Please install manually."
}

update_system() {
    log_info "Updating system packages..."
    export DEBIAN_FRONTEND=noninteractive

    apt update -qq
    apt upgrade -y -qq

    DEBIAN_FRONTEND=noninteractive apt install -qq -y \
        apt-transport-https \
        ca-certificates \
        curl \
        software-properties-common \
        net-tools \
        zip \
        git \
        python3-pip \
        wget \
        pipx

    # install_python_venv

    log_success "System packages updated"
}

# ============================================================================
# Docker Installation
# ============================================================================

install_docker() {
    if command -v docker >/dev/null 2>&1; then
        log_info "Docker is already installed"
        return 0
    fi

    log_info "Installing Docker..."

    local DISTRO
    DISTRO=$(identify_os)

    curl -fsSL "https://download.docker.com/linux/${DISTRO}/gpg" | \
        gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/${DISTRO} $(lsb_release -cs) stable" | \
        tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt update -qq
    apt install -qq -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

    if [[ -n "${SUDO_USER:-}" ]]; then
        usermod -aG docker "$SUDO_USER"
        log_info "Added $SUDO_USER to docker group"
    fi

    log_success "Docker installed successfully"
}

# ============================================================================
# Directory Setup
# ============================================================================

create_and_set_owner() {
    local working_dir="${CONFIG[WORKING_DIR]}"
    local upload_folder="$working_dir/data/CTFd/uploads"
    local log_folder="$working_dir/data/CTFd/logs"

    log_info "Creating necessary directories and setting ownership..."

    # Create directories
    mkdir -p "$upload_folder"
    mkdir -p "$log_folder"
    mkdir -p "$working_dir/data/galvanize/challenges"
    mkdir -p "$working_dir/data/galvanize/playbooks"


    chown -R "${SUDO_USER:-$USER}:${SUDO_USER:-$USER}" "$working_dir/data"

    # Change ownership to 1001
    chown -R 1001:1001 "$upload_folder"
    chown -R 1001:1001 "$log_folder"

    log_success "Directories created and ownership set successfully"
}

# ============================================================================
# Theme Management
# ============================================================================

setup_custom_theme() {
    local theme_source="${CONFIG[THEME]}"
    local working_dir="${CONFIG[WORKING_DIR]}"
    local custom_theme_dir="$working_dir/data/CTFd/themes/custom"
    
    if [[ -z "$theme_source" ]]; then
        log_info "No custom theme specified"
        return 0
    fi
    
    log_info "Setting up custom theme from: $theme_source"
    
    # Clean up any existing custom theme directory
    if [[ -d "$custom_theme_dir" ]]; then
        log_info "Removing existing custom theme directory..."
        rm -rf "$custom_theme_dir"
    fi
    
    mkdir -p "$custom_theme_dir"
    
    if is_git_url "$theme_source"; then
        # Clone the git repository
        log_info "Detected git URL, cloning repository..."
        local clone_dir="$working_dir/theme-clone-temp"
        
        # Clean up any existing clone directory
        if [[ -d "$clone_dir" ]]; then
            rm -rf "$clone_dir"
        fi
        
        if git clone "$theme_source" "$clone_dir"; then
            log_success "Repository cloned successfully"
            
            # Copy the contents to the custom theme directory
            cp -r "$clone_dir"/* "$custom_theme_dir"/
            
            # Clean up clone directory
            rm -rf "$clone_dir"
        else
            log_error "Failed to clone git repository: $theme_source"
            return 1
        fi
    else
        # Use local folder
        if [[ ! -d "$theme_source" ]]; then
            log_error "Theme directory not found: $theme_source"
            return 1
        fi
        
        log_info "Copying local theme directory..."
        if cp -r "$theme_source"/* "$custom_theme_dir"/; then
            log_success "Local theme copied successfully"
        else
            log_error "Failed to copy local theme"
            return 1
        fi
    fi
    
    # Set proper ownership
    chown -R 1001:1001 "$custom_theme_dir"
    
    log_success "Custom theme setup completed at: $custom_theme_dir"
    return 0
}

# ============================================================================
# CTFd Installation
# ============================================================================

install_ctfd() {
    local working_dir="${CONFIG[WORKING_DIR]}"
    local plugin_name="zync"
    local plugin_path="$working_dir/$plugin_name"
    local compose_file="$working_dir/infra/docker-compose.yml"

    log_info "Installing CTFd..."

    if [[ ! -d $plugin_path ]]; then
        log_info "Cloning zync instancer plugin..."
        git -C "$working_dir" clone "$DOCKER_PLUGIN_REPO"
    else
        log_info "Zync plugin already exists, updating..."
        git -C "$plugin_path" pull
    fi    
    log_success "Instancer plugin configuration complete"

    if [[ "${CONFIG[INSTANCER_URL]:-}" == "" ]]; then
        local instancer_path="$working_dir/galvanize"
        local cert_dir="${CONFIG[WORKING_DIR]}/cert"
        local PRIVATE_KEY_PATH="$cert_dir/galvanize-instancer-key"
        local PUBLIC_KEY_PATH="${PRIVATE_KEY_PATH}.pub"
        local CONFIG_PATH="$working_dir/data/galvanize/config.yaml"
        log_info "Setting up local instancer..."

        if [[ ! -d $instancer_path ]]; then
            log_info "Cloning galvanize instancer..."
            git -C "$working_dir" clone "$DOCKER_INSTANCER_REPO"
        else
            log_info "Instancer already exists, updating..."
            git -C "$instancer_path" pull
        fi
        cp "$instancer_path/config.example.yaml" "$CONFIG_PATH"

        mkdir -p "$cert_dir"         

        ssh-keygen -t rsa -b 4096 -f "$PRIVATE_KEY_PATH" -N "" -q
        chmod 600 "$PRIVATE_KEY_PATH"
        chown "${SUDO_USER:-$USER}:${SUDO_USER:-$USER}" "$PRIVATE_KEY_PATH"

        chmod 644 "$PUBLIC_KEY_PATH"

        cat "$PUBLIC_KEY_PATH" >> "/home/${SUDO_USER:-$USER}/.ssh/authorized_keys"

        setup_env_key GALVANIZE_REPO_PATH "$instancer_path"
        setup_env_key GALVANIZE_CONFIG_PATH "$CONFIG_PATH"
        setup_env_key SSH_KEY_PATH "$PRIVATE_KEY_PATH"
        mkdir -p "$working_dir/data/galvanize"
        cp -a "$instancer_path/data/." "$working_dir/data/galvanize"
        chown -R "${SUDO_USER:-$USER}:${SUDO_USER:-$USER}" "$working_dir/data/galvanize"
    fi


    # Configure plugin access in DB --> add JWT key + instancer URL

    if [[ -f $compose_file ]]; then
        cp "$compose_file" "$compose_file.backup"
    fi

    log_info "Generating secure secrets..."

    local secret_key
    local db_password
    local db_root_password
    local jwt_secret_key

    secret_key=$(generate_password 32)
    db_password=$(generate_password 16)
    db_root_password=$(generate_password 16)
    jwt_secret_key=$(generate_password 48)
    CONFIG[JWT_SECRET_KEY]="$jwt_secret_key"

    log_info "Updating configuration with new secrets..."

    setup_env_key SECRET_KEY "$secret_key"
    setup_env_key MARIADB_PASSWORD "$db_password"
    setup_env_key MARIADB_ROOT_PASSWORD "$db_root_password"

    log_info "Configuration updated with new secrets"
    setup_env_key BASE_DOMAIN "${CONFIG[CTFD_URL]}"

    log_info "Pulling and building necessary docker images..."
    log_info "Building docker images... This may take a while"
    docker compose -f "$compose_file" build
    log_success "Docker images successfully built"
    docker compose -f "$compose_file" pull -q
    log_success "Docker images successfully pulled"

    if [[ -n "${CONFIG[THEME]}" ]]; then
        log_info "Custom theme option enabled"
        
        if setup_custom_theme; then
            sed -i '/#.*themes\/custom:/s/^#//' "$compose_file"
            log_success "Custom theme volume mount enabled in docker-compose.yml"
        else
            log_warning "Theme setup failed, but continuing with setup"
            log_warning "You may need to manually configure the theme later"
        fi
    fi

    log_info "To start the CTFd containers, please run the following command in a properly configured session:"
    echo -e "\tdocker compose -f "$compose_file" up -d"

    log_success "CTFd installation complete!"

    log_info "Generated secrets:"
    log_info "  Secret Key: $secret_key"
    log_info "  DB Password: $db_password"
    log_info "  DB Root Password: $db_root_password"
}

# ============================================================================
# Instancer Configuration
# ============================================================================

configure_instancer() {
    local working_dir="${CONFIG[WORKING_DIR]}"
    local instancer_path="$working_dir/galvanize"
    local CONFIG_PATH="$working_dir/data/galvanize/config.yaml"

    sed -i "s|your-secret-key-here|${CONFIG[JWT_SECRET_KEY]}|g" "$CONFIG_PATH"
    sed -i "s|your-ssh-user|"${SUDO_USER:-$USER}"|g" "$CONFIG_PATH"
    sed -i "s|your-server-ip,|${CONFIG[CTFD_URL]},|g" "$CONFIG_PATH"
    sed -i "s|challs.example.com|${CONFIG[CTFD_URL]}|g" "$CONFIG_PATH"

    log_success "Local instancer setup complete"
}

# ============================================================================
# Backup System
# ============================================================================

setup_backup_script() {
    local working_dir="${CONFIG[WORKING_DIR]}"
    local infra_dir="$working_dir/infra"
    local backup_script_src="$infra_dir/backup_db.sh"
    local backup_script_dest="$working_dir/backup_db.sh"
    
    log_info "Setting up database backup script..."
    
    if [[ ! -f "$backup_script_src" ]]; then
        log_error "Backup script not found at: $backup_script_src"
        log_warning "Skipping backup script setup"
        return 1
    fi
    
    # Copy backup script to working directory
    cp "$backup_script_src" "$backup_script_dest"
    chmod +x "$backup_script_dest"
    chown "${SUDO_USER:-$USER}:${SUDO_USER:-$USER}" "$backup_script_dest"
    
    log_success "Backup script copied to: $backup_script_dest"
}

setup_backup_cron() {
    local working_dir="${CONFIG[WORKING_DIR]}"
    local backup_script="$working_dir/backup_db.sh"
    local cron_log="$working_dir/cron_backup.log"
    local user="${SUDO_USER:-$USER}"
    local schedule="${CONFIG[BACKUP_SCHEDULE]}"
    
    log_info "Setting up backup cron job with schedule: $schedule"
    
    # Define cron schedule based on configuration
    local cron_schedule
    case "$schedule" in
        daily)
            cron_schedule="0 4 * * *"
            ;;
        hourly)
            cron_schedule="0 * * * *"
            ;;
        10min)
            cron_schedule="*/10 * * * *"
            ;;
        *)
            log_error "Invalid backup schedule: $schedule"
            return 1
            ;;
    esac
    
    # Create cron entry
    local cron_entry="$cron_schedule $backup_script >> $cron_log 2>&1"
    
    # Check if cron entry already exists
    if crontab -u "$user" -l 2>/dev/null | grep -Fq "$backup_script"; then
        log_warning "Cron job for backup script already exists, skipping..."
        return 0
    fi
    
    # Add cron entry
    (crontab -u "$user" -l 2>/dev/null || true; echo "$cron_entry") | crontab -u "$user" -
    
    # Create log file with proper permissions
    touch "$cron_log"
    chown "$user:$user" "$cron_log"
    
    case "$schedule" in
        daily)
            log_success "Cron job added: Daily backup at 4:00 AM"
            ;;
        hourly)
            log_success "Cron job added: Hourly backups at the top of each hour"
            ;;
        10min)
            log_success "Cron job added: Backups every 10 minutes"
            ;;
    esac
    
    log_info "Backup logs will be written to: $cron_log"
}

# ============================================================================
# Main Execution
# ============================================================================

main() {
    log_info "Starting CTFd server setup..."

    update_system

    # install_pipx
    install_docker

    create_and_set_owner

    install_ctfd
    configure_instancer 

    # Setup database backup
    setup_backup_script
    setup_backup_cron

    log_success "CTFd server setup completed successfully!"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    ensure_root "$@"
    parse_arguments "$@"
    main
fi