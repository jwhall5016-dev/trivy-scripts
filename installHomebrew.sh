#!/bin/bash

# Checks for missing Command Line Developer Tools, downloads, and installs Homebrew package,
# and updates logged-in user's shells.

# Uncomment line below for debugging
#set -x

# Constants
readonly EXPECTED_TEAM_ID="927JGANW46"
readonly COMMAND_LINE_TOOLS_GIT_PATH="/Library/Developer/CommandLineTools/usr/bin/git"

err() {
  echo "ERROR: $*" >&2
}

log() {
  echo "INFO: $*" >&2
}

# Check for Command Line Developer Tools installation
check_and_install_command_line_tools() {
  if [[ ! -f "${COMMAND_LINE_TOOLS_GIT_PATH}" ]]; then
    log "Command Line Developer Tools are missing. Attempting to install..."
    xcode-select --install

    # Wait until the Command Line Tools are installed
    until xcode-select -p &>/dev/null; do
        sleep 10
    done
    
    if [[ ! -f "${COMMAND_LINE_TOOLS_GIT_PATH}" ]]; then
      err "Command Line Developer Tools failed to install"
      return 1
    fi
  fi
  log "Command Line Developer Tools are installed"
  return 0
}

# Download Homebrew package from GitHub releases
download_homebrew_package() {
  log "Finding latest Homebrew package download URL..."
  
  # Search for a package download in the last 10 Homebrew releases
  # Not all releases have a pkg asset and packages are added some time after release
  local download_url
  download_url=$(/usr/bin/curl -fs "https://api.github.com/repos/Homebrew/brew/releases?per_page=10" | awk -F '"' '/browser_download_url/ && /pkg/ { print $4; exit }')

  if [[ -z "${download_url}" ]]; then
    err "Failed to find a Homebrew package download URL"
    return 1
  fi

  # Download package to a temporary directory
  local pkg_download_dest pkg_filename pkg_filepath
  pkg_download_dest=$(mktemp -d)
  pkg_filename=$(basename "${download_url}")
  pkg_filepath="${pkg_download_dest}/${pkg_filename}"
  
  log "Downloading ${pkg_filename} to ${pkg_download_dest}..."
  /usr/bin/curl -fsLvo "${pkg_filepath}" "${download_url}"
  
  if [[ $? -ne 0 ]]; then
    err "Failed to download Homebrew package"
    return 1
  fi
  
  # Export the filepath for use by other functions
  echo "${pkg_filepath}"
  return 0
}

# Verify package code signature with spctl/Gatekeeper
verify_package() {
  local pkg_filepath="$1"
  
  if [[ -z "${pkg_filepath}" ]]; then
    err "Package filepath not provided"
    return 1
  fi
  
  log "Verifying package signature..."
  
  local spctl_out spctl_status team_id
  spctl_out=$(/usr/sbin/spctl -a -vv -t install "${pkg_filepath}" 2>&1)
  spctl_status=$?
  team_id=$(echo "${spctl_out}" | awk -F '(' '/origin=/ {print $2 }' | tr -d '()')
  
  if [[ ${spctl_status} -ne 0 ]]; then
    err "Unable to verify package (exit code: ${spctl_status})"
    err "spctl output: ${spctl_out}"
    return 1
  fi

  if [[ "${team_id}" != "${EXPECTED_TEAM_ID}" ]]; then
    err "Developer Team ID ${team_id} does not match expected ID ${EXPECTED_TEAM_ID}"
    return 1
  fi
  
  log "Package verified successfully"
  return 0
}

# Install Homebrew package and verify installation
install_homebrew_package() {
  local pkg_filepath="$1"
  
  if [[ -z "${pkg_filepath}" ]]; then
    err "Package filepath not provided"
    return 1
  fi
  
  log "Starting package installation..."
  local installer_log="/var/tmp/homebrew_installer.log"
  : > "${installer_log}"
  if ! /usr/sbin/installer -verbose -pkg "${pkg_filepath}" -target / >"${installer_log}" 2>&1; then
    err "Installer failed. See ${installer_log} for details"
    return 1
  fi
  log "Installer finished. Output captured in ${installer_log}"

  log "Verifying installation..."
  if ! /usr/sbin/pkgutil --pkg-info sh.brew.homebrew >/dev/null 2>&1; then
    err "Installation failed. No package receipt found"
    return 1
  fi
  log "Package receipt found"

  local homebrew_dir
  if [[ "$(arch)" == "i386" ]]; then
    homebrew_dir="/usr/local/Homebrew"
  else
    homebrew_dir="/opt/homebrew"
  fi
  
  if [[ ! -f "${homebrew_dir}/bin/brew" ]]; then
    err "Installation failed. brew executable not found"
    return 1
  fi
  
  log "brew executable found at ${homebrew_dir}/bin/brew"
  
  # Export homebrew directory for shell config update
  echo "${homebrew_dir}"
  return 0
}

# Check if homebrew shellenv is already configured in a file
check_homebrew_rc_file_configured() {
  local config_file="$1"
  local homebrew_dir="$2"
  
  if [[ ! -f "${config_file}" ]]; then
    return 1  # File doesn't exist, so not configured
  fi
  
  # Check if this script has already configured homebrew (look for our comment)
  if grep -q "^# Homebrew added by Self Service" "${config_file}" 2>/dev/null; then
    return 0  # Already configured by this script
  fi
  
  return 1  # Not configured
}

# Update bash and zsh configuration files
update_shell_configs() {
  local homebrew_dir="$1"
  
  if [[ -z "${homebrew_dir}" ]]; then
    err "Homebrew directory not provided"
    return 1
  fi
  
  log "Updating shell configurations..."
  
  local current_user
  current_user=$(scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ { print $3 }')
  log "Current user: ${current_user}"
  
  if [[ -z "${current_user}" ]]; then
    err "Could not determine current user"
    return 1
  fi
  
  local config_files=("/Users/${current_user}/.zshrc" "/Users/${current_user}/.bash_profile")
  local files_updated=0
  
  # Process each shell configuration file independently
  for config_file in "${config_files[@]}"; do
    if check_homebrew_rc_file_configured "${config_file}" "${homebrew_dir}"; then
      log "Homebrew already configured in $(basename "${config_file}") - skipping"
    else
      log "Adding Homebrew configuration to $(basename "${config_file}")"
      
      # Ensure file exists
      if [[ ! -f "${config_file}" ]]; then
        /usr/bin/touch "${config_file}"
      fi

      # Append only the required Homebrew shellenv lines
      # Append lines using ed to avoid shell redirection capturing unrelated output
      /bin/ed -s "${config_file}" <<EOF 2>/dev/null
$ a
# Homebrew added by Self Service $(date)
eval "\$(${homebrew_dir}/bin/brew shellenv)"
.
wq
EOF

      /usr/sbin/chown "${current_user}" "${config_file}"
      ((files_updated++))
    fi
  done
  
  if [[ ${files_updated} -gt 0 ]]; then
    log "Shell configurations updated for user: ${current_user} (${files_updated} files modified)"
  else
    log "No shell configuration updates needed - Homebrew already configured"
  fi
  
  return 0
}

# Main installation flow
main() {
  log "Starting Homebrew installation process..."
  
  # Check and install Command Line Developer Tools
  if ! check_and_install_command_line_tools; then
    exit 1
  fi
  
  # Download Homebrew package
  local pkg_filepath
  if ! pkg_filepath=$(download_homebrew_package); then
    exit 1
  fi
  
  # Verify package
  if ! verify_package "${pkg_filepath}"; then
    exit 1
  fi
  
  # Install package
  local homebrew_dir
  if ! homebrew_dir=$(install_homebrew_package "${pkg_filepath}"); then
    exit 1
  fi
  
  # Update shell configurations
  if ! update_shell_configs "${homebrew_dir}"; then
    exit 1
  fi
  
  log "Homebrew installation complete!"
  return 0
}

# Run main function
main
exit $?