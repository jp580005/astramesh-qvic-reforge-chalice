#!/bin/bash
# AstraMesh QVic Reforge Chalice - Self-Installing Bootstrap Script
# This script sets up the complete environment for the AI-powered knowledge aggregator

set -euo pipefail

# Configuration
INSTALL_DIR="/opt/astramesh"
SERVICE_USER="astramesh"
SERVICE_NAME="astramesh"
PYTHON_VERSION="3.11"
GITHUB_REPO="jp580005/astramesh-qvic"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

# Error handling
error_exit() {
    error "$1"
    exit 1
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error_exit "This script must be run as root (use sudo)"
    fi
}

# Detect OS
detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
    else
        error_exit "Cannot detect operating system"
    fi
    
    log "Detected OS: $OS $VERSION"
}

# Install system dependencies
install_system_deps() {
    log "Installing system dependencies..."
    
    case $OS in
        ubuntu|debian)
            apt-get update
            apt-get install -y \
                python3 python3-pip python3-venv python3-dev \
                curl wget git \
                build-essential \
                nginx \
                systemd \
                bc \
                ca-certificates \
                gnupg \
                lsb-release
            ;;
        centos|rhel|fedora)
            if command -v dnf >/dev/null; then
                dnf install -y \
                    python3 python3-pip python3-devel \
                    curl wget git \
                    gcc gcc-c++ make \
                    nginx \
                    systemd \
                    bc \
                    ca-certificates
            else
                yum install -y \
                    python3 python3-pip python3-devel \
                    curl wget git \
                    gcc gcc-c++ make \
                    nginx \
                    systemd \
                    bc \
                    ca-certificates
            fi
            ;;
        *)
            error_exit "Unsupported operating system: $OS"
            ;;
    esac
}

# Create service user
create_user() {
    if ! id "$SERVICE_USER" &>/dev/null; then
        log "Creating service user: $SERVICE_USER"
        useradd -r -s /bin/bash -d "$INSTALL_DIR" -m "$SERVICE_USER"
    else
        log "Service user $SERVICE_USER already exists"
    fi
}

# Setup directories
setup_directories() {
    log "Setting up directories..."
    
    mkdir -p "$INSTALL_DIR"/{backend,frontend,logs,backups,.configs}
    chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"
    chmod 755 "$INSTALL_DIR"
}

# Download and install application
install_application() {
    log "Downloading and installing AstraMesh QVic..."
    
    local temp_dir=$(mktemp -d)
    cd "$temp_dir"
    
    # Download latest release or clone repository
    if curl -s "https://api.github.com/repos/$GITHUB_REPO/releases/latest" | grep -q "tag_name"; then
        local latest_version=$(curl -s "https://api.github.com/repos/$GITHUB_REPO/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        log "Downloading latest release: $latest_version"
        curl -L "https://github.com/$GITHUB_REPO/archive/refs/tags/$latest_version.tar.gz" -o astramesh.tar.gz
        tar -xzf astramesh.tar.gz --strip-components=1
    else
        log "Cloning repository..."
        git clone "https://github.com/$GITHUB_REPO.git" .
    fi
    
    # Copy files to install directory
    cp -r * "$INSTALL_DIR/"
    
    # Set permissions
    chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"
    chmod +x "$INSTALL_DIR/infra/selfheal/"*.sh
    
    # Create version file
    if [[ -n "${latest_version:-}" ]]; then
        echo "$latest_version" > "$INSTALL_DIR/.version"
    else
        echo "dev-$(date +%Y%m%d)" > "$INSTALL_DIR/.version"
    fi
    
    rm -rf "$temp_dir"
}

# Setup Python virtual environment
setup_python_env() {
    log "Setting up Python virtual environment..."
    
    cd "$INSTALL_DIR"
    
    # Create virtual environment
    sudo -u "$SERVICE_USER" python3 -m venv venv
    
    # Upgrade pip
    sudo -u "$SERVICE_USER" ./venv/bin/pip install --upgrade pip
    
    # Install requirements
    if [[ -f "backend/requirements.txt" ]]; then
        sudo -u "$SERVICE_USER" ./venv/bin/pip install -r backend/requirements.txt
    fi
}

# Setup configuration
setup_configuration() {
    log "Setting up configuration..."
    
    # Copy example configuration if .env doesn't exist
    if [[ ! -f "$INSTALL_DIR/.env" ]] && [[ -f "$INSTALL_DIR/.configs/.env.example" ]]; then
        cp "$INSTALL_DIR/.configs/.env.example" "$INSTALL_DIR/.env"
        chown "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR/.env"
        chmod 600 "$INSTALL_DIR/.env"
        
        warn "Configuration file created at $INSTALL_DIR/.env"
        warn "Please edit this file with your API keys before starting the service"
    fi
}

# Install systemd service
install_systemd_service() {
    log "Installing systemd service..."
    
    if [[ -f "$INSTALL_DIR/infra/selfheal/astramesh.service" ]]; then
        cp "$INSTALL_DIR/infra/selfheal/astramesh.service" /etc/systemd/system/
        systemctl daemon-reload
        systemctl enable "$SERVICE_NAME"
        log "Systemd service installed and enabled"
    else
        warn "Systemd service file not found, skipping service installation"
    fi
}

# Setup cron jobs for self-healing
setup_cron_jobs() {
    log "Setting up cron jobs for self-healing..."
    
    # Health check every 5 minutes
    local cron_job="*/5 * * * * $INSTALL_DIR/infra/selfheal/run_healthcheck.sh >/dev/null 2>&1"
    
    # Add cron job for service user
    (sudo -u "$SERVICE_USER" crontab -l 2>/dev/null || true; echo "$cron_job") | sudo -u "$SERVICE_USER" crontab -
    
    # Self-update check daily at 2 AM
    local update_job="0 2 * * * $INSTALL_DIR/infra/selfheal/self_update.sh >/dev/null 2>&1"
    (sudo -u "$SERVICE_USER" crontab -l 2>/dev/null || true; echo "$update_job") | sudo -u "$SERVICE_USER" crontab -
    
    log "Cron jobs configured for automated health checks and updates"
}

# Setup firewall (if available)
setup_firewall() {
    if command -v ufw >/dev/null; then
        log "Configuring UFW firewall..."
        ufw allow 8000/tcp comment "AstraMesh QVic"
        ufw allow 80/tcp comment "HTTP"
        ufw allow 443/tcp comment "HTTPS"
    elif command -v firewall-cmd >/dev/null; then
        log "Configuring firewalld..."
        firewall-cmd --permanent --add-port=8000/tcp
        firewall-cmd --permanent --add-port=80/tcp
        firewall-cmd --permanent --add-port=443/tcp
        firewall-cmd --reload
    else
        warn "No firewall detected, please configure manually if needed"
    fi
}

# Run tests
run_tests() {
    log "Running basic tests..."
    
    cd "$INSTALL_DIR"
    if sudo -u "$SERVICE_USER" ./venv/bin/python -m pytest backend/tests/ -v; then
        log "Tests passed successfully"
    else
        warn "Some tests failed, but installation will continue"
    fi
}

# Start services
start_services() {
    log "Starting services..."
    
    if systemctl is-enabled "$SERVICE_NAME" >/dev/null 2>&1; then
        systemctl start "$SERVICE_NAME"
        
        # Wait for service to start
        sleep 10
        
        # Check if service is running
        if systemctl is-active --quiet "$SERVICE_NAME"; then
            log "Service started successfully"
            
            # Test health endpoint
            if curl -f http://localhost:8000/health >/dev/null 2>&1; then
                log "Health check passed"
            else
                warn "Health check failed, service may need configuration"
            fi
        else
            warn "Service failed to start, check logs with: journalctl -u $SERVICE_NAME"
        fi
    else
        warn "Service not enabled, start manually with: systemctl start $SERVICE_NAME"
    fi
}

# Display installation summary
display_summary() {
    info "=============================================="
    info "AstraMesh QVic Reforge Chalice Installation Complete!"
    info "=============================================="
    info ""
    info "Installation Directory: $INSTALL_DIR"
    info "Service User: $SERVICE_USER"
    info "Service Name: $SERVICE_NAME"
    info ""
    info "Configuration:"
    info "  - Edit API keys in: $INSTALL_DIR/.env"
    info "  - View logs: journalctl -u $SERVICE_NAME -f"
    info "  - Service status: systemctl status $SERVICE_NAME"
    info ""
    info "Web Interface:"
    info "  - Local: http://localhost:8000"
    info "  - Health: http://localhost:8000/health"
    info "  - API Docs: http://localhost:8000/docs"
    info ""
    info "Management Commands:"
    info "  - Start: systemctl start $SERVICE_NAME"
    info "  - Stop: systemctl stop $SERVICE_NAME"
    info "  - Restart: systemctl restart $SERVICE_NAME"
    info "  - Status: systemctl status $SERVICE_NAME"
    info ""
    info "Self-Healing Features:"
    info "  - Automatic health checks every 5 minutes"
    info "  - Automatic updates daily at 2 AM"
    info "  - Manual update: $INSTALL_DIR/infra/selfheal/self_update.sh"
    info "  - Manual health check: $INSTALL_DIR/infra/selfheal/run_healthcheck.sh"
    info ""
    warn "IMPORTANT: Configure your API keys in $INSTALL_DIR/.env before using!"
    info "=============================================="
}

# Main installation process
main() {
    info "Starting AstraMesh QVic Reforge Chalice installation..."
    
    check_root
    detect_os
    install_system_deps
    create_user
    setup_directories
    install_application
    setup_python_env
    setup_configuration
    install_systemd_service
    setup_cron_jobs
    setup_firewall
    run_tests
    start_services
    display_summary
    
    log "Installation completed successfully!"
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi