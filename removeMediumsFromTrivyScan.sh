#!/usr/bin/env bash
set -euo pipefail

# remove-medium-rows.sh
# Recursively remove HTML table rows with Medium severity.
# - Targets rows like: <tr class="...severity-MEDIUM..."> ... </tr>
# - Or rows containing a <td class="severity">MEDIUM</td> cell.
# - Creates .bak backups per file.
# Usage:
#   ./remove-medium-rows.sh [ROOT_DIR]
# Example:
#   ./remove-medium-rows.sh /path/to/trivy-scans

ROOT_DIR=${1:-$(pwd)}

if [[ ! -d "$ROOT_DIR" ]]; then
  echo "Error: ROOT_DIR is not a directory: $ROOT_DIR" >&2
  exit 1
fi

export LC_ALL=C

# Find and process all HTML files
while IFS= read -r -d '' file; do
  # Use perl with slurp mode (-0777) to allow multi-line matching
  perl -0777 -i.bak -pe '
    s#<tr\b[^>]*class="[^"]*\bseverity-MEDIUM\b[^"]*"[^>]*>[\s\S]*?</tr>\s*##gis;
    s#<tr\b[^>]*>[\s\S]*?<td[^>]*class="severity"[^>]*>\s*MEDIUM\s*</td>[\s\S]*?</tr>\s*##gis;#;
  ' "$file"

done < <(find "$ROOT_DIR" -type f -name '*.html' -print0)

# Verification summary
count=$(grep -RIl -e '<tr[^>]*class="[^"]*\bseverity-MEDIUM\b' -e '<td[^>]*class="severity"[^>]*>[[:space:]]*MEDIUM[[:space:]]*<' --include='*.html' "$ROOT_DIR" | wc -l | sed 's/ //g')
echo "Remaining files with Medium rows: $count"

exit 0