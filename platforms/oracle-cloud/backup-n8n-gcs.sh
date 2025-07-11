#!/bin/bash

# remember to make the script excusable 
# chmod +x ~/backup-n8n-gcs.sh

# --- Cron job
# crontab -e
# add a new line to schedule your backup. For example, to run daily at 2:00 AM Toronto time:
# m h dom mon dow command
# 0 2 * * * /home/ubuntu/backup-n8n-gcs.sh >> /var/log/n8n_backup.log 2>&1

# --- Configuration ---
N8N_DIR="/home/ubuntu/n8n" # Path to your n8n Docker Compose directory
BACKUP_DIR="${N8N_DIR}/backups" # Directory to store local backups temporarily
GCS_BUCKET="gs://n8n-backups-dalenguyen-prod" # CHANGE THIS to your GCS bucket name (e.g., gs://my-n8n-backups)
BACKUP_PREFIX="n8n_backup" # Prefix for your backup files
RETENTION_DAYS_LOCAL=7    # How many days to keep local backups
RETENTION_DAYS_GCS=30     # How many days to keep backups in GCS

# --- Pre-checks ---
echo "Checking environment..."
echo "Current PATH: $PATH"
echo "Current shell: $SHELL"
echo "Script interpreter: $0"

# Function to find Docker (sh-compatible)
find_docker() {
    # Try common Docker locations
    if [ -x "/usr/bin/docker" ]; then
        echo "/usr/bin/docker"
        return 0
    fi
    
    if [ -x "/usr/local/bin/docker" ]; then
        echo "/usr/local/bin/docker"
        return 0
    fi
    
    if [ -x "/opt/homebrew/bin/docker" ]; then
        echo "/opt/homebrew/bin/docker"
        return 0
    fi
    
    # Try which command if available
    if command -v which >/dev/null 2>&1; then
        DOCKER_PATH=$(which docker 2>/dev/null)
        if [ -n "$DOCKER_PATH" ] && [ -x "$DOCKER_PATH" ]; then
            echo "$DOCKER_PATH"
            return 0
        fi
    fi
    
    return 1
}

# Find Docker
DOCKER_CMD=$(find_docker)
if [ -z "$DOCKER_CMD" ]; then
    echo "Error: Docker is not installed or not accessible."
    echo "Tried to find Docker in: /usr/bin/docker, /usr/local/bin/docker, /opt/homebrew/bin/docker, and PATH"
    echo "Please ensure Docker is installed and accessible."
    exit 1
else
    echo "Found Docker at: $DOCKER_CMD"
fi

# Function to find gsutil (sh-compatible)
find_gsutil() {
    # Try common gsutil locations
    if [ -x "/usr/bin/gsutil" ]; then
        echo "/usr/bin/gsutil"
        return 0
    fi
    
    if [ -x "/usr/local/bin/gsutil" ]; then
        echo "/usr/local/bin/gsutil"
        return 0
    fi
    
    if [ -x "/opt/homebrew/bin/gsutil" ]; then
        echo "/opt/homebrew/bin/gsutil"
        return 0
    fi
    
    # Try which command if available
    if command -v which >/dev/null 2>&1; then
        GSUTIL_PATH=$(which gsutil 2>/dev/null)
        if [ -n "$GSUTIL_PATH" ] && [ -x "$GSUTIL_PATH" ]; then
            echo "$GSUTIL_PATH"
            return 0
        fi
    fi
    
    return 1
}

# Find gsutil
GSUTIL_CMD=$(find_gsutil)
if [ -z "$GSUTIL_CMD" ]; then
    echo "Error: gsutil (Google Cloud SDK) is not installed or not accessible."
    echo "Tried to find gsutil in: /usr/bin/gsutil, /usr/local/bin/gsutil, /opt/homebrew/bin/gsutil, and PATH"
    echo "Current PATH: $PATH"
    echo "Please ensure gsutil is installed and accessible."
    exit 1
else
    echo "Found gsutil at: $GSUTIL_CMD"
fi

# Ensure backup directory exists
mkdir -p "$BACKUP_DIR"

# --- Generate Timestamp ---
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILENAME="${BACKUP_PREFIX}_${TIMESTAMP}.tar.gz"
BACKUP_PATH="${BACKUP_DIR}/${BACKUP_FILENAME}"

echo "--- Starting n8n backup at ${TIMESTAMP} ---"

# --- Stop n8n and DB containers ---
echo "Stopping n8n and database containers..."
cd "$N8N_DIR" || { echo "Error: Could not change to n8n directory."; exit 1; }
"$DOCKER_CMD" compose stop || { echo "Error: Failed to stop Docker Compose services."; exit 1; }
echo "Containers stopped."

# --- Create Backup ---
echo "Creating backup archive: ${BACKUP_FILENAME}..."
# Use Docker to create backup to avoid permission issues with pg_data
# This runs tar inside a container with access to the volumes
cd "$N8N_DIR" || { echo "Error: Could not change to n8n directory."; exit 1; }

# Create backup using Docker to avoid permission issues
"$DOCKER_CMD" run --rm \
  -v "$(pwd)/n8n_data:/n8n_data:ro" \
  -v "$(pwd)/pg_data:/pg_data:ro" \
  -v "$(pwd)/backups:/backups" \
  alpine:latest \
  tar -czf "/backups/${BACKUP_FILENAME}" -C / n8n_data pg_data

if [ $? -eq 0 ]; then
    echo "Backup archive created: ${BACKUP_PATH}"
else
    echo "Error: Failed to create tar archive."
    "$DOCKER_CMD" compose start || { echo "Error: Failed to start Docker Compose services."; exit 1; }
    exit 1
fi

# --- Start n8n and DB containers ---
echo "Starting n8n and database containers..."
"$DOCKER_CMD" compose start || { echo "Error: Failed to start Docker Compose services."; exit 1; }
echo "Containers started."

# --- Upload to Google Cloud Storage ---
echo "Uploading ${BACKUP_FILENAME} to GCS bucket ${GCS_BUCKET}..."
"$GSUTIL_CMD" cp "$BACKUP_PATH" "${GCS_BUCKET}/${BACKUP_FILENAME}"
if [ $? -eq 0 ]; then
    echo "Backup uploaded successfully to GCS."
else
    echo "Error: Failed to upload backup to GCS."
    exit 1
fi

# --- Clean up old local backups ---
echo "Cleaning up local backups older than ${RETENTION_DAYS_LOCAL} days..."
find "$BACKUP_DIR" -type f -name "${BACKUP_PREFIX}_*.tar.gz" -mtime +"${RETENTION_DAYS_LOCAL}" -delete
echo "Local cleanup complete."

# --- Clean up old GCS backups ---
echo "Cleaning up GCS backups older than ${RETENTION_DAYS_GCS} days..."

# Get list of backups and process each one
"$GSUTIL_CMD" ls "${GCS_BUCKET}/${BACKUP_PREFIX}_*.tar.gz" 2>/dev/null | while read -r backup; do
    if [ -n "$backup" ]; then
        filename=$(basename "$backup")
        
        # Extract date from filename (format: n8n_backup_YYYYMMDD_HHMMSS.tar.gz)
        # Use sed to extract YYYYMMDD part
        date_part=$(echo "$filename" | sed 's/n8n_backup_\([0-9]\{8\}\)_.*\.tar\.gz/\1/')
        
        # Check if date extraction was successful
        if [ "$date_part" = "$filename" ]; then
            echo "Warning: Could not parse date from filename: $filename"
            continue
        fi
        
        # Convert date to timestamp (sh-compatible)
        # Format: YYYYMMDD to YYYY-MM-DD
        year=$(echo "$date_part" | cut -c1-4)
        month=$(echo "$date_part" | cut -c5-6)
        day=$(echo "$date_part" | cut -c7-8)
        formatted_date="${year}-${month}-${day}"
        
        # Get current date
        current_date=$(date +%Y-%m-%d)
        
        # Calculate days difference
        # Convert both dates to seconds since epoch
        backup_epoch=$(date -d "$formatted_date" +%s 2>/dev/null)
        current_epoch=$(date -d "$current_date" +%s 2>/dev/null)
        
        if [ -z "$backup_epoch" ] || [ -z "$current_epoch" ]; then
            echo "Warning: Could not calculate date for: $filename"
            continue
        fi
        
        # Calculate days difference
        days_old=$(( (current_epoch - backup_epoch) / 86400 ))
        
        # Check if backup is older than retention period
        if [ "$days_old" -gt "$RETENTION_DAYS_GCS" ]; then
            echo "Deleting old backup: $filename (${days_old} days old)"
            "$GSUTIL_CMD" rm "$backup"
        else
            echo "Keeping backup: $filename (${days_old} days old)"
        fi
    fi
done

echo "--- n8n backup process complete ---"