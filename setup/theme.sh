#!/usr/bin/env bash
# setup/theme.sh — Clone or copy a custom CTFd theme.
# Requires: lib/common.sh

[[ -n "${_SETUP_THEME_LOADED:-}" ]] && return 0
readonly _SETUP_THEME_LOADED=1

setup_custom_theme() {
    local theme_source="${CONFIG[THEME]}"
    local working_dir="${CONFIG[WORKING_DIR]}"
    local custom_theme_dir="$working_dir/data/CTFd/themes/custom"

    if [[ -z "$theme_source" ]]; then
        log_info "No custom theme specified"
        return 0
    fi

    log_info "Setting up custom theme from: $theme_source"

    if [[ -d "$custom_theme_dir" ]]; then
        log_info "Removing existing custom theme directory..."
        rm -rf "$custom_theme_dir"
    fi

    mkdir -p "$custom_theme_dir"

    if is_git_url "$theme_source"; then
        log_info "Detected git URL, cloning repository..."
        local clone_dir="$working_dir/theme-clone-temp"
        _cleanup_files+=("$clone_dir")
        rm -rf "$clone_dir" 2>/dev/null || true

        if git clone "$theme_source" "$clone_dir"; then
            log_success "Repository cloned successfully"
            cp -r "$clone_dir"/* "$custom_theme_dir"/
            rm -rf "$clone_dir"
        else
            log_error "Failed to clone git repository: $theme_source"
            return 1
        fi
    else
        if [[ ! -d "$theme_source" ]]; then
            log_error "Theme directory not found: $theme_source"
            return 1
        fi

        log_info "Copying local theme directory..."
        if ! cp -r "$theme_source"/* "$custom_theme_dir"/; then
            log_error "Failed to copy local theme"
            return 1
        fi
        log_success "Local theme copied successfully"
    fi

    chown -R 1001:1001 "$custom_theme_dir"
    log_success "Custom theme setup completed at: $custom_theme_dir"
}
