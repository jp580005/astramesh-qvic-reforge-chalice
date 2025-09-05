#!/bin/bash
# AstraMesh QVic Self-Update Script
# This script handles automatic updates and self-healing

set -euo pipefail

# Configuration
INSTALL_DIR="/opt/astramesh"
SERVICE_NAME="astramesh"
BACKUP_DIR="/opt/astramesh/backups"
LOG_FILE="/opt/astramesh/logs/self_update.log"
GITHUB_REPO="jp580005/astramesh-qvic"
CURRENT_VERSION_FILE="/opt/astramesh/.version"

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Error handling
error_exit() {
    log "ERROR: $1"
    exit 1
}

# Check if running as root
check_root() {
    if [[ $EUID -eq 0 ]]; then
        error_exit "This script should not be run as root"
    fi
}

# Create necessary directories
setup_directories() {
    mkdir -p "$BACKUP_DIR" "$INSTALL_DIR/logs"
}

# Get current version
get_current_version() {
    if [[ -f "$CURRENT_VERSION_FILE" ]]; then
        cat "$CURRENT_VERSION_FILE"
    else
        echo "unknown"
    fi
}

# Get latest version from GitHub
get_latest_version() {
    curl -s "https://api.github.com/repos/$GITHUB_REPO/releases/latest" | \
        grep '"tag_name":' | \
        sed -E 's/.*"([^"]+)".*/\1/'
}

# Download and extract update
download_update() {
    local version=$1
    local temp_dir=$(mktemp -d)
    local archive_url="https://github.com/$GITHUB_REPO/archive/refs/tags/$version.tar.gz"
    
    log "Downloading version $version from $archive_url"
    
    cd "$temp_dir"
    curl -L "$archive_url" -o "astramesh-$version.tar.gz" || error_exit "Failed to download update"
    
    tar -xzf "astramesh-$version.tar.gz" || error_exit "Failed to extract update"
    
    echo "$temp_dir/astramesh-qvic-${version#v}"
}

# Create backup
create_backup() {
    local backup_name="backup-$(date +%Y%m%d-%H%M%S)"
    local backup_path="$BACKUP_DIR/$backup_name"
    
    log "Creating backup at $backup_path"
    
    cp -r "$INSTALL_DIR" "$backup_path" || error_exit "Failed to create backup"
    
    # Keep only last 5 backups
    cd "$BACKUP_DIR"
    ls -t | tail -n +6 | xargs -r rm -rf
    
    echo "$backup_path"
}

# Update application
update_application() {
    local source_dir=$1
    local version=$2
    
    log "Updating application from $source_dir"
    
    # Stop service
    sudo systemctl stop "$SERVICE_NAME" || log "Warning: Failed to stop service"
    
    # Update files
    cp -r "$source_dir"/* "$INSTALL_DIR/" || error_exit "Failed to copy new files"
    
    # Update version file
    echo "$version" > "$CURRENT_VERSION_FILE"
    
    # Update dependencies
    cd "$INSTALL_DIR"
    if [[ -f "backend/requirements.txt" ]]; then
        "$INSTALL_DIR/venv/bin/pip" install -r backend/requirements.txt || error_exit "Failed to update dependencies"
    fi
    
    # Fix permissions
    sudo chown -R astramesh:astramesh "$INSTALL_DIR"
    chmod +x "$INSTALL_DIR/infra/selfheal/"*.sh
    
    # Start service
    sudo systemctl start "$SERVICE_NAME" || error_exit "Failed to start service"
    
    log "Application updated successfully to version $version"
}

# Rollback to backup
rollback() {
    local backup_path=$1
    
    log "Rolling back to backup: $backup_path"
    
    sudo systemctl stop "$SERVICE_NAME"
    
    rm -rf "$INSTALL_DIR"
    cp -r "$backup_path" "$INSTALL_DIR"
    
    sudo systemctl start "$SERVICE_NAME"
    
    log "Rollback completed"
}

# Health check after update
health_check() {
    local max_attempts=30
    local attempt=1
    
    log "Performing health check..."
    
    while [[ $attempt -le $max_attempts ]]; do
        if curl -f http://localhost:8000/health >/dev/null 2>&1; then
            log "Health check passed"
            return 0
        fi
        
        log "Health check attempt $attempt/$max_attempts failed, waiting..."
        sleep 10
        ((attempt++))
    done
    
    error_exit "Health check failed after $max_attempts attempts"
}

# Main update process
main() {
    log "Starting self-update process"
    
    check_root
    setup_directories
    
    local current_version=$(get_current_version)
    local latest_version=$(get_latest_version)
    
    log "Current version: $current_version"
    log "Latest version: $latest_version"
    
    if [[ "$current_version" == "$latest_version" ]]; then
        log "Already up to date"
        exit 0
    fi
    
    # Create backup before update
    local backup_path=$(create_backup)
    
    # Download and extract update
    local source_dir=$(download_update "$latest_version")
    
    # Perform update
    if update_application "$source_dir" "$latest_version"; then
        # Verify update with health check
        if health_check; then
            log "Update completed successfully"
            rm -rf "$source_dir"
        else
            log "Health check failed, rolling back"
            rollback "$backup_path"
            error_exit "Update failed, rolled back to previous version"
        fi
    else
        log "Update failed, rolling back"
        rollback "$backup_path"
        error_exit "Update failed, rolled back to previous version"
    fi
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi