#!/bin/bash
#
# MobSF MCP Server - Installation Script
# 
# This script will:
# 1. Check prerequisites (Docker, Node.js)
# 2. Pull and start MobSF Docker container on port 9000
# 3. Wait for MobSF to be ready and extract API key
# 4. Create .env file with configuration
# 5. Build and start MobSF MCP Server
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
MOBSF_PORT=${MOBSF_PORT:-9000}
MCP_PORT=${MCP_PORT:-7567}
MOBSF_CONTAINER_NAME="mobsf"
MCP_CONTAINER_NAME="mobsf-mcp-server"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Helper functions
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

print_banner() {
    echo -e "${GREEN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║       🛡️  MobSF MCP Server - Installation Script            ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

check_command() {
    if ! command -v "$1" &> /dev/null; then
        log_error "$1 is not installed. Please install it first."
        exit 1
    fi
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    check_command "docker"
    log_success "Docker is installed"
    
    # Check if Docker daemon is running
    if ! docker info &> /dev/null; then
        log_error "Docker daemon is not running. Please start Docker first."
        exit 1
    fi
    log_success "Docker daemon is running"
    
    # Check for docker-compose or docker compose
    if command -v docker-compose &> /dev/null; then
        DOCKER_COMPOSE="docker-compose"
    elif docker compose version &> /dev/null; then
        DOCKER_COMPOSE="docker compose"
    else
        log_error "docker-compose is not installed. Please install it first."
        exit 1
    fi
    log_success "Docker Compose is available ($DOCKER_COMPOSE)"
}

# Check if MobSF is already running
check_mobsf_running() {
    if docker ps --format '{{.Names}}' | grep -q "^${MOBSF_CONTAINER_NAME}$"; then
        return 0
    fi
    return 1
}

# Check if MCP server is already running and healthy
check_mcp_server_running() {
    if docker ps --format '{{.Names}}' | grep -q "^${MCP_CONTAINER_NAME}$"; then
        # Also verify it's healthy
        if curl -s "http://localhost:${MCP_PORT}/health" > /dev/null 2>&1; then
            return 0
        fi
    fi
    return 1
}

# Check if everything is already installed and running
check_already_installed() {
    if check_mobsf_running && check_mcp_server_running; then
        echo ""
        log_success "🎉 MobSF and MCP Server are already running!"
        echo ""
        echo -e "  MobSF Web UI:      ${BLUE}http://localhost:${MOBSF_PORT}${NC}"
        echo -e "  MCP Server:        ${BLUE}http://localhost:${MCP_PORT}/mcp${NC}"
        echo -e "  Health Check:      ${BLUE}http://localhost:${MCP_PORT}/health${NC}"
        echo ""
        echo -e "To restart:   ${YELLOW}./uninstall.sh --mcp-only && ./install.sh${NC}"
        echo -e "To reinstall: ${YELLOW}./uninstall.sh --full && ./install.sh${NC}"
        echo ""
        exit 0
    fi
}

# Start MobSF
start_mobsf() {
    log_info "Setting up MobSF..."
    
    if check_mobsf_running; then
        log_warning "MobSF container is already running"
    else
        # Check if container exists but stopped
        if docker ps -a --format '{{.Names}}' | grep -q "^${MOBSF_CONTAINER_NAME}$"; then
            log_info "Starting existing MobSF container..."
            docker start "$MOBSF_CONTAINER_NAME"
        else
            log_info "Pulling MobSF Docker image..."
            docker pull opensecurity/mobile-security-framework-mobsf:latest
            
            log_info "Starting MobSF container on port ${MOBSF_PORT}..."
            docker run -d \
                --name "$MOBSF_CONTAINER_NAME" \
                -p "${MOBSF_PORT}:8000" \
                -v mobsf_data:/home/mobsf/.MobSF \
                --restart unless-stopped \
                opensecurity/mobile-security-framework-mobsf:latest
        fi
    fi
    
    log_success "MobSF container started"
}

# Wait for MobSF to be ready
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
    log_info "Check logs with: docker logs $MOBSF_CONTAINER_NAME"
    exit 1
}

# Extract API key from MobSF logs
get_mobsf_api_key() {
    # Log to stderr so it doesn't get captured in the return value
    echo -e "${BLUE}[INFO]${NC} Extracting MobSF API key..." >&2
    
    local max_attempts=30
    local attempt=1
    local api_key=""
    
    while [ $attempt -le $max_attempts ]; do
        # Extract API key: strip ANSI codes, find the line, extract just the key
        api_key=$(docker logs "$MOBSF_CONTAINER_NAME" 2>&1 | \
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
    log_info "You can find it manually in: docker logs $MOBSF_CONTAINER_NAME | grep 'REST API Key'"
    exit 1
}

# Create .env file
create_env_file() {
    local api_key="$1"
    
    log_info "Creating .env file..."
    
    cat > "${SCRIPT_DIR}/.env" << EOF
# MobSF MCP Server Configuration
# Generated by install.sh on $(date)

# MobSF Configuration
MOBSF_URL=http://host.docker.internal:${MOBSF_PORT}
MOBSF_API_KEY=${api_key}

# MCP Server Configuration
PORT=${MCP_PORT}
EOF

    log_success ".env file created"
}

# Build and start MCP server
start_mcp_server() {
    log_info "Building and starting MobSF MCP Server..."
    
    cd "$SCRIPT_DIR"
    
    # Stop existing container if running
    if docker ps --format '{{.Names}}' | grep -q "^${MCP_CONTAINER_NAME}$"; then
        log_info "Stopping existing MCP server..."
        $DOCKER_COMPOSE down
    fi
    
    # Build and start
    $DOCKER_COMPOSE up -d --build
    
    log_success "MobSF MCP Server started"
}

# Wait for MCP server to be healthy
wait_for_mcp_server() {
    log_info "Waiting for MCP server to be healthy..."
    
    local max_attempts=30
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if curl -s "http://localhost:${MCP_PORT}/health" > /dev/null 2>&1; then
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

# Print final status
print_status() {
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║              ✅ Installation Complete!                       ║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}  MobSF Web UI:      ${BLUE}http://localhost:${MOBSF_PORT}${NC}                  ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  MCP Server:        ${BLUE}http://localhost:${MCP_PORT}/mcp${NC}               ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  Health Check:      ${BLUE}http://localhost:${MCP_PORT}/health${NC}            ${GREEN}║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}  Configure your MCP client with:                            ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  ${YELLOW}URL: http://localhost:${MCP_PORT}/mcp${NC}                          ${GREEN}║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "To stop services:  ${YELLOW}./uninstall.sh${NC}"
    echo -e "View MCP logs:     ${YELLOW}docker logs -f ${MCP_CONTAINER_NAME}${NC}"
    echo -e "View MobSF logs:   ${YELLOW}docker logs -f ${MOBSF_CONTAINER_NAME}${NC}"
    echo ""
}

# Main installation flow
main() {
    print_banner
    
    # Check if already fully installed
    check_already_installed
    
    check_prerequisites
    
    start_mobsf
    wait_for_mobsf
    
    api_key=$(get_mobsf_api_key)
    log_success "Got API key: ${api_key:0:16}..."
    
    create_env_file "$api_key"
    
    start_mcp_server
    wait_for_mcp_server
    
    print_status
}

# Run main function
main "$@"
