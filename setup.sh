#!/bin/bash

set -euo pipefail  # Exit on error, undefined variables, and pipe failures

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

error_exit() {
    log_error "$1"
    exit "${2:-1}"
}

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

declare -A CONFIG=(
    [GENERATE_CERTS]="true"
    [CONFIGURE_DOCKER]="true"
    [WORKING_DIR]="/home/${SUDO_USER:-$USER}"
    [THEME]="false"
)

declare -A CERT_CONFIG=(
    [COUNTRY]="CA"
    [STATE]="Quebec"
    [CITY]="Montreal"
    [ORGANISATION]="PolyCyber"
    [OU]="PolyCyber"
    [CN]="polycyber.io"
    [EMAIL]="infra@polycyber.io"
)

declare -A CERT_FILES=(
    [CA_KEY]="ca-key.pem"
    [CA_CERT]="ca-cert.pem"
    [SERVER_KEY]="server-key.pem"
    [SERVER_CERT]="server-cert.pem"
    [CLIENT_KEY]="client-key.pem"
    [CLIENT_CERT]="client-cert.pem"
)

readonly HOST="127.0.0.11"
readonly DOCKER_CONTAINER_IP="172.20.0.2"
readonly DOCKER_PLUGIN_REPO="https://github.com/polycyber/CTFd-Docker-Challenges"

show_usage() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS]

Options:
    --ctfd-url URL          Set CTFd URL (mandatory)
    --working-folder DIR    Set working directory (default: /home/\$USER)
    --theme                 Enable custom theme (default: false)
    --help                  Show this help message

Examples:
    $SCRIPT_NAME --ctfd-url example.com
    $SCRIPT_NAME --ctfd-url example.com --working-folder /opt/ctfd
    $SCRIPT_NAME --ctfd-url example.com --theme
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
                CONFIG[THEME]="true"
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
}

generate_password() {
    local length="${1:-15}"
    openssl rand -base64 "$((length * 3 / 4))" | tr -d '+/=' | head -c "$length"
}

install_python_venv() {
    local python_version
    python_version=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null)
    local venv_package="python${python_version}-venv"

    log_info "Detected Python version: $python_version"
    log_info "Installing $venv_package..."

    # Try to install the version-specific venv package
    if apt-get install -qq -y "$venv_package" 2>/dev/null; then
        log_success "Successfully installed $venv_package"
        return 0
    fi

    # If that fails, try some common alternatives
    log_warning "Failed to install $venv_package, trying alternatives..."

    local alternatives=("python3-venv" "python3.13-venv" "python3.12-venv" "python3.11-venv")

    for alt in "${alternatives[@]}"; do
        log_info "Trying $alt..."
        if apt-get install -qq -y "$alt" 2>/dev/null; then
            log_success "Successfully installed $alt"
            return 0
        fi
    done

    error_exit "Failed to install any Python venv package. Please install manually."
}

update_system() {
    log_info "Updating system packages..."
    export DEBIAN_FRONTEND=noninteractive

    apt-get update -qq
    apt-get upgrade -y -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -qq -y \
        apt-transport-https \
        ca-certificates \
        curl \
        software-properties-common \
        net-tools \
        zip \
        git \
        python3-pip \
        wget

    install_python_venv

    log_success "System packages updated"
}

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

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] \
          https://download.docker.com/linux/${DISTRO} $(lsb_release -cs) stable" | \
        tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update -qq
    apt-get install -qq -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin

    if command -v docker >/dev/null 2>&1; then
        log_success "Docker installed successfully"
        setup_docker_group
    else
        error_exit "Docker installation failed"
    fi
}

setup_docker_group() {
    log_info "Setting up Docker group..."

    if ! getent group docker >/dev/null; then
        groupadd docker
    fi

    local user="${SUDO_USER:-$USER}"
    usermod -aG docker "$user"

    log_warning "User '$user' added to docker group"
    log_warning "You may need to log out and back in for group changes to take effect"
}

install_pipx() {
    log_info "Installing pipx..."
    local pipx_version
    pipx_version=$(pipx --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "")

    if [[ $pipx_version != "1.7" ]]; then
        su - $SUDO_USER -c "python3 -m pip install --user --break-system-packages pipx"
        su - $SUDO_USER -c "python3 -m pipx ensurepath"
        # Manually add pipx to PATH for the specific user
        su - $SUDO_USER -c "echo 'export PATH=\$PATH:\$HOME/.local/bin' >> ~/.bashrc"
    fi
    log_success "pipx installed and configured"
}

create_certificates() {
    local cert_dir="${CONFIG[WORKING_DIR]}/cert"
    local ca_password

    ca_password=$(generate_password 32)

    log_info "Creating certificates in $cert_dir..."

    mkdir -p "$cert_dir"
    cd "$cert_dir" || error_exit "Cannot access certificate directory"

    log_info "Generating CA private key..."
    openssl genrsa -aes256 -passout "pass:$ca_password" -out "${CERT_FILES[CA_KEY]}" 4096

    log_info "Generating CA certificate..."
    openssl req -new -x509 -days 365 \
        -key "${CERT_FILES[CA_KEY]}" \
        -passin "pass:$ca_password" \
        -sha256 \
        -out "${CERT_FILES[CA_CERT]}" \
        -subj "/C=${CERT_CONFIG[COUNTRY]}/ST=${CERT_CONFIG[STATE]}/L=${CERT_CONFIG[CITY]}/O=${CERT_CONFIG[ORGANISATION]}/OU=${CERT_CONFIG[OU]}/CN=${CERT_CONFIG[CN]}/emailAddress=${CERT_CONFIG[EMAIL]}"

    cat "${CERT_FILES[CA_CERT]}" >> /etc/ssl/certs/ca-certificates.crt
    update-ca-certificates

    log_info "Generating server certificates..."
    openssl genrsa -out "${CERT_FILES[SERVER_KEY]}" 4096
    openssl req -subj "/CN=$HOST" -sha256 -new \
        -key "${CERT_FILES[SERVER_KEY]}" \
        -out server.csr

    cat > server-extfile.cnf << EOF
subjectAltName = DNS:$HOST,IP:$DOCKER_CONTAINER_IP
extendedKeyUsage = serverAuth
EOF

    openssl x509 -req -days 365 -sha256 \
        -in server.csr \
        -CA "${CERT_FILES[CA_CERT]}" \
        -CAkey "${CERT_FILES[CA_KEY]}" \
        -passin "pass:$ca_password" \
        -CAcreateserial \
        -out "${CERT_FILES[SERVER_CERT]}" \
        -extfile server-extfile.cnf

    log_info "Generating client certificates..."
    openssl genrsa -out "${CERT_FILES[CLIENT_KEY]}" 4096
    openssl req -subj '/CN=client' -new \
        -key "${CERT_FILES[CLIENT_KEY]}" \
        -out client.csr

    echo "extendedKeyUsage = clientAuth" > client-extfile.cnf

    openssl x509 -req -days 365 -sha256 \
        -in client.csr \
        -CA "${CERT_FILES[CA_CERT]}" \
        -CAkey "${CERT_FILES[CA_KEY]}" \
        -passin "pass:$ca_password" \
        -CAcreateserial \
        -out "${CERT_FILES[CLIENT_CERT]}" \
        -extfile client-extfile.cnf

    rm -f server.csr client.csr server-extfile.cnf client-extfile.cnf

    zip -j cert.zip "${CERT_FILES[CA_CERT]}" "${CERT_FILES[CLIENT_CERT]}" "${CERT_FILES[CLIENT_KEY]}"

    chmod 0400 "${CERT_FILES[CA_KEY]}" "${CERT_FILES[CLIENT_KEY]}" "${CERT_FILES[SERVER_KEY]}"
    chmod 0444 "${CERT_FILES[CA_CERT]}" "${CERT_FILES[SERVER_CERT]}" "${CERT_FILES[CLIENT_CERT]}"

    log_success "Certificates created successfully in $cert_dir"
    log_info "Generated secrets:"
    log_info "  CA password: $ca_password"
}

configure_docker_tls() {
    local cert_dir="${CONFIG[WORKING_DIR]}/cert"
    local docker_conf_dir="/etc/systemd/system/docker.service.d"
    local docker_conf_file="$docker_conf_dir/override.conf"

    log_info "Configuring Docker for TLS..."

    local required_certs=(
        "$cert_dir/${CERT_FILES[CA_CERT]}"
        "$cert_dir/${CERT_FILES[SERVER_CERT]}"
        "$cert_dir/${CERT_FILES[SERVER_KEY]}"
    )

    local missing_certs=()
    for cert in "${required_certs[@]}"; do
        if [[ ! -f $cert ]]; then
            missing_certs+=("$cert")
        fi
    done

    if [[ ${#missing_certs[@]} -gt 0 ]]; then
        log_info "Generating missing certificates..."
        create_certificates
    fi

    mkdir -p "$docker_conf_dir"

    if [[ -f $docker_conf_file ]]; then
        cp "$docker_conf_file" "$docker_conf_file.backup"
    fi

    local dockerd_path
    dockerd_path=$(command -v dockerd) || error_exit "dockerd not found"

    cat > "$docker_conf_file" << EOF
[Service]
ExecStart=
ExecStart=$dockerd_path --tls --tlsverify --tlscacert=$cert_dir/${CERT_FILES[CA_CERT]} --tlscert=$cert_dir/${CERT_FILES[SERVER_CERT]} --tlskey=$cert_dir/${CERT_FILES[SERVER_KEY]} -H=172.17.0.1:2376 -H=fd://
EOF

    systemctl daemon-reload
    systemctl restart docker.service

    if netstat -lntp 2>/dev/null | grep -q dockerd; then
        log_success "Docker TLS configuration complete"
    else
        error_exit "Docker TLS configuration failed - port not listening"
    fi
}

copy_themes() {
    local working_dir="${CONFIG[WORKING_DIR]}"
    local source_theme="$working_dir/infra/core-beta"
    local themes_dir="$working_dir/data/CTFd/themes"
    
    log_info "Setting up custom themes..."
    
    # Check if source theme exists
    if [[ ! -d "$source_theme" ]]; then
        log_warning "Theme source directory not found: $source_theme"
        log_warning "Please ensure the core-beta theme exists in the infra folder"
        return 1
    fi
    mkdir -p "$themes_dir"
    
    log_info "Copying core-beta theme..."
    if cp -r "$source_theme" "$themes_dir/core-beta"; then
        log_success "core-beta theme copied successfully"
    else
        log_error "Failed to copy core-beta theme"
        return 1
    fi
    
    log_info "Copying core-beta theme for custom themes..."
    if cp -r "$source_theme" "$themes_dir/custom"; then
        log_success "Custom theme created successfully"
    else
        log_error "Failed to create custom theme"
        return 1
    fi
        
    log_success "Themes setup completed successfully"
    
    return 0
}

install_ctfd() {
    local working_dir="${CONFIG[WORKING_DIR]}"
    local plugin_name="CTFd-Docker-Challenges"
    local plugin_path="$working_dir/$plugin_name"
    local compose_file="$working_dir/infra/docker-compose.yml"

    log_info "Installing CTFd..."

    if [[ ! -d $plugin_path ]]; then
        log_info "Cloning CTFd Docker Challenges plugin..."
        git -C "$working_dir" clone "$DOCKER_PLUGIN_REPO"
    else
        log_info "Plugin already exists, updating..."
        git -C "$plugin_path" pull
    fi

    if [[ -f $compose_file ]]; then
        cp "$compose_file" "$compose_file.backup"
    fi

    log_info "Generating secure secrets..."

    local secret_key
    local db_password
    local db_root_password

    secret_key=$(generate_password 32)
    db_password=$(generate_password 16)
    db_root_password=$(generate_password 16)

    log_info "Updating configuration with new secrets..."

    sed -i "s/SECRET_KEY=.*/SECRET_KEY=$secret_key/" "$compose_file"

    sed -i "s/db_password/$db_password/g" "$compose_file"
    sed -i "s/db_root_password/$db_root_password/g" "$compose_file"
    log_info "Configuration updated with new secrets"

    sed -i "s|BASE_DOMAIN=.*|BASE_DOMAIN=${CONFIG[CTFD_URL]}|" "$compose_file"

    log_info "Pulling necessary docker images..."
    docker compose -f "$compose_file" pull -q
    log_success "Docker images successfully pulled"

    if [[ "${CONFIG[THEME]}" == "true" ]]; then
        log_info "Custom theme option enabled"
        
        if copy_themes; then
            sed -i '/#.*themes:/s/^#//' "$compose_file"
            log_success "Theme volume mount enabled in docker-compose.yml"
        else
            log_warning "Theme copy failed, but continuing with setup"
            log_warning "You may need to manually copy themes later"
        fi
    fi

    log_info "To start the CTFd containers, please run the following command in a properly configured session:"
    echo -e "\tdocker compose -f "$compose_file" up -d"

    log_success "CTFd installation complete!"
    log_info "Download certificates with: scp -r ${SUDO_USER:-$USER}@<server_ip>:${CONFIG[WORKING_DIR]}/cert/cert.zip <local_path>"

    log_info "Generated secrets:"
    log_info "  Secret Key: $secret_key"
    log_info "  DB Password: $db_password"
    log_info "  DB Root Password: $db_root_password"
}

create_and_set_owner() {
    local working_dir="${CONFIG[WORKING_DIR]}"
    local upload_folder="$working_dir/data/CTFd/uploads"
    local log_folder="$working_dir/data/CTFd/logs"
    local themes_folder="$working_dir/data/CTFd/themes"

    log_info "Creating necessary directories and setting ownership..."

    # Create directories
    mkdir -p "$upload_folder"
    mkdir -p "$log_folder"
    mkdir -p "$themes_folder"

    # Change ownership to 1001
    chown -R 1001:1001 "$upload_folder"
    chown -R 1001:1001 "$log_folder"
    chown -R 1001:1001 "$themes_folder"

    log_success "Directories created and ownership set successfully"
}

main() {
    log_info "Starting CTFd server setup..."

    update_system

    install_pipx
    install_docker

    create_certificates

    configure_docker_tls

    create_and_set_owner

    install_ctfd

    log_success "CTFd server setup completed successfully!"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    ensure_root "$@"
    parse_arguments "$@"
    main
fi