#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Shared runtime configuration loader for the physical-device E2E runners.
# Source this file, then call:
#   sim_use_load_physical_device_e2e_config "$REPO_ROOT"
#
# The local file uses strict KEY=value lines rather than shell syntax. Only the
# allowlisted keys below are accepted, so loading developer-specific signing
# data never executes commands. Existing non-empty environment variables win.

sim_use_load_physical_device_e2e_config() {
    local repo_root="$1"
    local config_file="${SIM_USE_E2E_CONFIG_FILE:-$repo_root/.sim-use-e2e.local.env}"

    [[ -e "$config_file" ]] || return 0
    if [[ ! -f "$config_file" || ! -r "$config_file" ]]; then
        echo "Physical-device E2E config is not a readable file: $config_file" >&2
        return 1
    fi

    local line=""
    local line_number=0
    local key=""
    local value=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        line_number=$((line_number + 1))
        line="${line%$'\r'}"
        case "$line" in
            ""|\#*) continue ;;
        esac
        if [[ "$line" != *=* ]]; then
            echo "Malformed physical-device E2E config at $config_file:$line_number" >&2
            return 1
        fi

        key="${line%%=*}"
        value="${line#*=}"
        case "$key" in
            SIM_USE_DEVICE_UDID|\
            SIM_USE_TVOS_DEVICE_UDID|\
            SIM_USE_PLAYGROUND_BUNDLE_ID|\
            SIM_USE_TVOS_BUNDLE_ID|\
            SIM_USE_WDA_BUNDLE_ID|\
            SIM_USE_TVOS_WDA_BUNDLE_ID|\
            SIM_USE_XCODE_ORG_ID|\
            SIM_USE_XCODE_SIGNING_ID)
                ;;
            *)
                echo "Unsupported physical-device E2E config key at $config_file:$line_number: $key" >&2
                return 1
                ;;
        esac

        if [[ -z "${!key:-}" ]]; then
            printf -v "$key" '%s' "$value"
            export "$key"
        fi
    done < "$config_file"
}
