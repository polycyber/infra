#!/bin/bash

set -euo pipefail  # Exit on error, undefined variables, and pipe failures

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

error_exit() {
    log_error "$1"
    exit "${2:-1}"
}

declare -A CONFIG=(
    [DRY_RUN]="false"
    [WORKING_DIR]="/home/${SUDO_USER:-$USER}"
    [CTF_REPO]=""
)

show_usage() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS]

Options:
    --working-folder DIR    Set working directory (default: /home/\$USER)
    --ctf-repo REPO         Set the CTF challenge repository name (must be placed in working directory) (mandatory)
    --dry-run               Runs without building docker images or ingesting challenges to make sure every path is properly set
    --help                  Show this help message

Examples:
  $SCRIPT_NAME --ctf-repo PolyPwnCTF-2025-challenges
  $SCRIPT_NAME --ctf-repo PolyPwnCTF-2025-challenges --working-folder /opt/ctf
EOF
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --working-folder)
                [[ -n ${2:-} ]] || error_exit "Missing value for --working-folder"
                CONFIG[WORKING_DIR]="$2"
                shift 2
                ;;
            --ctf-repo)
                [[ -n ${2:-} ]] || error_exit "Missing value for --ctf-repo"
                CONFIG[CTF_REPO]="$2"
                shift 2
                ;;
            --dry-run)
                CONFIG[DRY_RUN]="true"
                shift
                ;;
            --help)
                show_usage
                exit 0
                ;;
            *)
                error_exit "Unknown parameter: $1"
                ;;
        esac
    done
    [[ -n "${CONFIG[CTF_REPO]}" ]] || error_exit "Error: --ctf-repo is mandatory and must be specified."
    local repo_path="${CONFIG[WORKING_DIR]}/${CONFIG[CTF_REPO]}"
    [[ -d "$repo_path" ]] || error_exit "Error: Coudn't find local challenges repository $repo_path."
}

install_ctfcli() {
  if ! command -v ctfcli &> /dev/null; then
    log_info "CTFcli is not installed. Installing CTFcli..."
    pipx install ctfcli
    log_success "CTFcli installed successfully"
  else
    log_info "CTFcli is already installed."
  fi
}

build_challenges() {
  for category in "${CONFIG[CHALLENGE_PATH]}"/*; do
    if [ -d "$category" ]; then
      for challenge in "$category"/*; do
        if [ -d "$challenge" ]; then
          local challenge_name=$(basename "$challenge")
          local challenge_yml="$category/$challenge_name/challenge.yml"

          if grep -q '^type: docker$' "$challenge_yml"; then
            local docker_image=$(grep '^  docker_image:' "$challenge_yml" | sed -E 's/^  docker_image: "([^"]+):[^"]+"/\1/')
            log_info "Building Challenge: $challenge_name, Docker Image: $docker_image"
            if [ "${CONFIG[DRY_RUN]}" = "false" ]; then
              (cd "$category/$challenge_name" && docker build . -t "$docker_image" -f "$category/$challenge_name/Dockerfile")
            else
              echo "docker build . -t '$docker_image' -f '$category/$challenge_name/Dockerfile'"
            fi
          fi
        fi
      done
    fi
  done
}

ingest_challenges() {
  for category in "${CONFIG[CHALLENGE_PATH]}"/*; do
    if [ -d "$category" ]; then
      for challenge in "$category"/*; do
        if [ -d "$challenge" ]; then
          local challenge_name=$(basename "$challenge")
          log_info "Installing $challenge_name..."
          if [ "${CONFIG[DRY_RUN]}" = "false" ]; then
            ctf challenge install "$category/$challenge_name"
          else
            echo "ctf challenge install '$category/$challenge_name'"
          fi  
        fi
      done
    fi
  done
  log_success "All challenges have been ingested."
}

get_challenges_path() {
  local repo_path="${CONFIG[WORKING_DIR]}/${CONFIG[CTF_REPO]}"
  local complete_path="$repo_path"
  if [ -d "$repo_path/challenges" ]; then
    complete_path="$repo_path/challenges"
  fi
  CONFIG[CHALLENGE_PATH]="$complete_path"
}

main() {
  log_info "Starting CTF challenge setup..."
  install_ctfcli
  get_challenges_path
  build_challenges
  read -p "All Docker images have been built. Add them to the Docker Plugin directly in CTFd, then press Enter to continue with ingesting challenges..."
  ingest_challenges
  log_success "CTF challenge setup completed successfully!"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    parse_arguments "$@"
    main
fi
