#!/usr/bin/env bash
# Enhanced CTF Challenge Management Tool
# Builds, ingests, syncs, and manages CTF challenges for CTFd.
#
# This script is meant to be invoked from the WORKING directory, not from
# inside the infra/ folder.  It resolves its own location to source the
# shared libraries and challenge sub-modules.

set -euo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly VERSION="2.0.0"

# ── Source shared libraries ──────────────────────────────────────────────────

source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/env.sh"
source "$SCRIPT_DIR/lib/challenges.sh"
source "$SCRIPT_DIR/lib/ctfd/config.sh"
source "$SCRIPT_DIR/lib/ctfd/api.sh"
source "$SCRIPT_DIR/lib/ctfd/yaml.sh"
source "$SCRIPT_DIR/lib/ctfd/resources.sh"
source "$SCRIPT_DIR/lib/ctfd/challenge.sh"

# ── Source challenge modules ─────────────────────────────────────────────────

source "$SCRIPT_DIR/challenges/deps.sh"
source "$SCRIPT_DIR/challenges/build.sh"
source "$SCRIPT_DIR/challenges/ingest.sh"
source "$SCRIPT_DIR/challenges/sync.sh"
source "$SCRIPT_DIR/challenges/status.sh"
source "$SCRIPT_DIR/challenges/cleanup.sh"

# ── Configuration ────────────────────────────────────────────────────────────

declare -A CONFIG=(
    [DRY_RUN]="false"
    [WORKING_DIR]="/home/${SUDO_USER:-$USER}"
    [CTF_REPO]=""
    [ACTION]="all"
    [CATEGORIES]=""
    [CHALLENGES]=""
    [FORCE]="false"
    [PARALLEL_BUILDS]="4"
    [DEBUG]="false"
    [SKIP_DOCKER_CHECK]="false"
    [CONFIG_FILE]=""
)

# ── Usage & Version ──────────────────────────────────────────────────────────

show_usage() {
    cat << EOF
Enhanced CTF Challenge Management Tool v${VERSION}

Usage: $SCRIPT_NAME [OPTIONS]

ACTIONS:
    --action ACTION         Action to perform: all, build, ingest, sync, status, cleanup (default: all)

MAIN OPTIONS:
    --working-folder DIR    Set working directory (default: /home/\$USER)
    --ctf-repo REPO         Set the CTF challenge repository name (mandatory)
    --config FILE           Load configuration from file

FILTERING OPTIONS:
    --categories LIST       Comma-separated list of categories to process
    --challenges LIST       Comma-separated list of specific challenges to process

BEHAVIOR OPTIONS:
    --dry-run               Show what would be done without executing
    --force                 Force operations (rebuild images, overwrite challenges)
    --parallel-builds N     Number of parallel Docker builds (default: 4)

DEBUGGING:
    --debug                 Enable debug output
    --skip-docker-check     Skip Docker daemon availability check
    --help                  Show this help message
    --version               Show version information

EXAMPLES:
  $SCRIPT_NAME --ctf-repo PolyPwnCTF-2025-Challenges
  $SCRIPT_NAME --action build --ctf-repo PolyPwnCTF-2025-Challenges --categories "web,crypto"
  $SCRIPT_NAME --action ingest --ctf-repo PolyPwnCTF-2025-Challenges
  $SCRIPT_NAME --action sync --ctf-repo PolyPwnCTF-2025-Challenges --force
  $SCRIPT_NAME --ctf-repo PolyPwnCTF-2025-Challenges --dry-run

CONFIG FILE FORMAT:
  Create a .env file with KEY=VALUE pairs:
    CTF_REPO=PolyPwnCTF-2025-Challenges
    WORKING_DIR=/opt/ctf
    PARALLEL_BUILDS=8
EOF
}

show_version() {
    echo "$SCRIPT_NAME version $VERSION"
    exit 0
}

# ── Argument parsing ─────────────────────────────────────────────────────────

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --working-folder)
                [[ -n ${2:-} ]] || error_exit "Missing value for --working-folder"
                CONFIG[WORKING_DIR]="$2"; shift 2 ;;
            --ctf-repo)
                [[ -n ${2:-} ]] || error_exit "Missing value for --ctf-repo"
                CONFIG[CTF_REPO]="$2"; shift 2 ;;
            --action)
                [[ -n ${2:-} ]] || error_exit "Missing value for --action"
                case "$2" in
                    all|build|ingest|sync|status|cleanup) CONFIG[ACTION]="$2" ;;
                    *) error_exit "Invalid action: $2. Valid: all, build, ingest, sync, status, cleanup" ;;
                esac
                shift 2 ;;
            --categories)
                [[ -n ${2:-} ]] || error_exit "Missing value for --categories"
                CONFIG[CATEGORIES]="$2"; shift 2 ;;
            --challenges)
                [[ -n ${2:-} ]] || error_exit "Missing value for --challenges"
                CONFIG[CHALLENGES]="$2"; shift 2 ;;
            --parallel-builds)
                [[ -n ${2:-} ]] || error_exit "Missing value for --parallel-builds"
                [[ "$2" =~ ^[0-9]+$ ]] || error_exit "Invalid number for --parallel-builds: $2"
                CONFIG[PARALLEL_BUILDS]="$2"; shift 2 ;;
            --config)
                [[ -n ${2:-} ]] || error_exit "Missing value for --config"
                CONFIG[CONFIG_FILE]="$2"; shift 2 ;;
            --dry-run)           CONFIG[DRY_RUN]="true";         shift ;;
            --force)             CONFIG[FORCE]="true";           shift ;;
            --debug)             CONFIG[DEBUG]="true"; _DEBUG="true"; shift ;;
            --skip-docker-check) CONFIG[SKIP_DOCKER_CHECK]="true"; shift ;;
            --help)    show_usage;   exit 0 ;;
            --version) show_version        ;;
            *)         error_exit "Unknown parameter: $1" ;;
        esac
    done

    [[ -n "${CONFIG[CONFIG_FILE]}" ]] && load_config_file "${CONFIG[CONFIG_FILE]}"
    [[ -n "${CONFIG[CTF_REPO]}" ]]   || error_exit "Error: --ctf-repo is mandatory and must be specified."

    local repo_path
    if [[ "${CONFIG[CTF_REPO]}" == /* ]]; then
        repo_path="${CONFIG[CTF_REPO]}"
    else
        repo_path="${CONFIG[WORKING_DIR]}/${CONFIG[CTF_REPO]}"
    fi
    CONFIG[CTF_REPO_PATH]="$repo_path"
    [[ -d "$repo_path" ]] || error_exit "Error: Couldn't find local challenges repository $repo_path."
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    log_info "Enhanced CTF Challenge Management Tool v${VERSION}"
    log_info "Action: ${CONFIG[ACTION]}"

    check_dependencies
    check_ctfd_api_deps
    get_challenges_path

    case "${CONFIG[ACTION]}" in
        all)
            local build_ok=true
            build_challenges || build_ok=false
            [[ "$build_ok" == "false" ]] \
                && log_warning "Some builds failed — continuing with ingestion for successfully built challenges"
            initialize_ctfd_config
            ingest_challenges
            ;;
        build)   build_challenges   ;;
        ingest)  initialize_ctfd_config; ingest_challenges ;;
        sync)    initialize_ctfd_config; sync_challenges    ;;
        status)  show_status        ;;
        cleanup) cleanup_docker     ;;
        *)       error_exit "Unknown action: ${CONFIG[ACTION]}" ;;
    esac

    log_success "Operation completed successfully!"
}

# ── Entry point ──────────────────────────────────────────────────────────────

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    parse_arguments "$@"
    main
fi
