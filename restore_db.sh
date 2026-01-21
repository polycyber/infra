#!/bin/bash

# CTFd Restore Script
# Restores MariaDB database and CTFd uploads from backup

# Configuration - MODIFY THESE PATHS (should match backup script)
BASE_PATH="/home/${SUDO_USER:-$USER}"
DOCKER_COMPOSE_PATH="$BASE_PATH/infra/docker-compose.yml"
BACKUP_BASE_DIR="$BASE_PATH/backups"
CTFD_UPLOADS_PATH="$BASE_PATH/data/CTFd/uploads"

# Script variables
LOG_FILE="${BACKUP_BASE_DIR}/restore.log"
CONTAINER_NAME="maria-db"
RESTORE_TEMP_DIR="${BACKUP_BASE_DIR}/restore_temp"

# Function to log messages
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "${LOG_FILE}"
}

ensure_root() {
    if [[ $EUID -ne 0 ]]; then
        log_message "This script must be run as root. Re-executing with sudo..."
        exec sudo bash "$0" "$@"
    fi
    log_message "Running script as root..."
}

# Function to extract value from docker-compose file
extract_compose_value() {
    local key=$1
    awk '/maria-db:/,/^[a-z]/ {print}' "${DOCKER_COMPOSE_PATH}" | \
        grep "${key}" | \
        sed 's/.*- //' | \
        sed 's/.*=//' | \
        tr -d ' \r'
}

# Function to extract credentials from backup file
extract_backup_credential() {
    local cred_file=$1
    local key=$2
    grep "^${key}:" "${cred_file}" | sed 's/.*: //' | tr -d '\r\n'
}

# Function to cleanup temp directory
cleanup() {
    if [ -d "${RESTORE_TEMP_DIR}" ]; then
        log_message "Cleaning up temporary files..."
        rm -rf "${RESTORE_TEMP_DIR}"
    fi
}

# Set trap to cleanup on exit
trap cleanup EXIT

# Display usage
usage() {
    echo "Usage: $0 <backup_file>"
    echo "Example: $0 ${BACKUP_BASE_DIR}/ctfd_backup_20240101_120000.tar.gz"
    echo "Or use 'latest' to restore the most recent backup:"
    echo "Example: $0 latest"
    exit 1
}

# Check if backup file argument is provided
if [ $# -eq 0 ]; then
    usage
fi

BACKUP_FILE="$1"

# Handle 'latest' keyword
if [ "$BACKUP_FILE" = "latest" ]; then
    if [ -L "${BACKUP_BASE_DIR}/latest_backup.tar.gz" ]; then
        BACKUP_FILE="${BACKUP_BASE_DIR}/latest_backup.tar.gz"
        log_message "Using latest backup: $(readlink -f ${BACKUP_FILE})"
    else
        log_message "ERROR: No latest backup symlink found"
        exit 1
    fi
fi

# Verify backup file exists
if [ ! -f "${BACKUP_FILE}" ]; then
    log_message "ERROR: Backup file not found: ${BACKUP_FILE}"
    exit 1
fi

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    ensure_root "$@"
fi

log_message "========== Starting CTFd Restore =========="
log_message "Backup file: ${BACKUP_FILE}"

# Warning prompt
echo ""
echo "WARNING: This will REPLACE all current CTFd data with the backup!"
echo "  - Database will be dropped and restored"
echo "  - Uploads directory will be replaced"
echo ""
read -p "Are you sure you want to continue? (yes/no): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    log_message "Restore cancelled by user"
    exit 0
fi

# Create temporary restore directory
log_message "Extracting backup archive..."
mkdir -p "${RESTORE_TEMP_DIR}"
if ! tar -xzf "${BACKUP_FILE}" -C "${RESTORE_TEMP_DIR}"; then
    log_message "ERROR: Failed to extract backup archive"
    exit 1
fi

# Find the extracted backup directory
BACKUP_DIR=$(find "${RESTORE_TEMP_DIR}" -maxdepth 1 -type d -name "ctfd_backup_*" | head -n 1)

if [ -z "${BACKUP_DIR}" ]; then
    log_message "ERROR: Could not find backup directory in extracted archive"
    exit 1
fi

log_message "SUCCESS: Backup extracted to temporary directory"

# Extract database credentials - Try backup first, then docker-compose
log_message "Extracting database credentials..."

DB_ROOT_PASSWORD=""
DB_NAME=""

# Fallback to docker-compose if backup credentials not found or invalid
if [ -z "$DB_ROOT_PASSWORD" ] || [ -z "$DB_NAME" ]; then
    log_message "  Extracting credentials from docker-compose file..."
    DB_ROOT_PASSWORD=$(extract_compose_value "MARIADB_ROOT_PASSWORD")
    DB_NAME=$(extract_compose_value "MARIADB_DATABASE")
    
    if [ -n "$DB_ROOT_PASSWORD" ] && [ -n "$DB_NAME" ]; then
        log_message "  Using credentials from docker-compose.yml"
    else
        log_message "ERROR: Failed to extract database credentials or docker-compose"
        exit 1
    fi
fi

# Verify credentials are valid
if [ -z "$DB_ROOT_PASSWORD" ] || [ -z "$DB_NAME" ]; then
    log_message "ERROR: Database credentials are empty"
    exit 1
fi

log_message "SUCCESS: Credentials obtained from docker-compose"

# Check if container is running
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    log_message "ERROR: Container ${CONTAINER_NAME} is not running"
    log_message "Please start your CTFd stack first: docker compose -f ${DOCKER_COMPOSE_PATH} up -d"
    exit 1
fi

# 1. Restore MariaDB Database
log_message "Step 1/2: Restoring MariaDB database..."

if [ ! -f "${BACKUP_DIR}/database.sql.gz" ]; then
    log_message "ERROR: Database backup file not found in archive"
    exit 1
fi

# Verify database connection
log_message "  Verifying database connection..."
if ! docker exec "${CONTAINER_NAME}" mysql -u root -p"${DB_ROOT_PASSWORD}" -e "SELECT 1;" &> /dev/null; then
    log_message "ERROR: Cannot connect to database. Password may be incorrect."
    exit 1
fi

# Drop existing database and recreate
log_message "  Dropping existing database..."
if ! docker exec "${CONTAINER_NAME}" mysql -u root -p"${DB_ROOT_PASSWORD}" \
    -e "DROP DATABASE IF EXISTS ${DB_NAME}; CREATE DATABASE ${DB_NAME};" 2>/dev/null; then
    log_message "ERROR: Failed to drop/create database"
    exit 1
fi

# Restore database
log_message "  Restoring database from backup..."
if gunzip < "${BACKUP_DIR}/database.sql.gz" | \
    docker exec -i "${CONTAINER_NAME}" mysql -u root -p"${DB_ROOT_PASSWORD}" "${DB_NAME}" 2>/dev/null; then
    log_message "SUCCESS: Database restored successfully"
else
    log_message "ERROR: Database restore failed"
    exit 1
fi

# 2. Restore CTFd uploads
log_message "Step 2/2: Restoring CTFd uploads..."

if [ -f "${BACKUP_DIR}/no_uploads.txt" ]; then
    log_message "INFO: Backup contained no uploads, skipping"
elif [ -f "${BACKUP_DIR}/ctfd_uploads.tar.gz" ]; then
    # Backup existing uploads if they exist
    if [ -d "${CTFD_UPLOADS_PATH}" ] && [ "$(ls -A ${CTFD_UPLOADS_PATH} 2>/dev/null)" ]; then
        UPLOADS_BACKUP="${CTFD_UPLOADS_PATH}_backup_$(date +%Y%m%d_%H%M%S)"
        log_message "  Backing up existing uploads to: ${UPLOADS_BACKUP}"
        mv "${CTFD_UPLOADS_PATH}" "${UPLOADS_BACKUP}"
    else
        # Remove empty directory if it exists
        rm -rf "${CTFD_UPLOADS_PATH}" 2>/dev/null
    fi
    
    # Extract uploads
    log_message "  Extracting uploads..."
    mkdir -p "$(dirname ${CTFD_UPLOADS_PATH})"
    if tar --same-owner -xzf "${BACKUP_DIR}/ctfd_uploads.tar.gz" -C "$(dirname ${CTFD_UPLOADS_PATH})"; then
        # Set appropriate permissions
        chmod -R 755 "${CTFD_UPLOADS_PATH}"
        UPLOAD_COUNT=$(find "${CTFD_UPLOADS_PATH}" -type f 2>/dev/null | wc -l)
        log_message "SUCCESS: CTFd uploads restored (${UPLOAD_COUNT} files)"
    else
        log_message "ERROR: Failed to extract uploads"
        exit 1
    fi
else
    log_message "WARNING: No uploads found in backup"
fi

log_message "========== CTFd Restore Completed Successfully =========="
log_message "Please restart CTFd to apply changes:"
log_message "  docker compose -f ${DOCKER_COMPOSE_PATH} restart"

exit 0