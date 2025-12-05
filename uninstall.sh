#!/bin/bash
#
# MobSF MCP Server - Uninstallation Script
#
# Options:
#   --mcp-only    Remove only the MCP server, keep MobSF running
#   --full        Remove both MCP server and MobSF (including data)
#   --help        Show this help message
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
MOBSF_CONTAINER_NAME="mobsf"
MCP_CONTAINER_NAME="mobsf-mcp-server"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Detect docker-compose command
if command -v docker-compose &> /dev/null; then
    DOCKER_COMPOSE="docker-compose"
elif docker compose version &> /dev/null 2>&1; then
    DOCKER_COMPOSE="docker compose"
else
    DOCKER_COMPOSE="docker-compose"
fi

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
    echo -e "${RED}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║       🗑️  MobSF MCP Server - Uninstallation Script          ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

show_help() {
    echo "Usage: $0 [OPTION]"
    echo ""
    echo "Options:"
    echo "  --mcp-only    Remove only the MCP server container"
    echo "                Keeps MobSF running for other uses"
    echo ""
    echo "  --full        Complete removal of both MCP server and MobSF"
    echo "                WARNING: This will delete all MobSF scan data!"
    echo ""
    echo "  --help        Show this help message"
    echo ""
    echo "If no option is provided, you will be prompted to choose."
    echo ""
}

# Remove MCP server only
remove_mcp_server() {
    log_info "Removing MobSF MCP Server..."
    
    cd "$SCRIPT_DIR"
    
    # Stop and remove container
    if docker ps -a --format '{{.Names}}' | grep -q "^${MCP_CONTAINER_NAME}$"; then
        $DOCKER_COMPOSE down --rmi local 2>/dev/null || true
        log_success "MCP server container removed"
    else
        log_warning "MCP server container not found"
    fi
    
    # Remove network if exists
    docker network rm mobsf-mcp-server_default 2>/dev/null || true
    
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

# Remove MobSF
remove_mobsf() {
    log_info "Removing MobSF..."
    
    # Stop and remove container
    if docker ps -a --format '{{.Names}}' | grep -q "^${MOBSF_CONTAINER_NAME}$"; then
        docker stop "$MOBSF_CONTAINER_NAME" 2>/dev/null || true
        docker rm "$MOBSF_CONTAINER_NAME" 2>/dev/null || true
        log_success "MobSF container removed"
    else
        log_warning "MobSF container not found"
    fi
    
    # Ask about removing volume (data)
    if docker volume ls --format '{{.Name}}' | grep -q "mobsf_data"; then
        echo ""
        log_warning "MobSF data volume found (contains all scan results)"
        read -p "Remove MobSF data volume? This will delete ALL scan history! [y/N]: " remove_volume
        if [[ "$remove_volume" =~ ^[Yy]$ ]]; then
            docker volume rm mobsf_data 2>/dev/null || true
            log_success "MobSF data volume removed"
        else
            log_info "Keeping MobSF data volume"
        fi
    fi
    
    # Ask about removing image
    if docker images --format '{{.Repository}}' | grep -q "opensecurity/mobile-security-framework-mobsf"; then
        read -p "Remove MobSF Docker image? [y/N]: " remove_image
        if [[ "$remove_image" =~ ^[Yy]$ ]]; then
            docker rmi opensecurity/mobile-security-framework-mobsf:latest 2>/dev/null || true
            log_success "MobSF Docker image removed"
        fi
    fi
}

# Full cleanup
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
    if docker images --format '{{.Repository}}' | grep -q "mobsf-mcp-server"; then
        docker rmi mobsf-mcp-server-mobsf-mcp-server 2>/dev/null || true
        log_success "MCP server Docker image removed"
    fi
}

# Interactive mode
interactive_mode() {
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

# Print status
print_status() {
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║              ✅ Uninstallation Complete!                     ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Check what's still running
    echo "Remaining containers:"
    if docker ps -a --format '{{.Names}}' | grep -qE "^(${MOBSF_CONTAINER_NAME}|${MCP_CONTAINER_NAME})$"; then
        docker ps -a --format "  - {{.Names}}: {{.Status}}" | grep -E "(${MOBSF_CONTAINER_NAME}|${MCP_CONTAINER_NAME})" || true
    else
        echo "  (none)"
    fi
    echo ""
    
    echo "To reinstall: ${YELLOW}./install.sh${NC}"
    echo ""
}

# Main function
main() {
    print_banner
    
    case "${1:-}" in
        --mcp-only)
            remove_mcp_server
            ;;
        --full)
            full_cleanup
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        "")
            interactive_mode
            ;;
        *)
            log_error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
    
    print_status
}

# Run main function
main "$@"
