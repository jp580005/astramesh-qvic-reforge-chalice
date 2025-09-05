#!/bin/bash
# AstraMesh QVic Release Builder
# Creates distribution packages for easy deployment

set -euo pipefail

# Configuration
PROJECT_NAME="astramesh-qvic"
VERSION_FILE="backend/main.py"
DIST_DIR="dist"
BUILD_DIR="build"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Get version from source
get_version() {
    if [[ -f "$VERSION_FILE" ]]; then
        grep -o 'version="[^"]*"' "$VERSION_FILE" | cut -d'"' -f2
    else
        echo "1.0.0"
    fi
}

# Clean previous builds
clean_build() {
    log "Cleaning previous builds..."
    rm -rf "$DIST_DIR" "$BUILD_DIR"
    mkdir -p "$DIST_DIR" "$BUILD_DIR"
}

# Run tests
run_tests() {
    log "Running tests..."
    if [[ -f "backend/requirements.txt" ]]; then
        python3 -m venv test_env
        source test_env/bin/activate
        pip install -r backend/requirements.txt
        python -m pytest backend/tests/ -v || {
            error "Tests failed!"
            deactivate
            rm -rf test_env
            exit 1
        }
        deactivate
        rm -rf test_env
        log "Tests passed!"
    else
        warn "No requirements.txt found, skipping tests"
    fi
}

# Create source distribution
create_source_dist() {
    local version=$1
    local archive_name="${PROJECT_NAME}-${version}"
    
    log "Creating source distribution: $archive_name"
    
    # Copy source files
    mkdir -p "$BUILD_DIR/$archive_name"
    
    # Copy essential files
    cp -r backend/ "$BUILD_DIR/$archive_name/"
    cp -r frontend/ "$BUILD_DIR/$archive_name/"
    cp -r docker/ "$BUILD_DIR/$archive_name/"
    cp -r k8s/ "$BUILD_DIR/$archive_name/"
    cp -r helm/ "$BUILD_DIR/$archive_name/"
    cp -r infra/ "$BUILD_DIR/$archive_name/"
    cp -r .configs/ "$BUILD_DIR/$archive_name/"
    cp -r .github/ "$BUILD_DIR/$archive_name/"
    
    # Copy root files
    cp README.md LICENSE .gitignore install.sh make_release.sh "$BUILD_DIR/$archive_name/"
    
    # Create version file
    echo "$version" > "$BUILD_DIR/$archive_name/.version"
    
    # Create tarball
    cd "$BUILD_DIR"
    tar -czf "../$DIST_DIR/${archive_name}.tar.gz" "$archive_name"
    cd ..
    
    log "Source distribution created: $DIST_DIR/${archive_name}.tar.gz"
}

# Create Docker image
create_docker_image() {
    local version=$1
    
    log "Building Docker image..."
    
    if command -v docker >/dev/null; then
        docker build -f docker/Dockerfile -t "${PROJECT_NAME}:${version}" -t "${PROJECT_NAME}:latest" .
        
        # Save Docker image
        docker save "${PROJECT_NAME}:${version}" | gzip > "$DIST_DIR/${PROJECT_NAME}-${version}-docker.tar.gz"
        
        log "Docker image created: ${PROJECT_NAME}:${version}"
        log "Docker image saved: $DIST_DIR/${PROJECT_NAME}-${version}-docker.tar.gz"
    else
        warn "Docker not found, skipping Docker image creation"
    fi
}

# Create Helm package
create_helm_package() {
    local version=$1
    
    log "Creating Helm package..."
    
    if command -v helm >/dev/null; then
        # Update Chart.yaml version
        sed -i "s/version: .*/version: $version/" helm/astramesh-qvic/Chart.yaml
        sed -i "s/appVersion: .*/appVersion: \"$version\"/" helm/astramesh-qvic/Chart.yaml
        
        # Package Helm chart
        helm package helm/astramesh-qvic/ -d "$DIST_DIR"
        
        log "Helm package created"
    else
        warn "Helm not found, skipping Helm package creation"
    fi
}

# Create installation bundle
create_install_bundle() {
    local version=$1
    local bundle_name="${PROJECT_NAME}-installer-${version}"
    
    log "Creating installation bundle..."
    
    mkdir -p "$BUILD_DIR/$bundle_name"
    
    # Copy installer and source
    cp install.sh "$BUILD_DIR/$bundle_name/"
    cp "$DIST_DIR/${PROJECT_NAME}-${version}.tar.gz" "$BUILD_DIR/$bundle_name/"
    
    # Create wrapper installer
    cat > "$BUILD_DIR/$bundle_name/install.sh" << 'EOF'
#!/bin/bash
# AstraMesh QVic Installation Bundle
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCHIVE=$(ls "$SCRIPT_DIR"/*.tar.gz | head -1)

if [[ -z "$ARCHIVE" ]]; then
    echo "Error: No archive found in bundle"
    exit 1
fi

echo "Extracting $ARCHIVE..."
tar -xzf "$ARCHIVE" -C /tmp/

EXTRACTED_DIR="/tmp/$(basename "$ARCHIVE" .tar.gz)"
cd "$EXTRACTED_DIR"

echo "Running installer..."
chmod +x install.sh
./install.sh "$@"

echo "Cleaning up..."
rm -rf "$EXTRACTED_DIR"

echo "Installation complete!"
EOF
    
    chmod +x "$BUILD_DIR/$bundle_name/install.sh"
    
    # Create bundle tarball
    cd "$BUILD_DIR"
    tar -czf "../$DIST_DIR/${bundle_name}.tar.gz" "$bundle_name"
    cd ..
    
    log "Installation bundle created: $DIST_DIR/${bundle_name}.tar.gz"
}

# Generate checksums
generate_checksums() {
    log "Generating checksums..."
    
    cd "$DIST_DIR"
    sha256sum *.tar.gz > checksums.sha256
    sha256sum *.tgz >> checksums.sha256 2>/dev/null || true
    cd ..
    
    log "Checksums generated: $DIST_DIR/checksums.sha256"
}

# Create release notes
create_release_notes() {
    local version=$1
    
    log "Creating release notes..."
    
    cat > "$DIST_DIR/RELEASE_NOTES.md" << EOF
# AstraMesh QVic Reforge Chalice v$version

## Release Information
- **Version**: $version
- **Release Date**: $(date '+%Y-%m-%d')
- **Build Date**: $(date '+%Y-%m-%d %H:%M:%S UTC')

## What's Included
- Source code distribution
- Docker image
- Helm chart
- Installation bundle
- Self-healing scripts

## Installation Options

### Quick Install (Recommended)
\`\`\`bash
curl -L https://github.com/jp580005/astramesh-qvic/releases/download/v$version/${PROJECT_NAME}-installer-${version}.tar.gz | tar -xz
cd ${PROJECT_NAME}-installer-${version}
sudo ./install.sh
\`\`\`

### Docker Installation
\`\`\`bash
docker load < ${PROJECT_NAME}-${version}-docker.tar.gz
docker-compose up -d
\`\`\`

### Kubernetes Installation
\`\`\`bash
helm install astramesh-qvic ${PROJECT_NAME}-${version}.tgz
\`\`\`

## Configuration
After installation, configure your API keys in \`/opt/astramesh/.env\`:
- TWITTER_BEARER_TOKEN
- OPENAI_API_KEY

## Features
- 🚀 AI-powered knowledge aggregation
- 🔄 Self-healing capabilities
- 🐳 Docker & Kubernetes ready
- 📊 Real-time health monitoring
- 🔧 Automatic updates

## Support
- Documentation: README.md
- Issues: https://github.com/jp580005/astramesh-qvic/issues
- Health Check: http://localhost:8000/health

## Checksums
See checksums.sha256 for file verification.
EOF
    
    log "Release notes created: $DIST_DIR/RELEASE_NOTES.md"
}

# Display build summary
display_summary() {
    local version=$1
    
    echo ""
    echo "=============================================="
    echo "AstraMesh QVic Release Build Complete!"
    echo "=============================================="
    echo "Version: $version"
    echo "Build Directory: $DIST_DIR"
    echo ""
    echo "Generated Files:"
    ls -la "$DIST_DIR"
    echo ""
    echo "Distribution Sizes:"
    du -h "$DIST_DIR"/*
    echo "=============================================="
}

# Main build process
main() {
    local version=$(get_version)
    
    log "Building AstraMesh QVic v$version release..."
    
    clean_build
    run_tests
    create_source_dist "$version"
    create_docker_image "$version"
    create_helm_package "$version"
    create_install_bundle "$version"
    generate_checksums
    create_release_notes "$version"
    display_summary "$version"
    
    log "Release build completed successfully!"
    log "Upload $DIST_DIR/* to GitHub releases"
}

# Handle command line arguments
case "${1:-build}" in
    "build")
        main
        ;;
    "clean")
        log "Cleaning build directories..."
        rm -rf "$DIST_DIR" "$BUILD_DIR"
        log "Clean complete"
        ;;
    "version")
        echo $(get_version)
        ;;
    *)
        echo "Usage: $0 [build|clean|version]"
        echo "  build   - Build release packages (default)"
        echo "  clean   - Clean build directories"
        echo "  version - Show current version"
        exit 1
        ;;
esac