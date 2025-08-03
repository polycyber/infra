# PolyCyber Infrastructure

The purpose of this repository is to gather all the resources used to deploy PolyCyber's CTFd infrastructures (PolyPwn, as well as internal CTFd for PolyCyber) in order to share a functional and simplified method for deploying services.

## Available Scripts

### 1. CTFd Installation Script (`setup.sh`)

Bash script that automates the installation and configuration of a CTFd server with Docker secured via TLS and using the CTFd-Docker-Challenges plugin.

### 2. Challenge Management Tool (`challenges_management.sh`)

Bash script for building, ingesting, and synchronizing CTF challenges with support for Docker containers.

## Prerequisites

### For the CTFd installation script

- **Operating System**: Tested and verified on:
  - Ubuntu Server 24
  - Ubuntu Server 25
  - Debian 12
- **Privileges**: The script must be executed as root (automatically uses sudo if necessary)

### For the challenge management tool

- **Docker**: Installed and functional
- **CTFcli**: Installed via pipx (automatic installation if absent)
- **Challenge repository**: Folder structure with `challenge.yml` files

> [!CAUTION]
> **📍 Script Placement Requirement**: The challenge management script has specific placement requirements that are **essential** for proper operation. See the [detailed placement guide](#challenge-management-tool) before running the script.

## CTFd Server Installation

1. **Clone this repository**:
   ```bash
   git clone https://github.com/polycyber/infra
   cd infra
   chmod +x setup.sh challenges_management.sh
   mv challenges_management.sh ..
   ```

2. **Run the installation script and follow the instructions**:
   ```bash
   ./setup.sh --ctfd-url <your-domain.com>
   ```
3. **Go to the configured server URL**
   - Configure the CTF event
   - Navigate to the admin configuration panel: `Admin Panel` --> `Plugins` --> `Docker Config`
   - Enter the following information to initialize the plugin's connection to the Docker socket:
     - Hostname: `172.17.0.1:2376`
     - TLS Enabled: `Yes`
     - Retrieve the CA Cert / Client Cert / Client Key from the server once the setup is complete:
    ```bash
    scp -r <user>@<server_ip>:<working_dir>/cert/cert.zip <local_path>
    ```

## Usage

### Installation Script Options

| Option | Description | Required |
|--------|-------------|-------------|
| `--ctfd-url URL` | URL/domain of your CTFd server | ✅ Yes |
| `--working-folder DIR` | Working directory (default: `/home/$USER`) | ❌ No |
| `--theme` | Enables the use of a personalised theme | ❌ No |
| `--help` | Display help | ❌ No |

#### Installation Examples

```bash
# Basic installation with domain
./setup.sh --ctfd-url example.com

# Installation with custom directory
./setup.sh --ctfd-url example.com --working-folder /opt/ctfd

# Installation with custom theme
./setup.sh --ctfd-url exemple.com --theme

# Display help
./setup.sh --help
```

#### Custom theme configuration

If you use the `--theme` option, the script will automatically mount the theme folder in the `docker-compose.yml`. 

> [!WARNING]  
> You must copy the custom theme in the `theme/` folder before starting the containers. This folder will be automatically created during setup.

### Challenge Management Tool

> [!WARNING]
> **Script Location Requirements for Challenge Management**
> 
> The challenge management script relies on the `ctfcli` utility, which requires challenge directories to be located **below** its execution point in the file system hierarchy. This means the script must be placed at the same level as the challenges directory or in a parent directory.

#### **Correct Placement Examples**

| Component | Path | Status |
|-----------|------|--------|
| Challenges | `/home/user/challenges` | ✅ Works |
| Script | `/home/user/challenges_management.sh` | ✅ Works |

**Why this works:** The script is at the same level as the challenges directory, so `ctfcli` can access the challenges folder.

| Component | Path | Status |
|-----------|------|--------|
| Challenges | `/home/user/challenges` | ✅ Works |
| Script | `/home/challenges_management.sh` | ✅ Works |

**Why this works:** The script is in a parent directory, so `ctfcli` can still reach the challenges folder below it.

#### **Incorrect Placement Example**

| Component | Path | Status |
|-----------|------|--------|
| Challenges | `/home/user/challenges` | ❌ Fails |
| Script | `/home/user/infra/challenges_management.sh` | ❌ Fails |

**Why this fails:** The script is in a subdirectory (`infra`) that is at the same level as `challenges`. From this location, `ctfcli` cannot access the challenges directory because it's not in the script's hierarchical path.

#### Available Actions

| Action | Description |
|--------|-------------|
| `all` | Build + ingest (default) |
| `build` | Build Docker images only |
| `ingest` | Ingest challenges into CTFd |
| `sync` | Synchronize existing challenges |
| `status` | Display status and statistics |
| `cleanup` | Clean up Docker images |

#### Main Options

| Option | Description | Required |
|--------|-------------|-------------|
| `--ctf-repo REPO` | Name of the challenge repository present in the working directory | ✅ Yes |
| `--action ACTION` | Action to perform (all, build, ingest, sync, status, cleanup) | ❌ No |
| `--working-folder DIR` | Working directory (default: `/home/$USER`) | ❌ No |
| `--config FILE` | Load configuration from a file | ❌ No |

#### Filtering Options

| Option | Description |
|--------|-------------|
| `--categories LIST` | List of categories to process (comma-separated) |
| `--challenges LIST` | List of specific challenges to process (comma-separated) |

#### Behavior Options

| Option | Description |
|--------|-------------|
| `--dry-run` | Simulation mode (shows actions without executing them) |
| `--force` | Force operations (rebuild, overwrite) |
| `--parallel-builds N` | Number of parallel builds (default: 4) |
| `--backup-before-sync` | Create a backup before synchronization |

#### Debug Options

| Option | Description |
|--------|-------------|
| `--debug` | Enable debug output |
| `--skip-docker-check` | Skip Docker daemon check |
| `--help` | Display help |
| `--version` | Display version information |

#### Challenge Management Examples

```bash
# Full configuration (build + ingest)
./challenges_management.sh --ctf-repo PolyPwnCTF-2025-challenges

# Build only for certain categories
./challenges_management.sh --action build --ctf-repo PolyPwnCTF-2025-challenges --categories "web,crypto"

# Synchronization with forced update
./challenges_management.sh --action sync --ctf-repo PolyPwnCTF-2025-challenges --force

# Simulation mode to see planned actions
./challenges_management.sh --ctf-repo PolyPwnCTF-2025-challenges --dry-run

# Processing specific challenges
./challenges_management.sh --action build --ctf-repo PolyPwnCTF-2025-challenges --challenges "web-challenge-1,crypto-rsa"

# Parallel build with 8 threads
./challenges_management.sh --action build --ctf-repo PolyPwnCTF-2025-challenges --parallel-builds 8

# Display status
./challenges_management.sh --action status --ctf-repo PolyPwnCTF-2025-challenges

# Clean up Docker images
./challenges_management.sh --action cleanup --ctf-repo PolyPwnCTF-2025-challenges
```

#### Configuration File

Create a `.env` file with `KEY=VALUE` pairs:

```bash
CTF_REPO=PolyPwnCTF-2025-challenges
WORKING_DIR=/opt/ctf
PARALLEL_BUILDS=8
FORCE=true
DEBUG=false
```

Usage:
```bash
./challenges_management.sh --config .env
```

## Script Functionality

### CTFd Installation Script

#### 1. System Update
- Update system packages
- Install dependencies

#### 2. Docker Installation
- Add official Docker repository
- Install Docker CE, Docker Compose, etc.
- Configure user groups

#### 3. pipx Installation
- Install pipx for managing Python packages (specifically CTFcli)

#### 4. TLS Certificate Generation
The script automatically generates:
- **CA Certificates** (Certificate Authority)
- **Server Certificates** for Docker daemon
- **Client Certificates** for authentication via the CTFd-Docker-Challenges plugin
- **ZIP Archive** containing the necessary certificates

#### 5. Docker TLS Configuration
- Configure Docker daemon to use TLS

#### 6. Theme configuration (optionnal)
If the `--theme` flag is used:
- Mounts the `theme/` folder in the CTFd container
- Enables the use of custom themes
- The themes must be placed manually in the folder before starting the containers

### Challenge Management Tool

#### 1. Dependency Check
- Verify Docker and daemon availability
- Check for required system tools
- Automatically install CTFcli via pipx if necessary

#### 2. Challenge Discovery
- Analyze the challenge repository structure
- Identify Docker and static challenges

#### 3. Docker Image Building
- Sequential or parallel image building
- Support for `--force` mode for complete rebuild
- Error handling with detailed reports

#### 4. Challenge Ingestion
- Installation via CTFcli into the CTFd instance

#### 5. Synchronization
- Update existing challenges
- Option to backup before synchronization
- Support for `--force` mode for overwriting

#### 6. Cleanup
- Remove Docker images associated with challenges
- Dry-run mode available

## Challenge Structure

### Expected Challenge Repository

```
repo-challenges/
├── challenges/                    # (optional, detected automatically)
│   ├── web/
│   │   ├── challenge-1/
│   │   │   ├── challenge.yml      # Challenge configuration
│   │   │   ├── Dockerfile         # Docker image (for type: docker)
│   │   │   ├── src/               # Source code
│   │   │   └── files/             # Challenge files
│   │   └── challenge-2/
│   ├── crypto/
│   └── pwn/
```

> [!WARNING]
> The challenge ingestion script works in alphabetical order of categories and challenges. If a challenge has prerequisites, it is necessary to ingest the prerequisites beforehand.

### Format of the `challenge.yml` File

```yaml
name: "MyChallenge"
author: Challenge_Author
category: AI

description: |-
  ## Description (French)

  Petite description en français

  ## Description (English)

  Short description in English

flags:
  - polycyber{flag_to_find}

tags:
  - AI
  - A:Challenge_Author

requirements:
  - "Rules"

# If files needed
files:
  - "files/hello_world.txt"

# If hints needed, choose the cost
hints:
  - Interesting hint

value: 500
type: docker                          # or type: dynamic
extra:
  docker_image: "mychallenge:latest"  # required for type: docker
  dynamic: True                       # required for type: docker
  initial: 500
  decay: 10
  minimum: 50
```

## Generated Configuration

### TLS Certificates

Certificates are created in `${WORKING_DIR}/cert/`:

- `ca-cert.pem` - Certificate Authority certificate
- `ca-key.pem` - Certificate Authority private key
- `server-cert.pem` - Docker server certificate
- `server-key.pem` - Docker server private key
- `client-cert.pem` - Client certificate
- `client-key.pem` - Client private key
- `cert.zip` - Archive containing the necessary certificates

### Docker Configuration

The script configures Docker to listen on:
- `172.17.0.1:2376` (TLS secured)
- Default Unix socket (`fd://`)

### Generated Secrets

The script automatically generates:
- **CTFd secret key** (32 characters)
- **Database password** (16 characters)
- **Database root password** (16 characters)
- **CA password** (32 characters)

These scripts are developed by the PolyCyber team for the automated installation and management of CTFd servers.