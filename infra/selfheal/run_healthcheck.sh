#!/bin/bash
# AstraMesh QVic Health Check and Self-Healing Script

set -euo pipefail

# Configuration
SERVICE_NAME="astramesh"
HEALTH_URL="http://localhost:8000/health"
LOG_FILE="/opt/astramesh/logs/healthcheck.log"
MAX_RESTART_ATTEMPTS=3
RESTART_DELAY=60
NOTIFICATION_WEBHOOK=""  # Optional webhook for notifications

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Send notification (if webhook configured)
send_notification() {
    local message=$1
    local level=${2:-"info"}
    
    if [[ -n "$NOTIFICATION_WEBHOOK" ]]; then
        curl -X POST "$NOTIFICATION_WEBHOOK" \
            -H "Content-Type: application/json" \
            -d "{\"text\":\"AstraMesh Health Check [$level]: $message\"}" \
            >/dev/null 2>&1 || true
    fi
}

# Check service status
check_service_status() {
    systemctl is-active --quiet "$SERVICE_NAME"
}

# Check HTTP health endpoint
check_http_health() {
    local response
    local http_code
    
    response=$(curl -s -w "%{http_code}" "$HEALTH_URL" --max-time 10 2>/dev/null || echo "000")
    http_code="${response: -3}"
    
    if [[ "$http_code" == "200" ]]; then
        return 0
    else
        log "HTTP health check failed with code: $http_code"
        return 1
    fi
}

# Check system resources
check_system_resources() {
    local cpu_usage
    local memory_usage
    local disk_usage
    
    # Check CPU usage (5-minute average)
    cpu_usage=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $2}' | sed 's/,//')
    if (( $(echo "$cpu_usage > 10.0" | bc -l) )); then
        log "WARNING: High CPU load: $cpu_usage"
        return 1
    fi
    
    # Check memory usage
    memory_usage=$(free | grep Mem | awk '{printf "%.1f", $3/$2 * 100.0}')
    if (( $(echo "$memory_usage > 90.0" | bc -l) )); then
        log "WARNING: High memory usage: ${memory_usage}%"
        return 1
    fi
    
    # Check disk usage
    disk_usage=$(df /opt/astramesh | tail -1 | awk '{print $5}' | sed 's/%//')
    if [[ $disk_usage -gt 90 ]]; then
        log "WARNING: High disk usage: ${disk_usage}%"
        return 1
    fi
    
    return 0
}

# Restart service
restart_service() {
    log "Attempting to restart $SERVICE_NAME service"
    
    if sudo systemctl restart "$SERVICE_NAME"; then
        log "Service restarted successfully"
        sleep 30  # Wait for service to fully start
        return 0
    else
        log "Failed to restart service"
        return 1
    fi
}

# Perform comprehensive health check
perform_health_check() {
    local issues=0
    
    # Check if service is running
    if ! check_service_status; then
        log "ERROR: Service $SERVICE_NAME is not running"
        ((issues++))
    fi
    
    # Check HTTP endpoint
    if ! check_http_health; then
        log "ERROR: HTTP health check failed"
        ((issues++))
    fi
    
    # Check system resources
    if ! check_system_resources; then
        log "WARNING: System resource check failed"
        # Don't increment issues for resource warnings
    fi
    
    return $issues
}

# Self-healing logic
self_heal() {
    local attempt=1
    
    while [[ $attempt -le $MAX_RESTART_ATTEMPTS ]]; do
        log "Self-healing attempt $attempt/$MAX_RESTART_ATTEMPTS"
        
        if restart_service; then
            sleep $RESTART_DELAY
            
            if perform_health_check; then
                log "Self-healing successful after $attempt attempts"
                send_notification "Self-healing successful after $attempt attempts" "success"
                return 0
            fi
        fi
        
        log "Self-healing attempt $attempt failed"
        ((attempt++))
        
        if [[ $attempt -le $MAX_RESTART_ATTEMPTS ]]; then
            log "Waiting ${RESTART_DELAY}s before next attempt"
            sleep $RESTART_DELAY
        fi
    done
    
    log "CRITICAL: Self-healing failed after $MAX_RESTART_ATTEMPTS attempts"
    send_notification "CRITICAL: Self-healing failed after $MAX_RESTART_ATTEMPTS attempts" "critical"
    return 1
}

# Cleanup old logs
cleanup_logs() {
    # Keep only last 7 days of logs
    find "/opt/astramesh/logs" -name "*.log" -type f -mtime +7 -delete 2>/dev/null || true
}

# Main health check routine
main() {
    log "Starting health check"
    
    # Cleanup old logs
    cleanup_logs
    
    # Perform health check
    if perform_health_check; then
        log "Health check passed - all systems operational"
        exit 0
    else
        log "Health check failed - initiating self-healing"
        send_notification "Health check failed - initiating self-healing" "warning"
        
        if self_heal; then
            log "System recovered successfully"
            exit 0
        else
            log "CRITICAL: System recovery failed - manual intervention required"
            exit 1
        fi
    fi
}

# Load configuration from environment file if it exists
if [[ -f "/opt/astramesh/.env" ]]; then
    source "/opt/astramesh/.env"
fi

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi