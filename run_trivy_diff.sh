#!/bin/bash

# Script to run trivy_diff.py - Generate delta report from two Trivy HTML scan results
# Usage: ./run_trivy_diff.sh <old_file> <new_file> [output_file]

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_SCRIPT="${SCRIPT_DIR}/trivy_diff.py"

# Function to print usage
usage() {
    echo "Usage: $0 <old_file> <new_file> [output_file]"
    echo ""
    echo "Arguments:"
    echo "  old_file     Path to the older HTML scan file"
    echo "  new_file     Path to the newer HTML scan file"
    echo "  output_file  (Optional) Path to the output HTML file (default: delta_report.html)"
    echo ""
    echo "Example:"
    echo "  $0 scan_old.html scan_new.html"
    echo "  $0 scan_old.html scan_new.html my_delta_report.html"
    exit 1
}

# Check if Python is available
if ! command -v python3 &> /dev/null; then
    echo -e "${RED}Error: python3 is not installed or not in PATH${NC}" >&2
    exit 1
fi

# Check if the Python script exists
if [ ! -f "$PYTHON_SCRIPT" ]; then
    echo -e "${RED}Error: Python script not found at: ${PYTHON_SCRIPT}${NC}" >&2
    exit 1
fi

# Check for required arguments
if [ $# -lt 2 ]; then
    echo -e "${RED}Error: Missing required arguments${NC}" >&2
    usage
fi

OLD_FILE="$1"
NEW_FILE="$2"
OUTPUT_FILE="${3:-delta_report.html}"

# Validate input files exist
if [ ! -f "$OLD_FILE" ]; then
    echo -e "${RED}Error: Old file not found: ${OLD_FILE}${NC}" >&2
    exit 1
fi

if [ ! -f "$NEW_FILE" ]; then
    echo -e "${RED}Error: New file not found: ${NEW_FILE}${NC}" >&2
    exit 1
fi

# Check if beautifulsoup4 is installed
if ! python3 -c "import bs4" 2>/dev/null; then
    echo -e "${YELLOW}Warning: beautifulsoup4 is not installed.${NC}"
    echo -e "${YELLOW}Attempting to install...${NC}"
    
    # Try to install beautifulsoup4
    if python3 -m pip install --user beautifulsoup4 2>/dev/null || \
       python3 -m pip install --break-system-packages beautifulsoup4 2>/dev/null; then
        echo -e "${GREEN}✓ beautifulsoup4 installed successfully${NC}"
    else
        echo -e "${RED}Error: Failed to install beautifulsoup4${NC}" >&2
        echo -e "${YELLOW}Please install manually: pip install beautifulsoup4${NC}" >&2
        exit 1
    fi
fi

# Run the Python script
echo -e "${GREEN}Running Trivy diff analysis...${NC}"
echo "  Old file: $OLD_FILE"
echo "  New file: $NEW_FILE"
echo "  Output:   $OUTPUT_FILE"
echo ""

python3 "$PYTHON_SCRIPT" "$OLD_FILE" "$NEW_FILE" -o "$OUTPUT_FILE"

# Check exit status
if [ $? -eq 0 ]; then
    echo ""
    echo -e "${GREEN}✓ Delta report generated successfully: ${OUTPUT_FILE}${NC}"
    
    # Try to open the file if on macOS
    if [[ "$OSTYPE" == "darwin"* ]]; then
        read -p "Open the report in your default browser? (y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            open "$OUTPUT_FILE"
        fi
    fi
else
    echo -e "${RED}Error: Script execution failed${NC}" >&2
    exit 1
fi
