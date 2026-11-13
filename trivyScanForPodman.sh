#!/usr/bin/env bash
#
# Script to scan images within `podman images` using Trivy
#
# Generates scans in JSON and HTML formats
#

# Configuration
OUTPUT_DIR="trivy-scans-$(date +%Y%m%d_%H%M%S)"
HTML_TEMPLATE_LOCATION="/opt/homebrew/Cellar/trivy/0.68.2/share/trivy/templates/html.tpl"

set -euo pipefail

# Function to display a menu and get user selection
select_images() {
    local images=("$@")
    local selected_images=()
    
    echo "Available images:"
    echo "0) Scan ALL images (${#images[@]} total)"
    for i in "${!images[@]}"; do
        echo "$((i+1))) ${images[i]}"
    done
    echo
    
    while true; do
        read -p "Select an option (0 for all, or image number): " choice
        
        if [[ "$choice" =~ ^[0-9]+$ ]]; then
            if [[ "$choice" -eq 0 ]]; then
                selected_images=("${images[@]}")
                echo "Selected: ALL images (${#images[@]} total)"
                break
            elif [[ "$choice" -ge 1 && "$choice" -le "${#images[@]}" ]]; then
                selected_images=("${images[$((choice-1))]}")
                echo "Selected: ${images[$((choice-1))]}"
                break
            else
                echo "Invalid selection. Please choose 0-${#images[@]}"
            fi
        else
            echo "Please enter a valid number."
        fi
    done
    
    # Return selected images via global variable
    SELECTED_IMAGES=("${selected_images[@]}")
}

# Function to perform the actual scanning
scan_image() {
    local image="$1"
    local safe_name=$(echo "$image" | tr '/:' '_')
    local json_report="$OUTPUT_DIR/${safe_name}.json"
    local html_report="$OUTPUT_DIR/${safe_name}.html"

    echo "Scanning $image"
    trivy -q image \
        --scanners vuln,secret,license `# Choose what you need to scan here` \
        --severity CRITICAL,HIGH,MEDIUM `# Adjust as needed` \
        --format json -o "$json_report" "$image"

    echo "Converting JSON to HTML"
    trivy convert -q \
        --format template \
        --template "@${HTML_TEMPLATE_LOCATION}" \
        -o "$html_report" "$json_report"
}

mkdir -p "$OUTPUT_DIR"

# Grab image:tag pairs
IMAGES=()
while IFS= read -r img; do
    IMAGES+=("$img")
done < <(
    podman images --format '{{.Repository}}:{{.Tag}}' |
    grep -Ev '^(<none>|sha256):'
)

if [[ ${#IMAGES[@]} -eq 0 ]]; then
    echo "No images found in 'podman images'." >&2
    exit 1
fi

# Let user select images
select_images "${IMAGES[@]}"

echo -e "\nStarting scans..."

# Scan selected images
for IMAGE in "${SELECTED_IMAGES[@]}"; do
    scan_image "$IMAGE"
done

echo -e "\nScans Completed. Reports can be found in: $OUTPUT_DIR"
