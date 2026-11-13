#!/usr/bin/env bash

# Script to update all currently pulled Podman images to their latest versions
#
# Description: This script lists all local Podman images and pulls the latest versions

set -euo pipefail  # Exit on error, undefined variables, and pipe failures

# JFrog Artifactory Configuration
# Replace these with your actual Artifactory details
ARTIFACTORY_URL="${JFROG_REPO_URL:-your-company.jfrog.io}"

# Multiple repository configuration
# Define your Artifactory repositories in order of preference
# The script will try each repository until it finds the image
declare -a ARTIFACTORY_REPOS=(
    "${ARTIFACTORY_REPO:-dockerhub-remote}"    # Docker Hub proxy
    "science-docker"                             # Local Docker repository
    "dst-docker"                           # Virtual repository
    "plat-docker"                           # Virtual repository
    "k8sregistry-remote"                           # Virtual repository
)

# You can also set this via environment variable as a comma-separated list:
# export ARTIFACTORY_REPOS="dockerhub-remote,docker-local,docker-virtual"
if [[ -n "${ARTIFACTORY_REPOS_ENV:-}" ]]; then
    IFS=',' read -ra ARTIFACTORY_REPOS <<< "$ARTIFACTORY_REPOS_ENV"
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS:${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1"
}

log_error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1"
}

# Function to check if podman is installed
check_podman() {
    if ! command -v podman &> /dev/null; then
        log_error "Podman is not installed or not in PATH"
        exit 1
    fi
    log "Podman found: $(podman --version)"
}

# Function to check Artifactory authentication
check_artifactory_auth() {
    log "Checking Artifactory authentication..."
    
    # Try to login or verify existing credentials
    if ! podman login --get-login "$ARTIFACTORY_URL" &>/dev/null; then
        log_warning "Not logged in to Artifactory. You may need to run:"
        echo "  podman login $ARTIFACTORY_URL"
        echo "  (Use your JFrog username and API token/password)"
        echo
        log "Continuing anyway - some images may be publicly accessible..."
    else
        log_success "Already authenticated with Artifactory"
    fi
}

# Function to find the best Artifactory repository for an image
find_image_in_artifactory() {
    local image_name="$1"
    local tag="$2"
    
    # Try each repository in order until we find the image
    for repo in "${ARTIFACTORY_REPOS[@]}"; do
        local full_image="${ARTIFACTORY_URL}/${repo}/${image_name}:${tag}"
        
        # Check if image exists in this repository
        log "Checking for image in repository: ${repo}"
        if podman pull "$full_image" >/dev/null 2>&1; then
            log_success "Found image in repository: ${repo}"
            echo "$full_image"
            return 0
        else
            log "Image not found in repository: ${repo}"
        fi
    done
    
    # If not found in any repository, default to first repository
    local default_image="${ARTIFACTORY_URL}/${ARTIFACTORY_REPOS[0]}/${image_name}:${tag}"
    log_warning "Image not found in any configured repository. Using default: ${ARTIFACTORY_REPOS[0]}"
    echo "$default_image"
    return 1
}

# Function to ensure image uses Artifactory registry
ensure_artifactory_registry() {
    local image="$1"
    local image_name tag
    
    # Extract image name and tag
    if [[ "$image" == *":"* ]]; then
        tag="${image##*:}"
        image_name="${image%:*}"
    else
        tag="latest"
        image_name="$image"
    fi
    
    # Remove any existing registry prefix to get just the image name
    if [[ "$image_name" == *"/"* ]]; then
        # Check if it's already from our Artifactory
        if [[ "$image_name" == "${ARTIFACTORY_URL}/"* ]]; then
            # Already from Artifactory, return as-is
            echo "$image"
            return 0
        else
            # Extract just the image name (everything after the last /)
            image_name="${image_name##*/}"
        fi
    fi
    
    # Find the image in our Artifactory repositories
    find_image_in_artifactory "$image_name" "$tag"
}

# Function to get all current images
get_current_images() {
    log "Retrieving list of current Podman images..."
    
    # Get images in format "repository:tag"
    # Filter out <none> repositories and tags
    local images
    images=$(podman images --format "{{.Repository}}:{{.Tag}}" | grep -v '<none>' | sort -u)
    
    if [[ -z "$images" ]]; then
        log_warning "No images found in local Podman storage"
        exit 0
    fi
    
    echo "$images"
}

# Function to pull latest version of an image
pull_image() {
    local image="$1"
    
    # Ensure the image uses Artifactory registry
    local artifactory_image
    artifactory_image=$(ensure_artifactory_registry "$image")
    
    # Check if the smart detection already found and pulled the image
    if [[ "$?" -eq 0 ]]; then
        log_success "Image already pulled during repository detection: $artifactory_image"
        return 0
    fi
    
    local repository="${artifactory_image%:*}"
    local tag="${artifactory_image#*:}"
    
    log "Pulling latest version from Artifactory: $artifactory_image"
    
    # If tag is 'latest', just pull the image as-is
    # Otherwise, try to pull the latest tag for the repository
    if [[ "$tag" == "latest" ]]; then
        if podman pull "$artifactory_image" >/dev/null 2>&1; then
            log_success "Updated $artifactory_image"
            return 0
        else
            log_error "Failed to pull $artifactory_image from Artifactory"
            return 1
        fi
    else
        # For non-latest tags, pull both the specific tag and latest
        local pull_success=0
        
        # Pull the specific tag (in case there are updates to that tag)
        if podman pull "$artifactory_image" >/dev/null 2>&1; then
            log_success "Updated $artifactory_image (specific tag)"
            pull_success=1
        else
            log_warning "Could not update specific tag: $artifactory_image"
        fi
        
        # Also try to pull the latest tag for this repository
        if podman pull "${repository}:latest" >/dev/null 2>&1; then
            log_success "Updated ${repository}:latest"
            pull_success=1
        else
            log_warning "Could not pull latest tag for: $repository"
        fi
        
        return $((1 - pull_success))
    fi
}

# Function to clean up duplicate images
cleanup_duplicates() {
    log "Cleaning up duplicate images..."
    
    # Get all images with their IDs, repositories, and tags, sorted by creation time (newest first)
    local image_data
    image_data=$(podman images --format "{{.ID}} {{.Repository}}:{{.Tag}} {{.Created}}" | grep -v '<none>' | sort -k3 -r)
    
    if [[ -z "$image_data" ]]; then
        log "No images found for duplicate cleanup"
        return 0
    fi
    
    # Create temporary files to track seen images (more portable than associative arrays)
    local temp_dir
    temp_dir=$(mktemp -d)
    local seen_images_file="${temp_dir}/seen_images"
    local duplicates_found=0
    local duplicates_removed=0
    
    # Process each image to find duplicates
    while IFS=' ' read -r image_id image_name creation_time; do
        if [[ -n "$image_id" && -n "$image_name" && "$image_name" != "<none>:<none>" ]]; then
            # Check if we've seen this image name before
            if grep -q "^${image_name}$" "$seen_images_file" 2>/dev/null; then
                ((duplicates_found++))
                log "Found duplicate image: $image_name (ID: ${image_id:0:12})"
                
                # This is a duplicate (older since we sorted by creation time desc)
                log "Removing older duplicate: ${image_id:0:12}"
                if podman rmi "$image_id" &>/dev/null; then
                    ((duplicates_removed++))
                    log_success "Removed older duplicate image: $image_name"
                else
                    log_warning "Could not remove older duplicate: ${image_id:0:12}"
                fi
            else
                # First time seeing this image name, record it
                echo "$image_name" >> "$seen_images_file"
            fi
        fi
    done <<< "$image_data"
    
    # Clean up temporary files
    rm -rf "$temp_dir"
    
    if [[ $duplicates_found -gt 0 ]]; then
        log_success "Duplicate cleanup complete: Found $duplicates_found duplicates, removed $duplicates_removed"
    else
        log "No duplicate images found"
    fi
}

# Function to show summary
show_summary() {
    local total="$1"
    local successful="$2"
    local failed="$3"
    
    echo
    log "Update Summary:"
    echo "  Total images processed: $total"
    echo "  Successfully updated: $successful"
    echo "  Failed to update: $failed"
    
    if [[ $failed -gt 0 ]]; then
        log_warning "Some images failed to update. Check the logs above for details."
    else
        log_success "All images updated successfully!"
    fi
}

# Main function
main() {
    log "Starting Podman image update process..."
    
    # Check if podman is available
    check_podman
    
    # Check Artifactory authentication
    check_artifactory_auth
    
    # Get current images
    local images
    images=$(get_current_images)
    
    # Count images
    local total_images
    total_images=$(echo "$images" | wc -l)
    log "Found $total_images images to update"
    
    # Initialize counters
    local successful=0
    local failed=0
    
    # Process each image
    while IFS= read -r image; do
        if [[ -n "$image" ]]; then
            if pull_image "$image"; then
                ((successful++))
            else
                ((failed++))
            fi
            echo  # Add spacing between image updates
        fi
    done <<< "$images"
    
    # Show summary
    show_summary "$total_images" "$successful" "$failed"
    
    # Clean up duplicate images
    cleanup_duplicates
    
    # Clean up dangling images (optional)
    log "Cleaning up dangling images..."
    if podman image prune -f &>/dev/null; then
        log_success "Cleaned up dangling images"
    else
        log_warning "Could not clean up dangling images"
    fi
    
    log "Image update process completed!"
}

# Help function
show_help() {
    cat << EOF
Podman Image Updater Script

USAGE:
    $0 [OPTIONS]

DESCRIPTION:
    This script updates all currently pulled Podman images to their latest versions from JFrog Artifactory.
    It will:
    1. Check Artifactory authentication
    2. List all local Podman images
    3. Smart repository detection - tries multiple Artifactory repos to find each image
    4. Ensure all images are pulled from Artifactory (converts docker.io images automatically)
    5. Pull the latest version of each image from the appropriate Artifactory repository
    6. For non-latest tagged images, attempt to pull both the specific tag and latest
    7. Clean up duplicate images (keeps the newest version)
    8. Clean up dangling images after updates
    9. Provide a summary of the update process

OPTIONS:
    -h, --help    Show this help message and exit

EXAMPLES:
    $0                                          # Update all images using default repositories
    $0 --help                                   # Show help
    
    # Set custom repositories via environment variables:
    export ARTIFACTORY_REPOS_ENV="dockerhub-remote,docker-local,my-custom-repo"
    $0

CONFIGURATION:
    Multiple Artifactory repositories can be configured in the script or via environment variables:
    
    1. Edit the ARTIFACTORY_REPOS array in the script:
       ARTIFACTORY_REPOS=("dockerhub-remote" "docker-local" "docker-virtual")
    
    2. Or set via environment variable:
       export ARTIFACTORY_REPOS_ENV="dockerhub-remote,docker-local,docker-virtual"

NOTES:
    - This script requires Podman to be installed and accessible
    - Configure JFROG_REPO_URL environment variable or edit ARTIFACTORY_URL in the script
    - You must be authenticated with your JFrog Artifactory (run: podman login your-artifactory-url)
    - The script tries multiple Artifactory repositories in order until it finds each image
    - Images without registry prefixes will automatically be converted to use Artifactory
    - Images with specific version tags (e.g., v1.0) will have their specific tag updated
      and the script will also attempt to pull the latest tag for the same repository
    - Duplicate images are automatically cleaned up (keeps the newest version)
    - The script includes error handling and will continue processing even if some images fail
    - Dangling images are automatically cleaned up after the update process

EOF
}

# Parse command line arguments
case "${1:-}" in
    -h|--help)
        show_help
        exit 0
        ;;
    "")
        main
        ;;
    *)
        log_error "Unknown option: $1"
        show_help
        exit 1
        ;;
esac
