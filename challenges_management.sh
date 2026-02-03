#!/bin/bash

set -euo pipefail  # Exit on error, undefined variables, and pipe failures

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly VERSION="2.0.0"

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_debug() { 
    if [[ "${CONFIG[DEBUG]}" == "true" ]]; then
        echo -e "${PURPLE}[DEBUG]${NC} $*"
    fi
    return 0
}

error_exit() {
    log_error "$1"
    exit "${2:-1}"
}

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
    [BACKUP_BEFORE_SYNC]="false"
    [CONFIG_FILE]=""
    [DEPLOY_COMPOSE]="true"
)

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
    --backup-before-sync    Create backup before syncing challenges
    
DOCKER COMPOSE OPTIONS:
    --no-deploy-compose     Skip docker-compose deployment during ingest
    
DEBUGGING:
    --debug                 Enable debug output
    --skip-docker-check     Skip Docker daemon availability check
    --help                  Show this help message
    --version               Show version information

EXAMPLES:
  # Full setup (build + ingest + deploy compose)
  $SCRIPT_NAME --ctf-repo PolyPwnCTF-2025-challenges
  
  # Build only specific categories
  $SCRIPT_NAME --action build --ctf-repo PolyPwnCTF-2025-challenges --categories "web,crypto"
  
  # Ingest without deploying compose files
  $SCRIPT_NAME --action ingest --ctf-repo PolyPwnCTF-2025-challenges --no-deploy-compose
  
  # Sync existing challenges with force update
  $SCRIPT_NAME --action sync --ctf-repo PolyPwnCTF-2025-challenges --force
  
  # Dry run to see what would happen
  $SCRIPT_NAME --ctf-repo PolyPwnCTF-2025-challenges --dry-run
  
  # Process specific challenges only
  $SCRIPT_NAME --action build --ctf-repo PolyPwnCTF-2025-challenges --challenges "web-challenge-1,crypto-rsa"

CONFIG FILE FORMAT:
  Create a .env file with KEY=VALUE pairs:
    CTF_REPO=PolyPwnCTF-2025-challenges
    WORKING_DIR=/opt/ctf
    PARALLEL_BUILDS=8
    DEPLOY_COMPOSE=true
EOF
}

show_version() {
    echo "$SCRIPT_NAME version $VERSION"
    exit 0
}

load_config_file() {
    local config_file="$1"
    [[ -f "$config_file" ]] || error_exit "Config file not found: $config_file"
    
    log_info "Loading config from: $config_file"
    
    # Source the config file in a subshell to avoid polluting current environment
    while IFS='=' read -r key value; do
        # Skip comments and empty lines
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$key" ]] && continue
        
        # Remove quotes from value
        value="${value%\"}"
        value="${value#\"}"
        value="${value%\'}"
        value="${value#\'}"
        
        # Set config if key exists
        if [[ -n "${CONFIG[$key]:-}" ]]; then
            CONFIG[$key]="$value"
            log_debug "Config loaded: $key=$value"
        fi
    done < <(grep -v '^[[:space:]]*#' "$config_file" | grep -v '^[[:space:]]*$')
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
            --action)
                [[ -n ${2:-} ]] || error_exit "Missing value for --action"
                case "$2" in
                    all|build|ingest|sync|status|cleanup)
                        CONFIG[ACTION]="$2"
                        ;;
                    *)
                        error_exit "Invalid action: $2. Valid actions: all, build, ingest, sync, status, cleanup"
                        ;;
                esac
                shift 2
                ;;
            --categories)
                [[ -n ${2:-} ]] || error_exit "Missing value for --categories"
                CONFIG[CATEGORIES]="$2"
                shift 2
                ;;
            --challenges)
                [[ -n ${2:-} ]] || error_exit "Missing value for --challenges"
                CONFIG[CHALLENGES]="$2"
                shift 2
                ;;
            --parallel-builds)
                [[ -n ${2:-} ]] || error_exit "Missing value for --parallel-builds"
                [[ "$2" =~ ^[0-9]+$ ]] || error_exit "Invalid number for --parallel-builds: $2"
                CONFIG[PARALLEL_BUILDS]="$2"
                shift 2
                ;;
            --config)
                [[ -n ${2:-} ]] || error_exit "Missing value for --config"
                CONFIG[CONFIG_FILE]="$2"
                shift 2
                ;;
            --no-deploy-compose)
                CONFIG[DEPLOY_COMPOSE]="false"
                shift
                ;;
            --dry-run)
                CONFIG[DRY_RUN]="true"
                shift
                ;;
            --force)
                CONFIG[FORCE]="true"
                shift
                ;;
            --debug)
                CONFIG[DEBUG]="true"
                shift
                ;;
            --skip-docker-check)
                CONFIG[SKIP_DOCKER_CHECK]="true"
                shift
                ;;
            --backup-before-sync)
                CONFIG[BACKUP_BEFORE_SYNC]="true"
                shift
                ;;
            --help)
                show_usage
                exit 0
                ;;
            --version)
                show_version
                ;;
            *)
                error_exit "Unknown parameter: $1"
                ;;
        esac
    done
    
    # Load config file if specified
    [[ -n "${CONFIG[CONFIG_FILE]}" ]] && load_config_file "${CONFIG[CONFIG_FILE]}"
    
    # Validate required parameters
    [[ -n "${CONFIG[CTF_REPO]}" ]] || error_exit "Error: --ctf-repo is mandatory and must be specified."
    
    local repo_path="${CONFIG[WORKING_DIR]}/${CONFIG[CTF_REPO]}"
    [[ -d "$repo_path" ]] || error_exit "Error: Couldn't find local challenges repository $repo_path."
}

check_dependencies() {
    log_info "Checking dependencies..."
    
    # Check Docker
    if [[ "${CONFIG[SKIP_DOCKER_CHECK]}" == "false" ]]; then
        log_debug "Checking Docker installation..."
        if ! command -v docker &> /dev/null; then
            error_exit "Docker is not installed or not in PATH"
        fi
        log_debug "Docker binary found"
        
        log_debug "Checking Docker daemon..."
        if ! timeout 10 docker info &> /dev/null; then
            log_warning "Docker daemon is not running or not accessible"
            log_warning "You may need to start Docker or check permissions"
            log_warning "Use --skip-docker-check to bypass this check"
            error_exit "Docker daemon check failed"
        fi
        log_debug "Docker daemon check passed"
    else
        log_info "Skipping Docker daemon check (--skip-docker-check enabled)"
    fi
    
    # Check other tools
    log_debug "Checking system tools..."
    for tool in grep sed awk; do
        if ! command -v "$tool" &> /dev/null; then
            error_exit "$tool is not installed or not available in PATH"
        fi
        log_debug "$tool found"
    done
    
    log_success "All dependencies check passed"
}

ensure_ctfcli_available() {
    export PATH="$HOME/.local/bin:$PATH"
    if command -v ctf &> /dev/null || command -v ctfcli &> /dev/null; then
        return 0
    fi

    log_debug "Attempting to make ctfcli available in current session..."
    if [[ -f "$HOME/.bashrc" ]]; then
        if grep -q "pipx" "$HOME/.bashrc" 2>/dev/null; then
            eval "$(grep -A 2 'Created by .pipx' "$HOME/.bashrc" 2>/dev/null | grep export || true)"
        fi
    fi
    if command -v ctf &> /dev/null || command -v ctfcli &> /dev/null; then
        return 0
    fi

    if [[ -x "$HOME/.local/bin/ctfcli" ]]; then
        log_info "Creating temporary command wrappers for this session..."
        ctfcli() { "$HOME/.local/bin/ctfcli" "$@"; }
        ctf() { "$HOME/.local/bin/ctfcli" "$@"; }
        export -f ctfcli 2>/dev/null || true
        export -f ctf 2>/dev/null || true
        return 0
    fi
    
    return 1
}

install_ctfcli() {
    export PATH="$HOME/.local/bin:$PATH"
    
    if ! command -v ctfcli &> /dev/null && ! command -v ctf &> /dev/null; then
        log_info "CTFcli is not installed. Installing CTFcli..."
        if [[ "${CONFIG[DRY_RUN]}" == "false" ]]; then
            # Check if pipx is available
            if ! command -v pipx &> /dev/null; then
                error_exit "pipx is not installed. Please install pipx first: python3 -m pip install --user pipx"
            fi
            
            # Try to install, but handle the case where it's already installed
            local install_output
            if install_output=$(pipx install ctfcli 2>&1); then
                log_success "CTFcli installed successfully"
                pipx ensurepath --force > /dev/null 2>&1 || true
                export PATH="$HOME/.local/bin:$PATH"
            elif echo "$install_output" | grep -q "already seems to be installed"; then
                log_info "CTFcli is already installed via pipx"
                if ! ensure_ctfcli_available; then
                    log_warning "CTFcli is installed but not accessible in current shell"
                    log_info "Please restart your shell or run: source ~/.bashrc"
                    log_info "Alternatively, add this to your shell config: export PATH=\"\$HOME/.local/bin:\$PATH\""
                    error_exit "CTFcli installation found but not accessible"
                fi
            else
                log_error "Failed to install CTFcli: $install_output"
                error_exit "CTFcli installation failed"
            fi
            
            ensure_ctfcli_available
        else
            echo "Would install: pipx install ctfcli"
        fi
    else
        log_success "CTFcli is already installed and available"
        # Check version
        local version
        if command -v ctfcli &> /dev/null; then
            version=$(ctfcli --version 2>/dev/null | head -n1 || echo "unknown")
        elif command -v ctf &> /dev/null; then
            version=$(ctf --version 2>/dev/null | head -n1 || echo "unknown")
        else
            version="unknown"
        fi
        log_debug "CTFcli version: $version"
    fi
}

get_challenges_path() {
    local repo_path="${CONFIG[WORKING_DIR]}/${CONFIG[CTF_REPO]}"
    local complete_path="$repo_path"
    
    if [[ -d "$repo_path/challenges" ]]; then
        complete_path="$repo_path/challenges"
    fi
    
    CONFIG[CHALLENGE_PATH]="$complete_path"
    log_info "Challenge path: '$complete_path'"
}

should_process_challenge() {
    local category="$1"
    local challenge="$2"
    local category_name
    local challenge_name
    
    category_name=$(basename "$category")
    challenge_name=$(basename "$challenge")
    
    # Check category filter
    if [[ -n "${CONFIG[CATEGORIES]}" ]]; then
        local categories_array
        IFS=',' read -ra categories_array <<< "${CONFIG[CATEGORIES]}"
        local found=false
        for cat in "${categories_array[@]}"; do
            [[ "$category_name" == "$cat" ]] && found=true && break
        done
        [[ "$found" == "false" ]] && return 1
    fi
    
    # Check challenge filter
    if [[ -n "${CONFIG[CHALLENGES]}" ]]; then
        local challenges_array
        IFS=',' read -ra challenges_array <<< "${CONFIG[CHALLENGES]}"
        local found=false
        for chall in "${challenges_array[@]}"; do
            [[ "$challenge_name" == "$chall" ]] && found=true && break
        done
        [[ "$found" == "false" ]] && return 1
    fi
    
    return 0
}

get_challenge_info() {
    local challenge_yml="$1"
    local info_type="$2"
    
    case "$info_type" in
        "type")
            grep '^type:' "$challenge_yml" 2>/dev/null | sed -E 's/^type:[[:space:]]*//' | tr -d '"'
            ;;
        "docker_image")
            grep '^[[:space:]]*docker_image:' "$challenge_yml" 2>/dev/null | sed -E 's/^[[:space:]]*docker_image:[[:space:]]*//' | tr -d '"'
            ;;
        "name")
            grep '^name:' "$challenge_yml" 2>/dev/null | sed -E 's/^name:[[:space:]]*//' | tr -d '"'
            ;;
        "requirements")
            # Extract requirements field - supports both single value and list format
            # Format: requirements: challenge-name
            # Or:     requirements: [challenge1, challenge2]
            local req_line
            req_line=$(grep '^requirements:' "$challenge_yml" 2>/dev/null | sed -E 's/^requirements:[[:space:]]*//')
            if [[ -n "$req_line" ]]; then
                # Remove brackets and quotes, split by comma
                echo "$req_line" | tr -d '[]"' | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$'
            fi
            ;;
    esac
}

get_challenge_requirements() {
    local challenge_path="$1"
    local challenge_yml="$challenge_path/challenge.yml"
    
    [[ -f "$challenge_yml" ]] || return 0
    
    get_challenge_info "$challenge_yml" "requirements"
}

deploy_single_compose() {
    local challenge_path="$1"
    local challenge_name
    local compose_file
    
    challenge_name=$(basename "$challenge_path")
    compose_file="$challenge_path/docker-compose.yml"
    
    [[ -f "$compose_file" ]] || {
        log_debug "No docker-compose.yml found for: $challenge_name"
        return 0
    }
    
    log_info "Deploying docker-compose for challenge: $challenge_name"
    log_debug "Compose file: $compose_file"
    
    if [[ "${CONFIG[DRY_RUN]}" == "false" ]]; then
        
        # Deploy the compose stack
        local compose_output
        local exit_code
        
        if command -v docker-compose &> /dev/null; then
            compose_output=$(cd $challenge_path && docker-compose up -d 2>&1)
            exit_code=$?
        else
            compose_output=$(cd $challenge_path && docker compose up -d 2>&1)
            exit_code=$?
        fi
        
        if [[ $exit_code -eq 0 ]]; then
            log_success "Successfully deployed compose stack: $challenge_name"
            log_debug "Compose output: $compose_output"
            return 0
        else
            log_error "Failed to deploy compose stack: $challenge_name"
            log_error "Error output: $compose_output"
            return 1
        fi
    else
        if command -v docker-compose &> /dev/null; then
            echo "Would deploy: docker-compose -f "$compose_file" up -d"
        else
            echo "Would deploy: docker compose -f "$compose_file" up -d"
        fi
        return 0
    fi
}

build_single_challenge() {
    local category="$1"
    local challenge="$2"
    local challenge_name
    local challenge_yml
    local docker_image
    local dockerfile_name=""
    
    challenge_name=$(basename "$challenge")
    challenge_yml="$category/$challenge_name/challenge.yml"
    
    [[ -f "$challenge_yml" ]] || {
        log_warning "No challenge.yml found for: $challenge_name"
        return 1
    }
    
    local challenge_type
    challenge_type=$(get_challenge_info "$challenge_yml" "type")
    
    [[ "$challenge_type" == "docker" ]] || {
        log_debug "Skipping non-docker challenge: $challenge_name (type: $challenge_type)"
        return 0
    }
    
    docker_image=$(get_challenge_info "$challenge_yml" "docker_image")
    [[ -n "$docker_image" ]] || {
        log_error "No docker_image specified in challenge.yml for: $challenge_name"
        return 1
    }
    
    # Find Dockerfile
    for dockerfile in "$category/$challenge_name"/[Dd]ockerfile*; do
        if [[ -f "$dockerfile" ]]; then
            dockerfile_name=$(basename "$dockerfile")
            break
        fi
    done
    
    [[ -n "$dockerfile_name" ]] || {
        log_error "No Dockerfile found for challenge: $challenge_name"
        return 1
    }
    
    log_info "Building Challenge: $challenge_name -> $docker_image"
    
    if [[ "${CONFIG[DRY_RUN]}" == "false" ]]; then
        local build_args=""
        
        # Check if we should force rebuild
        if [[ "${CONFIG[FORCE]}" == "true" ]]; then
            build_args="--no-cache"
        fi
        
        (cd "$category/$challenge_name" && docker build $build_args . -t "$docker_image" -f "$dockerfile_name") || {
            log_error "Failed to build $challenge_name"
            return 1
        }
        
        log_success "Built: $docker_image"
    else
        echo "Would build: docker build . -t '$docker_image' -f '$dockerfile_name'"
    fi
    
    return 0
}

build_single_challenge_quiet() {
    local category="$1"
    local challenge="$2"
    local log_file="$3"
    local challenge_name
    local challenge_yml
    local docker_image
    local dockerfile_name=""
    
    challenge_name=$(basename "$challenge")
    challenge_yml="$category/$challenge_name/challenge.yml"
    
    [[ -f "$challenge_yml" ]] || {
        echo "No challenge.yml found for: $challenge_name" >> "$log_file"
        return 1
    }
    
    local challenge_type
    challenge_type=$(get_challenge_info "$challenge_yml" "type")
    
    [[ "$challenge_type" == "docker" ]] || {
        echo "Skipping non-docker challenge: $challenge_name (type: $challenge_type)" >> "$log_file"
        return 0
    }
    
    docker_image=$(get_challenge_info "$challenge_yml" "docker_image")
    [[ -n "$docker_image" ]] || {
        echo "No docker_image specified in challenge.yml for: $challenge_name" >> "$log_file"
        return 1
    }
    
    # Find Dockerfile
    for dockerfile in "$category/$challenge_name"/[Dd]ockerfile*; do
        if [[ -f "$dockerfile" ]]; then
            dockerfile_name=$(basename "$dockerfile")
            break
        fi
    done
    
    [[ -n "$dockerfile_name" ]] || {
        echo "No Dockerfile found for challenge: $challenge_name" >> "$log_file"
        return 1
    }
    
    # Build with suppressed output
    local build_args=""
    
    # Check if we should force rebuild
    if [[ "${CONFIG[FORCE]}" == "true" ]]; then
        build_args="--no-cache"
    fi
    
    # Redirect all output to log file and /dev/null to keep console clean
    if (cd "$category/$challenge_name" && docker build $build_args . -t "$docker_image" -f "$dockerfile_name" >> "$log_file" 2>&1); then
        # Clean up temp log file on success
        rm -f "$log_file"
        return 0
    else
        echo "Failed to build $challenge_name. Check $log_file for details." >> "$log_file"
        return 1
    fi
}

build_challenges() {
    local total_challenges=0
    local successful_builds=0
    local failed_builds=0
    local failed_challenges=()
    local challenges_to_build=()
    
    log_info "Discovering Docker challenges..."
    
    # Collect challenges to build
    for category in "${CONFIG[CHALLENGE_PATH]}"/*; do
        [[ -d "$category" ]] || continue
        for challenge in "$category"/*; do
            [[ -d "$challenge" ]] || continue
            should_process_challenge "$category" "$challenge" || continue
            
            local challenge_name
            local challenge_yml
            challenge_name=$(basename "$challenge")
            challenge_yml="$category/$challenge_name/challenge.yml"
            
            if [[ -f "$challenge_yml" ]]; then
                local challenge_type
                challenge_type=$(get_challenge_info "$challenge_yml" "type")
                if [[ "$challenge_type" == "docker" ]]; then
                    challenges_to_build+=("$category:$challenge")
                    total_challenges=$((total_challenges + 1))
                fi
            fi
        done
    done
    
    log_info "Found $total_challenges Docker challenges to build"
    [[ $total_challenges -eq 0 ]] && { log_info "No Docker challenges to build"; return 0; }
    
    # Build challenges (with optional parallelization)
    local current=0
    local pids=()
    local max_parallel="${CONFIG[PARALLEL_BUILDS]}"
    
    for challenge_info in "${challenges_to_build[@]}"; do
        IFS=':' read -r category challenge <<< "$challenge_info"
        current=$((current + 1))
        
        log_info "[$current/$total_challenges] Starting build for $(basename "$challenge")"
        
        if [[ "${CONFIG[DRY_RUN]}" == "false" && $max_parallel -gt 1 ]]; then
            # Parallel execution with suppressed output for readability
            {
                # Suppress docker build output in parallel mode
                local challenge_name_base
                challenge_name_base=$(basename "$challenge")
                
                # Create a temporary log file for this build
                local temp_log="/tmp/ctf_build_${challenge_name_base}_$.log"
                
                if build_single_challenge_quiet "$category" "$challenge" "$temp_log"; then
                    log_success "Image $challenge_name_base successfully built"
                    exit 0
                else
                    log_error "Docker build failed for image $challenge_name_base. Check $temp_log file for more information"
                    exit 1
                fi
            } &
            pids+=($!)
            
            # Wait if we've reached max parallel builds
            if [[ ${#pids[@]} -ge $max_parallel ]]; then
                for pid in "${pids[@]}"; do
                    if wait "$pid"; then
                        successful_builds=$((successful_builds + 1))
                    else
                        failed_builds=$((failed_builds + 1))
                        failed_challenges+=("$(basename "$challenge")")
                    fi
                done
                pids=()
            fi
        else
            # Sequential execution
            if build_single_challenge "$category" "$challenge"; then
                successful_builds=$((successful_builds + 1))
            else
                failed_challenges+=("$(basename "$challenge")")
                failed_builds=$((failed_builds + 1))
            fi
        fi
    done
    
    # Wait for remaining parallel jobs
    if [[ "${CONFIG[DRY_RUN]}" == "false" && $max_parallel -gt 1 ]]; then
        for pid in "${pids[@]}"; do
            if wait "$pid"; then
                successful_builds=$((successful_builds + 1))
            else
                failed_builds=$((failed_builds + 1))
            fi
        done
        
        # Clean up any remaining temp log files
        rm -f /tmp/ctf_build_*_$.log 2>/dev/null || true
    fi
    
    # Summary
    log_info "Build summary:"
    log_success "Successfully built: $successful_builds/$total_challenges challenges"
    
    if [[ $failed_builds -gt 0 ]]; then
        log_warning "Failed to build: $failed_builds/$total_challenges challenges"
        if [[ ${#failed_challenges[@]} -gt 0 ]]; then
            log_warning "Failed challenges:"
            printf '%s\n' "${failed_challenges[@]}" | sed 's/^/  - /'
        fi
    fi
    
    return $([[ $failed_builds -eq 0 ]] && echo 0 || echo 1)
}

initialize_ctfcli() {
    ensure_ctfcli_available
    
    if [[ ! -f "${CONFIG[WORKING_DIR]}/.ctf/config" ]]; then
        log_info "CTFcli is not initialized. Initializing CTFcli..."
        if [[ "${CONFIG[DRY_RUN]}" == "false" ]]; then
            local init_cmd="ctf"
            if ! command -v ctf &> /dev/null; then
                init_cmd="ctfcli"
            fi
            
            if $init_cmd init; then
                log_success "CTFcli initialized successfully"
            else
                error_exit "Failed to initialize CTFcli"
            fi
        else
            echo "Would initialize: ctf init"
        fi
    else
        log_info "CTFcli is already initialized"
    fi
}

topological_sort_challenges() {
    local -n challenges_array=$1
    local -n requirements_map=$2
    local -n sorted_result=$3
    
    declare -A in_degree
    declare -A adjacency_list
    local queue=()
    
    for challenge_path in "${challenges_array[@]}"; do
        local challenge_name
        challenge_name=$(basename "$challenge_path")
        in_degree["$challenge_name"]=0
    done
    
    for challenge_path in "${challenges_array[@]}"; do
        local challenge_name
        challenge_name=$(basename "$challenge_path")
        
        if [[ -n "${requirements_map[$challenge_name]:-}" ]]; then
            while IFS= read -r req; do
                [[ -z "$req" ]] && continue
                
                if [[ -z "${adjacency_list[$req]:-}" ]]; then
                    adjacency_list["$req"]="$challenge_name"
                else
                    adjacency_list["$req"]="${adjacency_list[$req]} $challenge_name"
                fi
                
                in_degree["$challenge_name"]=$((${in_degree[$challenge_name]:-0} + 1))
            done <<< "${requirements_map[$challenge_name]}"
        fi
    done
    
    for challenge_path in "${challenges_array[@]}"; do
        local challenge_name
        challenge_name=$(basename "$challenge_path")
        
        if [[ ${in_degree[$challenge_name]:-0} -eq 0 ]]; then
            queue+=("$challenge_path")
        fi
    done
    
    while [[ ${#queue[@]} -gt 0 ]]; do
        local current_path="${queue[0]}"
        queue=("${queue[@]:1}")
        sorted_result+=("$current_path")
        
        local current_name
        current_name=$(basename "$current_path")
        
        if [[ -n "${adjacency_list[$current_name]:-}" ]]; then
            for dependent in ${adjacency_list[$current_name]}; do
                in_degree["$dependent"]=$((${in_degree[$dependent]} - 1))
                
                if [[ ${in_degree[$dependent]} -eq 0 ]]; then
                    for challenge_path in "${challenges_array[@]}"; do
                        if [[ "$(basename "$challenge_path")" == "$dependent" ]]; then
                            queue+=("$challenge_path")
                            break
                        fi
                    done
                fi
            done
        fi
    done
    
    if [[ ${#sorted_result[@]} -ne ${#challenges_array[@]} ]]; then
        log_warning "Circular dependency detected! Some challenges cannot be ordered."
        for challenge_path in "${challenges_array[@]}"; do
            local found=false
            for sorted_path in "${sorted_result[@]}"; do
                if [[ "$challenge_path" == "$sorted_path" ]]; then
                    found=true
                    break
                fi
            done
            if [[ "$found" == "false" ]]; then
                sorted_result+=("$challenge_path")
            fi
        done
    fi
}

ingest_challenges() {
    local successful_installs=0
    local failed_installs=0
    local skipped_installs=0
    local failed_challenges=()
    local skipped_challenges=()
    local total_challenges=0
    local challenges_to_ingest=()
    
    declare -A successfully_ingested    # Track successfully ingested challenges
    declare -A failed_to_ingest        # Track failed challenges
    declare -A compose_deployment_status # Track docker-compose deployment status
    declare -A challenge_requirements   # Map challenge -> requirements
    
    log_info "Discovering challenges to ingest..."
    log_debug "Scanning directory: ${CONFIG[CHALLENGE_PATH]}"
    
    # Collect challenges to ingest with better error handling
    for category in "${CONFIG[CHALLENGE_PATH]}"/*; do
        [[ -d "$category" ]] || continue
        log_debug "Processing category: $(basename "$category")"
        
        for challenge in "$category"/*; do
            [[ -d "$challenge" ]] || continue
            
            local challenge_name
            challenge_name=$(basename "$challenge")
            log_debug "Checking challenge: $challenge_name"
            
            # Apply filters
            if ! should_process_challenge "$category" "$challenge"; then
                log_debug "Skipping challenge $challenge_name due to filters"
                continue
            fi
            
            local challenge_yml="$category/$challenge_name/challenge.yml"
            
            if [[ -f "$challenge_yml" ]]; then
                log_debug "Found challenge.yml for: $challenge_name"
                challenges_to_ingest+=("$category/$challenge_name")
                total_challenges=$((total_challenges + 1))
                
                local reqs
                reqs=$(get_challenge_requirements "$category/$challenge_name")
                if [[ -n "$reqs" ]]; then
                    challenge_requirements["$challenge_name"]="$reqs"
                    log_debug "Challenge $challenge_name has requirements: $reqs"
                fi
            else
                log_debug "No challenge.yml found for: $challenge_name"
            fi
        done
    done
    
    log_info "Found $total_challenges challenges to ingest"
    [[ $total_challenges -eq 0 ]] && { 
        log_warning "No challenges found to ingest"
        return 0
    }
    
    local has_dependencies=false
    for challenge_name in "${!challenge_requirements[@]}"; do
        has_dependencies=true
        break
    done
    
    if [[ "$has_dependencies" == "true" ]]; then
        log_info "Challenge dependency tree:"
        for challenge_path in "${challenges_to_ingest[@]}"; do
            local challenge_name
            challenge_name=$(basename "$challenge_path")
            if [[ -n "${challenge_requirements[$challenge_name]:-}" ]]; then
                echo "  $challenge_name requires:"
                echo "${challenge_requirements[$challenge_name]}" | while read -r req; do
                    [[ -n "$req" ]] && echo "    - $req"
                done
            fi
        done
        
        log_info "Sorting challenges by dependency order..."
        local sorted_challenges=()
        topological_sort_challenges challenges_to_ingest challenge_requirements sorted_challenges
        
        if [[ ${#sorted_challenges[@]} -eq ${#challenges_to_ingest[@]} ]]; then
            challenges_to_ingest=("${sorted_challenges[@]}")
            log_success "Challenges sorted in dependency order"
        else
            log_warning "Could not fully sort challenges (possible circular dependency)"
            challenges_to_ingest=("${sorted_challenges[@]}")
        fi
    fi
    
    # Phase 1: Deploy all docker-compose files first if enabled
    if [[ "${CONFIG[DEPLOY_COMPOSE]}" == "true" ]]; then
        log_info "=== Phase 1: Deploying Docker Compose stacks ==="
        
        local compose_count=0
        for challenge_path in "${challenges_to_ingest[@]}"; do
            if [[ -f "$challenge_path/docker-compose.yml" ]]; then
                compose_count=$((compose_count + 1))
            fi
        done
        
        if [[ $compose_count -gt 0 ]]; then
            log_info "Found $compose_count challenges with docker-compose.yml files"
            
            local deployed_count=0
            local failed_compose_count=0
            
            for challenge_path in "${challenges_to_ingest[@]}"; do
                local challenge_name
                challenge_name=$(basename "$challenge_path")
                
                if [[ -f "$challenge_path/docker-compose.yml" ]]; then
                    log_info "Deploying compose for: $challenge_name"
                    
                    if [[ "${CONFIG[DRY_RUN]}" == "false" ]]; then
                        if deploy_single_compose "$challenge_path"; then
                            compose_deployment_status["$challenge_name"]="success"
                            deployed_count=$((deployed_count + 1))
                        else
                            compose_deployment_status["$challenge_name"]="failed"
                            failed_compose_count=$((failed_compose_count + 1))
                            log_error "Docker compose deployment failed for: $challenge_name"
                            log_warning "Will skip ingestion of $challenge_name and any challenges that depend on it"
                        fi
                    else
                        echo "Would deploy docker-compose for: $challenge_name"
                        compose_deployment_status["$challenge_name"]="success"
                        deployed_count=$((deployed_count + 1))
                    fi
                fi
            done
            
            log_info "Compose deployment summary: $deployed_count successful, $failed_compose_count failed"
        else
            log_info "No docker-compose.yml files found, skipping compose deployment phase"
        fi
    fi
    
    # Confirmation prompt
    if [[ "${CONFIG[DRY_RUN]}" == "false" ]]; then
        echo
        log_info "Ready to ingest $total_challenges challenges."
        log_warning "Make sure all Docker images have been added to the CTFd Docker Plugin first."
        read -p "Press Enter to continue with ingesting challenges, or Ctrl+C to abort..."
    fi
    
    # Phase 2: Ingest challenges with dependency checking
    log_info "=== Phase 2: Ingesting challenges ==="
    set +e
    
    local current=0
    for challenge_path in "${challenges_to_ingest[@]}"; do
        local challenge_name
        challenge_name=$(basename "$challenge_path")
        current=$((current + 1))
        
        log_info "[$current/$total_challenges] Processing $challenge_name..."
        
        if [[ "${compose_deployment_status[$challenge_name]:-}" == "failed" ]]; then
            log_error "Skipping $challenge_name: Docker compose deployment failed"
            failed_challenges+=("$challenge_name (compose deployment failed)")
            failed_installs=$((failed_installs + 1))
            failed_to_ingest["$challenge_name"]="compose_failed"
            continue
        fi
        
        local can_ingest=true
        local missing_requirements=()
        
        if [[ -n "${challenge_requirements[$challenge_name]:-}" ]]; then
            log_debug "Checking requirements for $challenge_name"
            
            while IFS= read -r req; do
                [[ -z "$req" ]] && continue
                
                log_debug "  Checking requirement: $req"
                
                # Check if requirement was successfully ingested
                if [[ -z "${successfully_ingested[$req]:-}" ]]; then
                    # Check if requirement failed to ingest
                    if [[ -n "${failed_to_ingest[$req]:-}" ]]; then
                        log_warning "  Requirement '$req' failed to ingest (${failed_to_ingest[$req]})"
                        missing_requirements+=("$req")
                        can_ingest=false
                    else
                        # Check if requirement exists in the list to be ingested
                        local req_found=false
                        for check_path in "${challenges_to_ingest[@]}"; do
                            if [[ "$(basename "$check_path")" == "$req" ]]; then
                                req_found=true
                                break
                            fi
                        done
                        
                        if [[ "$req_found" == "false" ]]; then
                            log_warning "  Requirement '$req' not found in challenges to ingest"
                            missing_requirements+=("$req")
                            can_ingest=false
                        else
                            log_warning "  Requirement '$req' has not been ingested yet (will be processed later)"
                            missing_requirements+=("$req")
                            can_ingest=false
                        fi
                    fi
                else
                    log_debug "  Requirement '$req' is satisfied"
                fi
            done <<< "${challenge_requirements[$challenge_name]}"
        fi
        
        # Skip if requirements are not met
        if [[ "$can_ingest" == "false" ]]; then
            log_error "Skipping $challenge_name: Missing requirements: ${missing_requirements[*]}"
            skipped_challenges+=("$challenge_name (missing: ${missing_requirements[*]})")
            skipped_installs=$((skipped_installs + 1))
            failed_to_ingest["$challenge_name"]="missing_requirements"
            continue
        fi
        
        # Attempt to install the challenge
        log_info "Installing $challenge_name..."
        
        if [[ "${CONFIG[DRY_RUN]}" == "false" ]]; then
            local install_output
            local exit_code
            
            local ctf_cmd="ctf"
            if ! command -v ctf &> /dev/null; then
                ctf_cmd="ctfcli"
            fi
            
            install_output=$($ctf_cmd challenge install "$challenge_path" 2>&1)
            exit_code=$?
            
            if [[ $exit_code -eq 0 ]]; then
                log_success "Successfully installed: $challenge_name"
                successful_installs=$((successful_installs + 1))
                successfully_ingested["$challenge_name"]="true"
            else
                # Check for specific error patterns
                if echo "$install_output" | grep -q "Found already existing challenge with the same name"; then
                    log_warning "Challenge already exists: $challenge_name (use --action sync to update)"
                    skipped_challenges+=("$challenge_name (already exists)")
                    skipped_installs=$((skipped_installs + 1))
                    # Consider already existing challenges as successfully ingested for dependency purposes
                    successfully_ingested["$challenge_name"]="true"
                elif echo "$install_output" | grep -q "could not be loaded"; then
                    log_error "Failed to install: $challenge_name"
                    local file_error
                    file_error=$(echo "$install_output" | grep "could not be loaded" | head -n1)
                    log_error "  File error: $file_error"
                    failed_challenges+=("$challenge_name (file load error)")
                    failed_installs=$((failed_installs + 1))
                    failed_to_ingest["$challenge_name"]="file_error"
                else
                    log_error "Failed to install: $challenge_name"
                    # Extract the most relevant error line
                    local error_line
                    error_line=$(echo "$install_output" | grep -E "(Error|Failed|Exception)" | head -n1)
                    if [[ -n "$error_line" ]]; then
                        log_error "  $error_line"
                    else
                        # Show the last non-empty line as fallback
                        error_line=$(echo "$install_output" | grep -v "^$" | tail -n1)
                        [[ -n "$error_line" ]] && log_error "  $error_line"
                    fi
                    
                    # Only show full debug output if debug mode is enabled
                    log_debug "Full error output: $install_output"
                    
                    failed_challenges+=("$challenge_name")
                    failed_installs=$((failed_installs + 1))
                    failed_to_ingest["$challenge_name"]="install_error"
                fi
            fi
        else
            echo "Would install: ctf challenge install '$challenge_path'"
            successful_installs=$((successful_installs + 1))
            successfully_ingested["$challenge_name"]="true"
        fi
    done
    
    # Re-enable exit on error
    set -e
    
    # Summary report
    echo
    log_info "========================================="
    log_info "Challenge Ingestion Summary"
    log_info "========================================="
    log_success "Successfully installed: $successful_installs/$total_challenges challenges"
    
    if [[ $skipped_installs -gt 0 ]]; then
        log_warning "Skipped: $skipped_installs/$total_challenges challenges"
        if [[ ${#skipped_challenges[@]} -gt 0 ]]; then
            log_info "Skipped challenges:"
            printf '%s\n' "${skipped_challenges[@]}" | sed 's/^/  - /'
        fi
    fi
    
    if [[ $failed_installs -gt 0 ]]; then
        log_error "Failed to install: $failed_installs/$total_challenges challenges"
        if [[ ${#failed_challenges[@]} -gt 0 ]]; then
            log_error "Failed challenges:"
            printf '%s\n' "${failed_challenges[@]}" | sed 's/^/  - /'
        fi
    fi
    
    # Show dependency impact summary
    if [[ "$has_dependencies" == "true" ]]; then
        echo
        log_info "Dependency Impact Analysis:"
        local blocked_count=0
        for challenge_name in "${!failed_to_ingest[@]}"; do
            if [[ "${failed_to_ingest[$challenge_name]}" == "missing_requirements" ]]; then
                blocked_count=$((blocked_count + 1))
            fi
        done
        
        if [[ $blocked_count -gt 0 ]]; then
            log_warning "$blocked_count challenge(s) were blocked due to unmet dependencies"
        else
            log_success "No challenges were blocked by dependencies"
        fi
    fi
    
    echo
    if [[ $failed_installs -eq 0 && $skipped_installs -eq 0 ]]; then
        log_success "All challenges have been ingested successfully!"
    elif [[ $failed_installs -eq 0 ]]; then
        log_success "All new challenges have been ingested successfully!"
    fi
    
    return $([[ $failed_installs -eq 0 ]] && echo 0 || echo 1)
}

sync_challenges() {
    log_info "Syncing existing challenges..."
    
    if [[ "${CONFIG[BACKUP_BEFORE_SYNC]}" == "true" ]]; then
        log_info "Creating backup before sync..."
        if [[ "${CONFIG[DRY_RUN]}" == "false" ]]; then
            local ctf_cmd="ctf"
            if ! command -v ctf &> /dev/null; then
                ctf_cmd="ctfcli"
            fi
            $ctf_cmd challenge backup --output "backup-$(date +%Y%m%d-%H%M%S).zip" || log_warning "Backup failed"
        else
            echo "Would create backup: ctfcli challenge backup --output 'backup-$(date +%Y%m%d-%H%M%S).zip'"
        fi
    fi
    
    local sync_args=""
    [[ "${CONFIG[FORCE]}" == "true" ]] && sync_args="--force"
    
    local total_synced=0
    local failed_syncs=0
    local failed_challenges=()
    
    # Collect challenges to sync
    local challenges_to_sync=()
    for category in "${CONFIG[CHALLENGE_PATH]}"/*; do
        [[ -d "$category" ]] || continue
        log_debug "Processing category: $(basename "$category")"
        
        for challenge in "$category"/*; do
            [[ -d "$challenge" ]] || continue
            
            local challenge_name
            challenge_name=$(basename "$challenge")
            log_debug "Checking challenge: $challenge_name"
            
            # Apply filters
            if ! should_process_challenge "$category" "$challenge"; then
                log_debug "Skipping challenge $challenge_name due to filters"
                continue
            fi
            
            local challenge_yml="$category/$challenge_name/challenge.yml"
            
            if [[ -f "$challenge_yml" ]]; then
                log_debug "Found challenge.yml for: $challenge_name"
                challenges_to_sync+=("$category/$challenge_name")
            else
                log_debug "No challenge.yml found for: $challenge_name"
            fi
        done
    done
    
    log_info "Found ${#challenges_to_sync[@]} challenges to sync"
    
    if [[ ${#challenges_to_sync[@]} -eq 0 ]]; then
        log_warning "No challenges found to sync"
        return 0
    fi
    
    # Temporarily disable exit on error for this function
    set +e
    
    local current=0
    # Sync each challenge individually
    for challenge_path in "${challenges_to_sync[@]}"; do
        local challenge_name
        challenge_name=$(basename "$challenge_path")
        
        current=$((current + 1))
        log_info "[$current/${#challenges_to_sync[@]}] Syncing challenge: $challenge_name"
        
        if [[ "${CONFIG[DRY_RUN]}" == "false" ]]; then
            local sync_output
            local exit_code
            
            local ctf_cmd="ctf"
            if ! command -v ctf &> /dev/null; then
                ctf_cmd="ctfcli"
            fi
            
            sync_output=$($ctf_cmd challenge sync $sync_args "$challenge_path" 2>&1)
            exit_code=$?
            
            if [[ $exit_code -eq 0 ]]; then
                log_success "Successfully synced: $challenge_name"
                total_synced=$((total_synced + 1))
                
                # Deploy docker-compose.yml if enabled and present
                if [[ "${CONFIG[DEPLOY_COMPOSE]}" == "true" ]]; then
                    if [[ -f "$challenge_path/docker-compose.yml" ]]; then
                        if deploy_single_compose "$challenge_path"; then
                            log_debug "Docker Compose deployed for: $challenge_name"
                        else
                            log_warning "Failed to deploy docker-compose for: $challenge_name"
                        fi
                    fi
                fi
            else
                log_error "Failed to sync: $challenge_name"
                log_debug "Error output: $sync_output"
                failed_challenges+=("$challenge_name")
                failed_syncs=$((failed_syncs + 1))
            fi
        else
            echo "Would sync: ctfcli challenge sync $sync_args '$challenge_path'"
            if [[ "${CONFIG[DEPLOY_COMPOSE]}" == "true" && -f "$challenge_path/docker-compose.yml" ]]; then
                echo "Would deploy docker-compose for: $challenge_name"
            fi
            total_synced=$((total_synced + 1))
        fi
    done
    
    # Re-enable exit on error
    set -e
    
    # Summary report
    log_info "Challenge sync summary:"
    log_success "Successfully synced: $total_synced/${#challenges_to_sync[@]} challenges"
    
    if [[ $failed_syncs -gt 0 ]]; then
        log_warning "Failed to sync: $failed_syncs/${#challenges_to_sync[@]} challenges"
        log_warning "Failed challenges:"
        printf '%s\n' "${failed_challenges[@]}" | sed 's/^/  - /'
        return 1
    else
        log_success "All challenges have been synced successfully!"
        return 0
    fi
}

show_status() {
    log_info "CTF Challenge Status Report"
    echo "=========================="
    
    # Environment info
    echo -e "${CYAN}Environment:${NC}"
    echo "  Working Directory: ${CONFIG[WORKING_DIR]}"
    echo "  CTF Repository: ${CONFIG[CTF_REPO]}"
    echo "  Challenge Path: ${CONFIG[CHALLENGE_PATH]}"
    echo "  Deploy Compose: ${CONFIG[DEPLOY_COMPOSE]}"
    echo
    
    # Challenge statistics
    local total_challenges=0
    local docker_challenges=0
    local static_challenges=0
    local compose_challenges=0
    local categories=()
    
    for category in "${CONFIG[CHALLENGE_PATH]}"/*; do
        [[ -d "$category" ]] || continue
        local category_name
        category_name=$(basename "$category")
        categories+=("$category_name")
        
        local category_count=0
        for challenge in "$category"/*; do
            [[ -d "$challenge" ]] || continue
            local challenge_name
            challenge_name=$(basename "$challenge")
            local challenge_yml="$category/$challenge_name/challenge.yml"
            local compose_file="$category/$challenge_name/docker-compose.yml"
            
            if [[ -f "$challenge_yml" ]]; then
                total_challenges=$((total_challenges + 1))
                category_count=$((category_count + 1))
                local challenge_type
                challenge_type=$(get_challenge_info "$challenge_yml" "type")
                case "$challenge_type" in
                    "docker") docker_challenges=$((docker_challenges + 1)) ;;
                    *) static_challenges=$((static_challenges + 1)) ;;
                esac
                
                # Check for docker-compose.yml
                if [[ -f "$compose_file" ]]; then
                    compose_challenges=$((compose_challenges + 1))
                fi
            fi
        done
        echo "  $category_name: $category_count challenges"
    done
    
    echo
    echo -e "${CYAN}Challenge Statistics:${NC}"
    echo "  Total Challenges: $total_challenges"
    echo "  Docker Challenges: $docker_challenges"
    echo "  Static Challenges: $static_challenges"
    echo "  Compose Challenges: $compose_challenges"
    echo "  Categories: ${#categories[@]} (${categories[*]})"
    echo
    
    # CTFcli status
    if command -v ctfcli &> /dev/null; then
        echo -e "${CYAN}CTFcli Status:${NC}"
        local ctfcli_version
        ctfcli_version=$(ctfcli --version 2>/dev/null | head -n1 || echo "unknown")
        echo "  Version: $ctfcli_version"
        
        if [[ -f ".ctf/config" ]]; then
            echo "  Configuration: Found"
        else
            echo "  Configuration: Not found (run 'ctfcli init' first)"
        fi
    else
        echo -e "${YELLOW}CTFcli: Not installed${NC}"
    fi

    # Show running compose services
    if [[ $compose_challenges -gt 0 ]] && ([[ "${CONFIG[DRY_RUN]}" == "false" ]]); then
        echo
        echo -e "${CYAN}Running Compose Services:${NC}"
        local running_services=0
        for category in "${CONFIG[CHALLENGE_PATH]}"/*; do
            [[ -d "$category" ]] || continue
            for challenge in "$category"/*; do
                [[ -d "$challenge" ]] || continue
                local challenge_name
                challenge_name=$(basename "$challenge")
                local compose_file="$category/$challenge_name/docker-compose.yml"
                
                if [[ -f "$compose_file" ]]; then
                    local project_name
                    
                    # Check if services are running
                    local running_containers
                    if command -v docker-compose &> /dev/null; then
                        running_containers=$(docker-compose -f "$compose_file" ps -q 2>/dev/null | wc -l)
                    else
                        running_containers=$(docker compose -f "$compose_file" ps -q 2>/dev/null | wc -l)
                    fi
                    
                    if [[ $running_containers -gt 0 ]]; then
                        echo "  $challenge_name: $running_containers container(s) running"
                        running_services=$((running_services + 1))
                    fi
                fi
            done
        done
        
        if [[ $running_services -eq 0 ]]; then
            echo "  No compose services currently running"
        fi
    fi
    
    echo
}

cleanup_docker() {
    log_info "Cleaning up Docker resources..."
    
    # Find Docker images related to challenges
    local challenge_images=()
    
    for category in "${CONFIG[CHALLENGE_PATH]}"/*; do
        [[ -d "$category" ]] || continue
        for challenge in "$category"/*; do
            [[ -d "$challenge" ]] || continue
            local challenge_yml="$category/$(basename "$challenge")/challenge.yml"
            if [[ -f "$challenge_yml" ]]; then
                local challenge_type
                challenge_type=$(get_challenge_info "$challenge_yml" "type")
                if [[ "$challenge_type" == "docker" ]]; then
                    local docker_image
                    docker_image=$(get_challenge_info "$challenge_yml" "docker_image")
                    [[ -n "$docker_image" ]] && challenge_images+=("$docker_image")
                fi
            fi
        done
    done
    
    if [[ ${#challenge_images[@]} -eq 0 ]]; then
        log_info "No challenge Docker images found"
        return 0
    fi
    
    log_info "Found ${#challenge_images[@]} challenge images"
    
    echo "Images to remove:"
    printf '%s\n' "${challenge_images[@]}" | sed 's/^/  - /'
    read -p "Remove these images? (y/N): " -r
    [[ $REPLY =~ ^[Yy]$ ]] || { log_info "Cleanup cancelled"; return 0; }
    
    local removed=0
    for image in "${challenge_images[@]}"; do
        if [[ "${CONFIG[DRY_RUN]}" == "false" ]]; then
            if docker rmi "$image" 2>/dev/null; then
                log_success "Removed: $image"
                removed=$((removed + 1))
            else
                log_warning "Failed to remove or not found: $image"
            fi
        else
            echo "Would remove: docker rmi '$image'"
            removed=$((removed + 1))
        fi
    done
    
    log_info "Cleanup completed: $removed images processed"
}

main() {
    log_info "Enhanced CTF Challenge Management Tool v${VERSION}"
    log_info "Action: ${CONFIG[ACTION]}"

    check_dependencies
    install_ctfcli
    get_challenges_path

    case "${CONFIG[ACTION]}" in
        "all")
            build_challenges && initialize_ctfcli && ingest_challenges
            ;;
        "build")
            build_challenges
            ;;
        "ingest")
            initialize_ctfcli
            ingest_challenges
            ;;
        "sync")
            sync_challenges
            ;;
        "status")
            show_status
            ;;
        "cleanup")
            cleanup_docker
            ;;
        *)
            error_exit "Unknown action: ${CONFIG[ACTION]}"
            ;;
    esac

    log_success "Operation completed successfully!"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    parse_arguments "$@"
    main
fi
