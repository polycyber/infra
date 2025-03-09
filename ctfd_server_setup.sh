#!/bin/bash

# Ensure the script is run as root, otherwise prompt for sudo password
if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root. Please enter your password."
    exec sudo bash "$0" "$@"
else 
  echo "Running script as root..."
fi

GENERATE_CERTS="true"
CONFIGURE_DOCKER="true"

USER=${SUDO_USER:-$USER}

WORKING_FOLDER="/home/$USER"
FULL_CERT_PATH="$WORKING_FOLDER/cert"

CA_PASSWORD="changeme"

# Cert files
CA_KEY_FILE="ca-key.pem"
CA_CERT_FILE="ca-cert.pem"
SERVER_KEY_FILE="server-key.pem"
SERVER_CERT_FILE="server-cert.pem"
CLIENT_KEY_FILE="client-key.pem"
CLIENT_CERT_FILE="client-cert.pem"

# Details for docker deployment
HOST="127.0.0.11"
DOCKER_CONTAINER_IP="172.18.0.2"

# Details for CTFd settings and challenge repo settings

DOCKER_PLUGIN_REPO="https://github.com/polycyber/CTFd-Docker-Challenges"

# nano ctfd_server_setup.sh && chmod +x ctfd_server_setup.sh && ./ctfd_server_setup.sh
# scp -r <user>@<server_ip>:/home/<remote_user>/cert/cert.zip <local_path_for_cert>
main() {
  # Configure silent app restart for Ubuntu 22.04
  if grep -q "Ubuntu 22.04" /etc/os-release; then
    # Ensure needrestart auto-restarts services
    NEEDRESTART_CONF="/etc/needrestart/needrestart.conf"
    RESTART_CONFIG="\$nrconf{restart} = 'a'"

    if ! grep -qF "$RESTART_CONFIG" "$NEEDRESTART_CONF"; then
      echo "$RESTART_CONFIG" >> "$NEEDRESTART_CONF"
      echo "Configured needrestart to automatically restart services after upgrade."
    fi
  fi

  # Run apt update and upgrade without interaction
  export DEBIAN_FRONTEND=noninteractive
  apt update
  apt upgrade -yq

  ensure_pipx
  ensure_docker

  if [ "$GENERATE_CERTS" = "true" ]; then
    create_certs
  fi

  if [ "$CONFIGURE_DOCKER" = "true" ]; then
    configure_docker
  fi

  install_ctfd
}


ensure_docker() {
  if command -v docker >/dev/null 2>&1; then
    echo "Docker is already installed."
  else
    echo "Docker is not installed. Installing Docker..."
    apt-get install -y apt-transport-https ca-certificates curl software-properties-common net-tools zip
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    if command -v docker >/dev/null 2>&1; then
        echo "Docker has been successfully installed."
        post_install_docker
    else
        echo "Docker installation failed."
    fi
  fi
}

post_install_docker() {
  echo "Applying post-install steps for Docker..."
  # Create the docker group if it doesn't exist
  if ! getent group docker; then
    groupadd docker
  fi

  # Add the non-root user to the docker group
  USER=${SUDO_USER:-$USER}
  usermod -aG docker $USER

  echo "Docker post-install steps completed. You will be logged out to force the user's groups to be correctly loaded on the new session. Run the script again to complete the setup."
  pkill -KILL -u "$USER"
}

create_certs() {
  SERVER_CSR_FILE="server.csr"
  CLIENT_CSR_FILE="client.csr"
  
  CERT_COUNTRY="CA"
  CERT_STATE="Quebec"
  CERT_CITY="Montreal"
  CERT_ORGANISATION="PolyCyber"
  CERT_OU="PolyCyber"
  CERT_CN="polycyber.io"
  CERT_EMAIL_ADDRESS="infra@polycyber.io"


  echo "Creating certs in folder $FULL_CERT_PATH..."
  mkdir -p "$FULL_CERT_PATH"
  cd "$FULL_CERT_PATH" || return

  echo "Generating CA Private Key..."
  openssl genrsa -aes256 -passout pass:$CA_PASSWORD -out "$CA_KEY_FILE" 4096
  echo "Generating CA..."
  openssl req -new -x509 -days 365 -key "$CA_KEY_FILE" -passin pass:$CA_PASSWORD -sha256 -out "$CA_CERT_FILE" \
    -subj "/C=$CERT_COUNTRY/ST=$CERT_STATE/L=$CERT_CITY/O=$CERT_ORGANISATION/OU=$CERT_OU/CN=$CERT_CN/emailAddress=$CERT_EMAIL_ADDRESS"

  echo "Generating Server Key..."
  openssl genrsa -out "$SERVER_KEY_FILE" 4096
  echo "Generating Server CSR..."
  openssl req -subj "/CN=$HOST" -sha256 -new -key "$SERVER_KEY_FILE" -out "$SERVER_CSR_FILE"

  echo "subjectAltName = DNS:$HOST,IP:$DOCKER_CONTAINER_IP
  extendedKeyUsage = serverAuth" > extfile.cnf

  echo "Generating Server Cert..."
  openssl x509 -req -days 365 -sha256 -in "$SERVER_CSR_FILE" -CA "$CA_CERT_FILE" -CAkey "$CA_KEY_FILE" -passin "pass:$CA_PASSWORD" -CAcreateserial -out "$SERVER_CERT_FILE" -extfile extfile.cnf

  echo "Generating Client Key..."
  openssl genrsa -out "$CLIENT_KEY_FILE" 4096
  openssl req -subj '/CN=client' -new -key "$CLIENT_KEY_FILE" -out "$CLIENT_CSR_FILE"

  echo "extendedKeyUsage = clientAuth" > extfile-client.cnf
  echo "Generating Client Cert..."
  openssl x509 -req -days 365 -sha256 -in "$CLIENT_CSR_FILE" -CA "$CA_CERT_FILE" -CAkey "$CA_KEY_FILE" -passin "pass:$CA_PASSWORD" -CAcreateserial -out "$CLIENT_CERT_FILE" -extfile extfile-client.cnf

  rm -v "$CLIENT_CSR_FILE" "$SERVER_CSR_FILE" extfile.cnf extfile-client.cnf
  zip -j cert.zip "$CA_CERT_FILE" "$CLIENT_CERT_FILE" "$CLIENT_KEY_FILE"
  chmod -v 0400 "$CA_KEY_FILE" "$CLIENT_KEY_FILE" "$SERVER_KEY_FILE"
  chmod -v 0444 "$CA_CERT_FILE" "$SERVER_CERT_FILE" "$CLIENT_CERT_FILE"
  echo "Cert files generated in folder $FULL_CERT_PATH!"
}

configure_docker() {
  DOCKER_CONF_PATH="/etc/systemd/system/docker.service.d"
  DOCKER_CONF_FILE="override.conf"
  DOCKER_CONF_ABSOLUTE_PATH="$DOCKER_CONF_PATH/$DOCKER_CONF_FILE"


  echo "Configuring docker for TLS socket: file $DOCKER_CONF_ABSOLUTE_PATH"

  REQUIRED_CERTS=("$FULL_CERT_PATH/$CA_CERT_FILE" "$FULL_CERT_PATH/$SERVER_CERT_FILE" "$FULL_CERT_PATH/$SERVER_KEY_FILE")

  MISSING_CERTS=false
  for cert in "${REQUIRED_CERTS[@]}"; do
    if [ ! -f "$cert" ]; then
      echo "Missing required certificate: $cert"
      MISSING_CERTS=true
    fi
  done

  if [ "$MISSING_CERTS" = true ]; then
    if [ "$GENERATE_CERTS" = "true" ]; then
      echo "Generating missing certificates..."
      create_certs
    else
      echo "TLS certificates are missing but automatic generation is disabled."
      read -rp "Do you want to generate the certificates now? (y/n): " USER_INPUT
      case "$USER_INPUT" in
          [Yy]* ) create_certs ;;
          [Nn]* ) echo "Cannot configure Docker without certificates. Exiting."; exit 1 ;;
          * ) echo "Invalid input. Exiting."; exit 1 ;;
      esac
    fi
  fi

  if [ -d "$DOCKER_CONF_PATH" ]; then
    echo "Trying to backup any .conf file in $DOCKER_CONF_PATH..."
    for file in "$DOCKER_CONF_PATH"/*.conf; do
      if [ "$file" != "$DOCKER_CONF_ABSOLUTE_PATH" ]; then
        mv "$file" "$file.bk" || true
      fi
    done
  else 
    echo "$DOCKER_CONF_PATH doesn't exist, creating it instead..."
    mkdir -p "$DOCKER_CONF_PATH"
  fi
  DOCKERD_PATH=$(command -v dockerd)

  if [ -z "$DOCKERD_PATH" ]; then
    echo "Error: dockerd binary not found. Is Docker installed?"
    exit 1
  else
    echo "Using dockerd path: $DOCKERD_PATH"
  fi

  NEW_CONFIG=$(cat <<EOF
[Service]
ExecStart=
ExecStart=$DOCKERD_PATH --tls --tlsverify --tlscacert=$FULL_CERT_PATH/$CA_CERT_FILE --tlscert=$FULL_CERT_PATH/$SERVER_CERT_FILE --tlskey=$FULL_CERT_PATH/$SERVER_KEY_FILE -H=172.17.0.1:2376 -H=fd://
EOF
  )

  if [ -f "$DOCKER_CONF_ABSOLUTE_PATH" ]; then
    EXISTING_CONFIG=$(cat "$DOCKER_CONF_ABSOLUTE_PATH")
    if [ "$EXISTING_CONFIG" = "$NEW_CONFIG" ]; then
      echo "Docker configuration is up to date."
    else
      echo "Updating Docker configuration..."
      mv "$DOCKER_CONF_ABSOLUTE_PATH" "$DOCKER_CONF_ABSOLUTE_PATH.bk" || true
      echo "$NEW_CONFIG" > "$DOCKER_CONF_ABSOLUTE_PATH"
      
      systemctl daemon-reload
      systemctl restart docker.service
    fi
  else
    echo "Creating Docker configuration..."
    echo "$NEW_CONFIG" > "$DOCKER_CONF_ABSOLUTE_PATH"
    
    systemctl daemon-reload
    systemctl restart docker.service
  fi


  if netstat -lntp | grep -q dockerd; then
    echo "Docker configuration complete!"
  else
    echo "Error configuring Docker: port not open"
  fi
}


ensure_pipx() {
  # Pipx needs to be version >=1.6 for global flag to work, and Ubuntu repo currently only has 1.4, so we need to install it with itself instead and purge the 1.4 version (see issue https://github.com/pypa/pipx/issues/1481)
  PIPX_VERSION=$(pipx --version 2>/dev/null)
  if [[ $PIPX_VERSION =~ ([0-9]+\.[0-9]+) ]]; then
    INSTALLED_VERSION="${BASH_REMATCH[1]}"
  else
    INSTALLED_VERSION=""
  fi

  if [[ -z "$INSTALLED_VERSION" || "$INSTALLED_VERSION" != "1.7" ]]; then
    echo "Installing pipx..."
    apt install -y pipx # Install 1.4
    pipx install pipx # Install 1.7 in ~/.local/bin/
    apt purge -y --autoremove pipx # Remove 1.4
    ~/.local/bin/pipx install --global pipx # Install 1.7 in /usr/local/bin/pipx
  fi

  if [ -f ~/.local/bin/pipx ]; then
    echo "Uninstalling pipx from ~/.local/bin/..."
    pipx uninstall pipx # Remove 1.7 from ~/.local/
  fi

  pipx ensurepath --global
}

ensure_gh() {
  (type -p wget >/dev/null || (sudo apt update && sudo apt-get install wget -y)) \
	&& sudo mkdir -p -m 755 /etc/apt/keyrings \
        && out=$(mktemp) && wget -nv -O$out https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        && cat $out | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
	&& sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
	&& echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
	&& sudo apt update \
	&& sudo apt install gh -y
}


install_ctfd() {
  CTFD_DOCKER_PLUGIN=$(basename "$DOCKER_PLUGIN_REPO")
  DOCKER_COMPOSE_FILE="docker-compose.yml"

  PLUGIN_PATH="$WORKING_FOLDER/$CTFD_DOCKER_PLUGIN"
  DOCKER_COMPOSE_PATH="$WORKING_FOLDER/$DOCKER_COMPOSE_FILE"

  DOCKER_COMPOSE_CONFIG=$(cat <<EOF
---
services:
  ctfd:
    image: ctfd/ctfd
    container_name: ctfd
    volumes:
      - $PLUGIN_PATH/docker_challenges:/opt/CTFd/CTFd/plugins/docker_challenges
    ports:
      - "8000:8000"
    restart: unless-stopped
EOF
    )

  echo "Cloning CTFd-Docker-Challenges plugin..."
  git -C "$WORKING_FOLDER" clone "$DOCKER_PLUGIN_REPO"
  echo "CTFd-Docker-Challenges plugin cloned!"

  if [ ! -f "$DOCKER_COMPOSE_PATH" ]; then
    echo "Creating Docker compose config for ctfd container..."
    echo "$DOCKER_COMPOSE_CONFIG" > "$DOCKER_COMPOSE_PATH"
  fi
  docker compose -f "$DOCKER_COMPOSE_PATH" up -d
  echo "CTFd started!"

  pipx install --global ctfcli
}

main