#!/bin/bash
#
# MobSF MCP Server - Unified Management Script
#
# Usage:
#   mobsf.sh --install   --docker|--podman   Install MobSF and MCP Server
#   mobsf.sh --uninstall --docker|--podman   [--mcp-only|--full] Uninstall
#   mobsf.sh --restart   --docker|--podman   Restart MCP Server
#   mobsf.sh --status    --docker|--podman   Show status of services
#   mobsf.sh --help                          Show this help message
#
# SELinux Note (RHEL/Fedora):
#   Volume mounts use :z suffix for SELinux compatibility (works on all systems).
#

set -e

# =============================================================================
# CONFIGURATION
# =============================================================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Container names
MOBSF_CONTAINER_NAME="mobsf"
MCP_CONTAINER_NAME="mobsf-mcp-server"

# Ports (can be overridden via environment variables)
MOBSF_PORT=${MOBSF_PORT:-9000}
MCP_PORT=${MCP_PORT:-7567}

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Container runtime (set by argument parsing)
CONTAINER_CMD=""
COMPOSE_CMD=""
RUNTIME_NAME=""

# =============================================================================
# LOGGING FUNCTIONS
# =============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

print_banner() {
    local color="$1"
    local title="$2"
    echo -e "${color}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║       🛡️  MobSF MCP Server - ${title}"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

check_command() {
    if ! command -v "$1" &> /dev/null; then
        return 1
    fi
    return 0
}

show_help() {
    echo "Usage: $0 <command> <runtime> [options]"
    echo ""
    echo "Commands:"
    echo "  --install     Install MobSF and MCP Server"
    echo "  --uninstall   Uninstall services"
    echo "  --restart     Restart MCP Server"
    echo "  --status      Show status of all services"
    echo "  --help        Show this help message"
    echo ""
    echo "Runtime (required for all commands except --help):"
    echo "  --docker      Use Docker as container runtime"
    echo "  --podman      Use Podman as container runtime"
    echo ""
    echo "Uninstall Options:"
    echo "  --mcp-only    Remove only the MCP server (keep MobSF)"
    echo "  --full        Remove everything including MobSF data"
    echo ""
    echo "Environment Variables:"
    echo "  MOBSF_PORT    MobSF web UI port (default: 9000)"
    echo "  MCP_PORT      MCP server port (default: 7567)"
    echo ""
    echo "Examples:"
    echo "  $0 --install --docker"
    echo "  $0 --install --podman"
    echo "  $0 --uninstall --podman --mcp-only"
    echo "  $0 --uninstall --docker --full"
    echo "  $0 --restart --docker"
    echo "  $0 --status --podman"
    echo ""
    echo "SELinux Note (RHEL/Fedora):"
    echo "  Volume mounts use :Z suffix for proper SELinux context labeling."
    echo ""
}

# =============================================================================
# CONTAINER RUNTIME SETUP
# =============================================================================

setup_container_runtime() {
    local runtime="$1"
    
    case "$runtime" in
        docker)
            CONTAINER_CMD="docker"
            RUNTIME_NAME="Docker"
            
            if ! check_command "docker"; then
                log_error "Docker is not installed. Please install Docker first."
                exit 1
            fi
            
            # Check if Docker daemon is running
            if ! docker info &> /dev/null; then
                log_error "Docker daemon is not running. Please start Docker first."
                exit 1
            fi
            
            # Detect docker-compose command
            if command -v docker-compose &> /dev/null; then
                COMPOSE_CMD="docker-compose"
            elif docker compose version &> /dev/null 2>&1; then
                COMPOSE_CMD="docker compose"
            else
                log_error "docker-compose is not installed. Please install it first."
                exit 1
            fi
            
            log_success "Docker is available (compose: $COMPOSE_CMD)"
            ;;
            
        podman)
            CONTAINER_CMD="podman"
            RUNTIME_NAME="Podman"
            
            if ! check_command "podman"; then
                log_error "Podman is not installed. Please install Podman first."
                exit 1
            fi
            
            # Check if Podman is working
            if ! podman info &> /dev/null; then
                log_error "Podman is not working properly. Please check your installation."
                exit 1
            fi
            
            # Check for rootless mode and warn about potential issues
            if podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null | grep -q "true"; then
                log_info "Running in Podman rootless mode"
            fi
            
            # Check for podman-compose
            if ! check_command "podman-compose"; then
                log_error "podman-compose is not installed. Please install it first:"
                echo "  pip install podman-compose"
                echo "  # or"
                echo "  dnf install podman-compose"
                exit 1
            fi
            COMPOSE_CMD="podman-compose"
            
            log_success "Podman is available (compose: $COMPOSE_CMD)"
            ;;
            
        *)
            log_error "Invalid runtime: $runtime"
            log_error "Please specify --docker or --podman"
            exit 1
            ;;
    esac
}

# =============================================================================
# STATUS CHECK FUNCTIONS
# =============================================================================

check_mobsf_running() {
    if $CONTAINER_CMD ps --format '{{.Names}}' 2>/dev/null | grep -q "^${MOBSF_CONTAINER_NAME}$"; then
        return 0
    fi
    return 1
}

check_mcp_server_running() {
    if $CONTAINER_CMD ps --format '{{.Names}}' 2>/dev/null | grep -q "^${MCP_CONTAINER_NAME}$"; then
        return 0
    fi
    return 1
}

check_mcp_server_healthy() {
    if curl -s "http://localhost:${MCP_PORT}/health" > /dev/null 2>&1; then
        return 0
    fi
    return 1
}

# =============================================================================
# INSTALL FUNCTIONS
# =============================================================================

start_mobsf() {
    log_info "Setting up MobSF..."
    
    if check_mobsf_running; then
        log_warning "MobSF container is already running"
        return 0
    fi
    
    # Check if container exists but stopped
    if $CONTAINER_CMD ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${MOBSF_CONTAINER_NAME}$"; then
        log_info "Starting existing MobSF container..."
        $CONTAINER_CMD start "$MOBSF_CONTAINER_NAME"
    else
        log_info "Pulling MobSF Docker image..."
        $CONTAINER_CMD pull opensecurity/mobile-security-framework-mobsf:latest
        
        log_info "Starting MobSF container on port ${MOBSF_PORT}..."
        
        # Build volume mount with optional SELinux suffix
        local volume_mount="mobsf_data:/home/mobsf/.MobSF"
        if [ "$CONTAINER_CMD" = "podman" ]; then
            volume_mount="${volume_mount}:Z"
        fi
        
        $CONTAINER_CMD run -d \
            --name "$MOBSF_CONTAINER_NAME" \
            -p "${MOBSF_PORT}:8000" \
            -v "${volume_mount}" \
            --restart=unless-stopped \
            opensecurity/mobile-security-framework-mobsf:latest
    fi
    
    log_success "MobSF container started"
}

wait_for_mobsf() {
    log_info "Waiting for MobSF to be ready (this may take a minute)..."
    
    local max_attempts=60
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if curl -s "http://localhost:${MOBSF_PORT}" > /dev/null 2>&1; then
            log_success "MobSF is ready!"
            return 0
        fi
        
        echo -n "."
        sleep 2
        attempt=$((attempt + 1))
    done
    
    echo ""
    log_error "MobSF failed to start within expected time"
    log_info "Check logs with: $CONTAINER_CMD logs $MOBSF_CONTAINER_NAME"
    exit 1
}

get_mobsf_api_key() {
    echo -e "${BLUE}[INFO]${NC} Extracting MobSF API key..." >&2
    
    local max_attempts=30
    local attempt=1
    local api_key=""
    
    while [ $attempt -le $max_attempts ]; do
        # Extract API key: strip ANSI codes, find the line, extract just the key
        api_key=$($CONTAINER_CMD logs "$MOBSF_CONTAINER_NAME" 2>&1 | \
            sed 's/\x1b\[[0-9;]*m//g' | \
            grep 'REST API Key:' | \
            head -1 | \
            awk -F': ' '{print $2}' | \
            tr -d '[:space:]')
        
        # Validate it looks like a hex string (64 chars)
        if [ -n "$api_key" ] && [ ${#api_key} -eq 64 ]; then
            echo "$api_key"
            return 0
        fi
        
        sleep 1
        attempt=$((attempt + 1))
    done
    
    log_error "Could not extract API key from MobSF logs"
    log_info "You can find it manually in: $CONTAINER_CMD logs $MOBSF_CONTAINER_NAME | grep 'REST API Key'"
    exit 1
}

create_env_file() {
    local mobsf_api_key="$1"
    local mcp_api_key=""
    
    log_info "Creating .env file..."
    
    # Ask user if they want to enable authentication
    echo ""
    read -p "Enable MCP authentication (Bearer token)? [Y/n]: " enable_auth
    if [[ ! "$enable_auth" =~ ^[Nn]$ ]]; then
        # Generate a secure random token
        mcp_api_key=$(openssl rand -hex 32)
        log_success "Generated MCP API key for authentication"
    else
        log_warning "MCP server will run WITHOUT authentication"
    fi
    
    # For Podman, use host.containers.internal instead of host.docker.internal
    local host_internal="host.docker.internal"
    if [ "$CONTAINER_CMD" = "podman" ]; then
        host_internal="host.containers.internal"
    fi
    
    cat > "${SCRIPT_DIR}/.env" << EOF
# MobSF MCP Server Configuration
# Generated by mobsf.sh on $(date)
# Runtime: ${RUNTIME_NAME}

# MobSF Configuration
MOBSF_URL=http://${host_internal}:${MOBSF_PORT}
MOBSF_API_KEY=${mobsf_api_key}

# MCP Server Authentication
# Use this token in Authorization header: Bearer <token>
MCP_API_KEY=${mcp_api_key}

# MCP Server Configuration
PORT=${MCP_PORT}
EOF

    log_success ".env file created"
    
    # Show the MCP API key if generated
    if [ -n "$mcp_api_key" ]; then
        echo ""
        echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}║  🔐 MCP API Key (save this for your MCP client config):      ║${NC}"
        echo -e "${YELLOW}╠══════════════════════════════════════════════════════════════╣${NC}"
        echo -e "${YELLOW}║${NC}  ${mcp_api_key}  ${YELLOW}║${NC}"
        echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════╝${NC}"
        echo ""
    fi
}

start_mcp_server() {
    log_info "Building and starting MobSF MCP Server..."
    
    cd "$SCRIPT_DIR"
    
    # Stop existing container if running
    if $CONTAINER_CMD ps --format '{{.Names}}' 2>/dev/null | grep -q "^${MCP_CONTAINER_NAME}$"; then
        log_info "Stopping existing MCP server..."
        $COMPOSE_CMD down 2>/dev/null || true
    fi
    
    # Build and start
    $COMPOSE_CMD up -d --build
    
    log_success "MobSF MCP Server started"
}

wait_for_mcp_server() {
    log_info "Waiting for MCP server to be healthy..."
    
    local max_attempts=30
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if check_mcp_server_healthy; then
            log_success "MCP server is healthy!"
            return 0
        fi
        
        echo -n "."
        sleep 1
        attempt=$((attempt + 1))
    done
    
    echo ""
    log_warning "MCP server health check timed out, but it may still be starting..."
}

cmd_install() {
    print_banner "$GREEN" "Installation             ║"
    
    # Check if already fully installed
    if check_mobsf_running && check_mcp_server_running && check_mcp_server_healthy; then
        echo ""
        log_success "🎉 MobSF and MCP Server are already running!"
        echo ""
        echo -e "  MobSF Web UI:      ${BLUE}http://localhost:${MOBSF_PORT}${NC}"
        echo -e "  MCP Server:        ${BLUE}http://localhost:${MCP_PORT}/mcp${NC}"
        echo -e "  Health Check:      ${BLUE}http://localhost:${MCP_PORT}/health${NC}"
        echo ""
        echo -e "To restart:   ${YELLOW}$0 --restart --${CONTAINER_CMD}${NC}"
        echo -e "To reinstall: ${YELLOW}$0 --uninstall --${CONTAINER_CMD} --full && $0 --install --${CONTAINER_CMD}${NC}"
        echo ""
        return 0
    fi
    
    log_info "Using ${RUNTIME_NAME} as container runtime"
    
    start_mobsf
    wait_for_mobsf
    
    api_key=$(get_mobsf_api_key)
    log_success "Got API key: ${api_key:0:16}..."
    
    create_env_file "$api_key"
    
    start_mcp_server
    wait_for_mcp_server
    
    # Print final status
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║              ✅ Installation Complete!                       ║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}  Runtime:           ${CYAN}${RUNTIME_NAME}${NC}                              ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  MobSF Web UI:      ${BLUE}http://localhost:${MOBSF_PORT}${NC}                  ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  MCP Server:        ${BLUE}http://localhost:${MCP_PORT}/mcp${NC}               ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  Health Check:      ${BLUE}http://localhost:${MCP_PORT}/health${NC}            ${GREEN}║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}  Configure your MCP client with:                            ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  ${YELLOW}URL: http://localhost:${MCP_PORT}/mcp${NC}                          ${GREEN}║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "To stop services:  ${YELLOW}$0 --uninstall --${CONTAINER_CMD}${NC}"
    echo -e "View MCP logs:     ${YELLOW}$CONTAINER_CMD logs -f ${MCP_CONTAINER_NAME}${NC}"
    echo -e "View MobSF logs:   ${YELLOW}$CONTAINER_CMD logs -f ${MOBSF_CONTAINER_NAME}${NC}"
    echo ""
}

# =============================================================================
# UNINSTALL FUNCTIONS
# =============================================================================

remove_mcp_server() {
    log_info "Removing MobSF MCP Server..."
    
    cd "$SCRIPT_DIR"
    
    # Stop and remove container
    if $CONTAINER_CMD ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${MCP_CONTAINER_NAME}$"; then
        $COMPOSE_CMD down --rmi local 2>/dev/null || true
        log_success "MCP server container removed"
    else
        log_warning "MCP server container not found"
    fi
    
    # Remove network if exists
    $CONTAINER_CMD network rm mobsf-mcp-server_default 2>/dev/null || true
    
    # Optional: Remove .env file
    if [ -f "${SCRIPT_DIR}/.env" ]; then
        read -p "Remove .env file? [y/N]: " remove_env
        if [[ "$remove_env" =~ ^[Yy]$ ]]; then
            rm -f "${SCRIPT_DIR}/.env"
            log_success ".env file removed"
        fi
    fi
    
    # Optional: Remove uploads directory
    if [ -d "${SCRIPT_DIR}/uploads" ]; then
        read -p "Remove uploads directory? [y/N]: " remove_uploads
        if [[ "$remove_uploads" =~ ^[Yy]$ ]]; then
            rm -rf "${SCRIPT_DIR}/uploads"
            log_success "uploads directory removed"
        fi
    fi
    
    # Optional: Remove dist directory
    if [ -d "${SCRIPT_DIR}/dist" ]; then
        read -p "Remove dist (build) directory? [y/N]: " remove_dist
        if [[ "$remove_dist" =~ ^[Yy]$ ]]; then
            rm -rf "${SCRIPT_DIR}/dist"
            log_success "dist directory removed"
        fi
    fi
    
    # Optional: Remove node_modules
    if [ -d "${SCRIPT_DIR}/node_modules" ]; then
        read -p "Remove node_modules directory? [y/N]: " remove_modules
        if [[ "$remove_modules" =~ ^[Yy]$ ]]; then
            rm -rf "${SCRIPT_DIR}/node_modules"
            log_success "node_modules directory removed"
        fi
    fi
}

remove_mobsf() {
    log_info "Removing MobSF..."
    
    # Stop and remove container
    if $CONTAINER_CMD ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${MOBSF_CONTAINER_NAME}$"; then
        $CONTAINER_CMD stop "$MOBSF_CONTAINER_NAME" 2>/dev/null || true
        $CONTAINER_CMD rm "$MOBSF_CONTAINER_NAME" 2>/dev/null || true
        log_success "MobSF container removed"
    else
        log_warning "MobSF container not found"
    fi
    
    # Ask about removing volume (data)
    if $CONTAINER_CMD volume ls --format '{{.Name}}' 2>/dev/null | grep -q "mobsf_data"; then
        echo ""
        log_warning "MobSF data volume found (contains all scan results)"
        read -p "Remove MobSF data volume? This will delete ALL scan history! [y/N]: " remove_volume
        if [[ "$remove_volume" =~ ^[Yy]$ ]]; then
            $CONTAINER_CMD volume rm mobsf_data 2>/dev/null || true
            log_success "MobSF data volume removed"
        else
            log_info "Keeping MobSF data volume"
        fi
    fi
    
    # Ask about removing image
    if $CONTAINER_CMD images --format '{{.Repository}}' 2>/dev/null | grep -q "opensecurity/mobile-security-framework-mobsf"; then
        read -p "Remove MobSF image? [y/N]: " remove_image
        if [[ "$remove_image" =~ ^[Yy]$ ]]; then
            $CONTAINER_CMD rmi opensecurity/mobile-security-framework-mobsf:latest 2>/dev/null || true
            log_success "MobSF image removed"
        fi
    fi
}

full_cleanup() {
    echo ""
    log_warning "⚠️  FULL CLEANUP MODE"
    log_warning "This will remove:"
    echo "  - MobSF MCP Server container and image"
    echo "  - MobSF container, data, and image"
    echo "  - All local configuration files"
    echo ""
    
    read -p "Are you sure you want to continue? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "Aborted"
        exit 0
    fi
    
    remove_mcp_server
    remove_mobsf
    
    # Clean up MCP image
    if $CONTAINER_CMD images --format '{{.Repository}}' 2>/dev/null | grep -q "mobsf-mcp-server"; then
        $CONTAINER_CMD rmi mobsf-mcp-server-mobsf-mcp-server 2>/dev/null || true
        log_success "MCP server image removed"
    fi
}

uninstall_interactive() {
    echo ""
    echo "What would you like to remove?"
    echo ""
    echo "  1) MCP Server only (keep MobSF running)"
    echo "  2) Full cleanup (remove everything)"
    echo "  3) Cancel"
    echo ""
    read -p "Choose an option [1-3]: " choice
    
    case $choice in
        1)
            remove_mcp_server
            ;;
        2)
            full_cleanup
            ;;
        3)
            log_info "Cancelled"
            exit 0
            ;;
        *)
            log_error "Invalid option"
            exit 1
            ;;
    esac
}

cmd_uninstall() {
    local uninstall_mode="$1"
    
    print_banner "$RED" "Uninstallation           ║"
    
    log_info "Using ${RUNTIME_NAME} as container runtime"
    
    case "$uninstall_mode" in
        mcp-only)
            remove_mcp_server
            ;;
        full)
            full_cleanup
            ;;
        "")
            uninstall_interactive
            ;;
        *)
            log_error "Unknown uninstall option: --$uninstall_mode"
            exit 1
            ;;
    esac
    
    # Print status
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║              ✅ Uninstallation Complete!                     ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Check what's still running
    echo "Remaining containers:"
    if $CONTAINER_CMD ps -a --format '{{.Names}}' 2>/dev/null | grep -qE "^(${MOBSF_CONTAINER_NAME}|${MCP_CONTAINER_NAME})$"; then
        $CONTAINER_CMD ps -a --format "  - {{.Names}}: {{.Status}}" 2>/dev/null | grep -E "(${MOBSF_CONTAINER_NAME}|${MCP_CONTAINER_NAME})" || true
    else
        echo "  (none)"
    fi
    echo ""
    
    echo -e "To reinstall: ${YELLOW}$0 --install --${CONTAINER_CMD}${NC}"
    echo ""
}

# =============================================================================
# RESTART FUNCTION
# =============================================================================

cmd_restart() {
    print_banner "$YELLOW" "Restart                  ║"
    
    log_info "Using ${RUNTIME_NAME} as container runtime"
    log_info "Restarting MobSF MCP Server..."
    
    cd "$SCRIPT_DIR"
    
    # Check if .env exists
    if [ ! -f "${SCRIPT_DIR}/.env" ]; then
        log_error ".env file not found. Please run --install first."
        exit 1
    fi
    
    $COMPOSE_CMD down 2>/dev/null || true
    $COMPOSE_CMD up -d
    
    wait_for_mcp_server
    
    log_success "MCP Server restarted"
    echo ""
    echo "Current health status:"
    curl -s "http://localhost:${MCP_PORT}/health" 2>/dev/null | python3 -m json.tool 2>/dev/null || \
        curl -s "http://localhost:${MCP_PORT}/health" 2>/dev/null || \
        echo "  Unable to reach health endpoint"
    echo ""
}

# =============================================================================
# STATUS FUNCTION
# =============================================================================

cmd_status() {
    print_banner "$CYAN" "Status                   ║"
    
    log_info "Using ${RUNTIME_NAME} as container runtime"
    echo ""
    
    # MobSF status
    echo -e "${CYAN}MobSF Container:${NC}"
    if check_mobsf_running; then
        echo -e "  Status:    ${GREEN}Running${NC}"
        echo -e "  Container: $MOBSF_CONTAINER_NAME"
        echo -e "  Web UI:    http://localhost:${MOBSF_PORT}"
        
        # Check if MobSF is responding
        if curl -s "http://localhost:${MOBSF_PORT}" > /dev/null 2>&1; then
            echo -e "  Health:    ${GREEN}Healthy${NC}"
        else
            echo -e "  Health:    ${YELLOW}Not responding${NC}"
        fi
    else
        if $CONTAINER_CMD ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${MOBSF_CONTAINER_NAME}$"; then
            echo -e "  Status:    ${YELLOW}Stopped${NC}"
        else
            echo -e "  Status:    ${RED}Not installed${NC}"
        fi
    fi
    echo ""
    
    # MCP Server status
    echo -e "${CYAN}MCP Server Container:${NC}"
    if check_mcp_server_running; then
        echo -e "  Status:    ${GREEN}Running${NC}"
        echo -e "  Container: $MCP_CONTAINER_NAME"
        echo -e "  MCP URL:   http://localhost:${MCP_PORT}/mcp"
        
        # Check health
        if check_mcp_server_healthy; then
            echo -e "  Health:    ${GREEN}Healthy${NC}"
            echo ""
            echo -e "${CYAN}Health Details:${NC}"
            curl -s "http://localhost:${MCP_PORT}/health" 2>/dev/null | python3 -m json.tool 2>/dev/null | sed 's/^/  /' || \
                curl -s "http://localhost:${MCP_PORT}/health" 2>/dev/null | sed 's/^/  /'
        else
            echo -e "  Health:    ${YELLOW}Not responding${NC}"
        fi
    else
        if $CONTAINER_CMD ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${MCP_CONTAINER_NAME}$"; then
            echo -e "  Status:    ${YELLOW}Stopped${NC}"
        else
            echo -e "  Status:    ${RED}Not installed${NC}"
        fi
    fi
    echo ""
    
    # Configuration status
    echo -e "${CYAN}Configuration:${NC}"
    if [ -f "${SCRIPT_DIR}/.env" ]; then
        echo -e "  .env file: ${GREEN}Present${NC}"
        # Show non-sensitive config
        echo "  MOBSF_URL: $(grep MOBSF_URL "${SCRIPT_DIR}/.env" 2>/dev/null | cut -d= -f2 || echo 'N/A')"
        echo "  PORT:      $(grep ^PORT "${SCRIPT_DIR}/.env" 2>/dev/null | cut -d= -f2 || echo 'N/A')"
        if grep -q "MCP_API_KEY=.\+" "${SCRIPT_DIR}/.env" 2>/dev/null; then
            echo -e "  Auth:      ${GREEN}Enabled${NC}"
        else
            echo -e "  Auth:      ${YELLOW}Disabled${NC}"
        fi
    else
        echo -e "  .env file: ${RED}Not found${NC}"
    fi
    echo ""
    
    # Volume status
    echo -e "${CYAN}Volumes:${NC}"
    if $CONTAINER_CMD volume ls --format '{{.Name}}' 2>/dev/null | grep -q "mobsf_data"; then
        echo -e "  mobsf_data: ${GREEN}Present${NC}"
    else
        echo -e "  mobsf_data: ${YELLOW}Not found${NC}"
    fi
    echo ""
    
    # SELinux status (for RHEL/Fedora)
    if command -v getenforce &> /dev/null; then
        echo -e "${CYAN}SELinux:${NC}"
        echo "  Status: $(getenforce)"
        echo ""
    fi
}

# =============================================================================
# MAIN ENTRY POINT
# =============================================================================

main() {
    local command=""
    local runtime=""
    local uninstall_mode=""
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --install)
                command="install"
                shift
                ;;
            --uninstall)
                command="uninstall"
                shift
                ;;
            --restart)
                command="restart"
                shift
                ;;
            --status)
                command="status"
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            --docker)
                runtime="docker"
                shift
                ;;
            --podman)
                runtime="podman"
                shift
                ;;
            --mcp-only)
                uninstall_mode="mcp-only"
                shift
                ;;
            --full)
                uninstall_mode="full"
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                echo ""
                show_help
                exit 1
                ;;
        esac
    done
    
    # Validate command
    if [ -z "$command" ]; then
        log_error "No command specified"
        echo ""
        show_help
        exit 1
    fi
    
    # Validate runtime (required for all commands)
    if [ -z "$runtime" ]; then
        log_error "Container runtime not specified"
        log_error "Please specify --docker or --podman"
        echo ""
        show_help
        exit 1
    fi
    
    # Setup container runtime
    setup_container_runtime "$runtime"
    
    # Execute command
    case "$command" in
        install)
            cmd_install
            ;;
        uninstall)
            cmd_uninstall "$uninstall_mode"
            ;;
        restart)
            cmd_restart
            ;;
        status)
            cmd_status
            ;;
    esac
}

# Run main function
main "$@"
