#!/bin/bash

# CTFd Essential Backup Script
# Backs up MariaDB database and CTFd uploads (everything needed for complete restoration)

# Configuration - MODIFY THESE PATHS
BASE_PATH="/home/${SUDO_USER:-$USER}"
DOCKER_COMPOSE_PATH="$BASE_PATH/infra/docker-compose.yml"
BACKUP_BASE_DIR="$BASE_PATH/backups"
CTFD_UPLOADS_PATH="$BASE_PATH/data/CTFd/uploads"

# Backup retention (number of backups to keep)
MAX_BACKUPS=5

# Script variables
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_DIR="${BACKUP_BASE_DIR}/ctfd_backup_${TIMESTAMP}"
LOG_FILE="${BACKUP_BASE_DIR}/backup.log"
CONTAINER_NAME="maria-db"

# Create backup directory
mkdir -p "${BACKUP_DIR}"

# Function to log messages
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "${LOG_FILE}"
}

# Function to extract value from docker-compose file
extract_compose_value() {
    local key=$1
    # Extract the maria-db service block and find the value
    awk '/maria-db:/,/^[a-z]/ {print}' "${DOCKER_COMPOSE_PATH}" | \
        grep "${key}" | \
        sed 's/.*- //' | \
        sed 's/.*=//' | \
        tr -d ' \r'
}

log_message "========== Starting CTFd Backup =========="

# Extract database credentials
log_message "Extracting database credentials..."
DB_ROOT_PASSWORD=$(extract_compose_value "MARIADB_ROOT_PASSWORD")
DB_NAME=$(extract_compose_value "MARIADB_DATABASE")

if [ -z "$DB_ROOT_PASSWORD" ] || [ -z "$DB_NAME" ]; then
    log_message "ERROR: Failed to extract database credentials from docker-compose file"
    exit 1
fi

# Check if container is running
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    log_message "ERROR: Container ${CONTAINER_NAME} is not running"
    exit 1
fi

# 1. Backup MariaDB Database (contains all CTFd data)
log_message "Step 1/2: Backing up MariaDB database..."
log_message "  Database contains: users, teams, challenges, submissions, solves, scores, flags, hints, settings, etc."
if docker exec "${CONTAINER_NAME}" mysqldump -u root -p"${DB_ROOT_PASSWORD}" \
    --single-transaction --quick --lock-tables=false "${DB_NAME}" | \
    gzip > "${BACKUP_DIR}/database.sql.gz"; then
    
    DB_SIZE=$(du -h "${BACKUP_DIR}/database.sql.gz" | cut -f1)
    log_message "SUCCESS: Database backup completed (${DB_SIZE})"
else
    log_message "ERROR: Database backup failed"
    exit 1
fi

# Verify database backup
if [ ! -s "${BACKUP_DIR}/database.sql.gz" ]; then
    log_message "ERROR: Database backup file is empty or missing"
    exit 1
fi

# 2. Backup CTFd uploads (challenge files, user uploads)
log_message "Step 2/2: Backing up CTFd uploads..."
if [ -d "${CTFD_UPLOADS_PATH}" ]; then
    # Check if directory has content
    if [ "$(ls -A ${CTFD_UPLOADS_PATH})" ]; then
        tar -czf "${BACKUP_DIR}/ctfd_uploads.tar.gz" -C "$(dirname ${CTFD_UPLOADS_PATH})" "$(basename ${CTFD_UPLOADS_PATH})"
        UPLOAD_SIZE=$(du -h "${BACKUP_DIR}/ctfd_uploads.tar.gz" | cut -f1)
        log_message "SUCCESS: CTFd uploads backed up (${UPLOAD_SIZE})"
    else
        log_message "INFO: Uploads directory is empty, skipping"
        touch "${BACKUP_DIR}/no_uploads.txt"
    fi
else
    log_message "WARNING: CTFd uploads directory not found at ${CTFD_UPLOADS_PATH}"
    log_message "  If you have challenge files or user uploads, verify the path is correct"
fi

# Calculate total backup size
TOTAL_SIZE=$(du -sh "${BACKUP_DIR}" | cut -f1)
log_message "Total backup size: ${TOTAL_SIZE}"

# Create a compressed archive of the entire backup
log_message "Creating compressed backup archive..."
tar -czf "${BACKUP_BASE_DIR}/ctfd_backup_${TIMESTAMP}.tar.gz" -C "${BACKUP_BASE_DIR}" "ctfd_backup_${TIMESTAMP}"
ARCHIVE_SIZE=$(du -h "${BACKUP_BASE_DIR}/ctfd_backup_${TIMESTAMP}.tar.gz" | cut -f1)
log_message "SUCCESS: Complete backup archive created (${ARCHIVE_SIZE})"

# Remove uncompressed backup directory
rm -rf "${BACKUP_DIR}"

# Create symlink to latest backup
ln -sf "${BACKUP_BASE_DIR}/ctfd_backup_${TIMESTAMP}.tar.gz" "${BACKUP_BASE_DIR}/latest_backup.tar.gz"

# Clean up old backups
log_message "Cleaning up old backups, keeping only the ${MAX_BACKUPS} most recent..."
BACKUP_FILES=$(find "${BACKUP_BASE_DIR}" -name "ctfd_backup_*.tar.gz" -type f | sort -r)
BACKUP_COUNT=$(echo "$BACKUP_FILES" | wc -l)

if [ $BACKUP_COUNT -gt $MAX_BACKUPS ]; then
    echo "$BACKUP_FILES" | tail -n +$((MAX_BACKUPS + 1)) | xargs rm -f
    log_message "Deleted $((BACKUP_COUNT - MAX_BACKUPS)) old backup(s)"
fi

REMAINING_COUNT=$(find "${BACKUP_BASE_DIR}" -name "ctfd_backup_*.tar.gz" -type f | wc -l)
log_message "Retained ${REMAINING_COUNT} backup(s)"
exit 0