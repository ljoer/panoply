# shellcheck shell=bash
# shellcheck source=lib/core.sh
source "$PN_ROOT/lib/core.sh" || return
# shellcheck source=lib/catalog.sh
source "$PN_ROOT/lib/catalog.sh" || return
# shellcheck source=lib/inventory.sh
source "$PN_ROOT/lib/inventory.sh" || return
# shellcheck source=lib/providers.sh
source "$PN_ROOT/lib/providers.sh" || return
# shellcheck source=lib/recovery.sh
source "$PN_ROOT/lib/recovery.sh" || return
# shellcheck source=lib/remove.sh
source "$PN_ROOT/lib/remove.sh" || return
# shellcheck source=lib/bloodhound.sh
source "$PN_ROOT/lib/bloodhound.sh" || return
# shellcheck source=lib/ui.sh
source "$PN_ROOT/lib/ui.sh" || return

pn_system() {
    local action=${1:-}
    (( $# == 1 )) || { pn_error 'Use system update or system upgrade.'; return 2; }
    case "$action" in update|upgrade) ;; *) pn_error 'Use system update or system upgrade.'; return 2 ;; esac
    pn_confirm || return
    if (( ! PN_DRY )); then pn_platform_check && pn_lock && pn_log_init || return; fi
    pn_apt_refresh || return
    [[ $action == update ]] && return 0
    pn_run 'Upgrade Kali system packages' pn_root env DEBIAN_FRONTEND=noninteractive \
        apt-get -o DPkg::Lock::Timeout=60 full-upgrade -y || return
    pn_info 'Upgrade completed. Review package output for restart requirements; no reboot was requested.'
}

pn_main() {
    pn_init || return
    trap pn_finish EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    pn_catalog_load || return
    local json=no command action rc=0
    local args=()
    while (( $# )); do
        case "$1" in
            --yes|-y) PN_YES=1 ;;
            --dry-run) PN_DRY=1 ;;
            --no-color) PN_COLOR=0 ;;
            --no-animation) PN_ANIMATE=0 ;;
            --json) json=yes ;;
            --include-untracked) PN_INCLUDE_UNTRACKED=1 ;;
            --help|-h) pn_help; return 0 ;;
            --version) cat "$PN_ROOT/VERSION"; return 0 ;;
            *) args+=("$1") ;;
        esac
        shift
    done
    command=${args[0]:-menu}
    set -- "${args[@]:1}"
    [[ $json == no || $command == doctor ]] || { pn_error '--json is only supported by doctor.'; return 2; }
    case "$command" in
        help) pn_help ;;
        version) cat "$PN_ROOT/VERSION" ;;
        menu) (( $# == 0 )) || return 2; pn_select all && pn_menu ;;
        banner)
            (( $# == 0 )) || return 2
            local options=()
            (( PN_COLOR )) || options+=(--no-color)
            (( PN_ANIMATE )) || options+=(--static)
            bash "$PN_ROOT/assets/logo.sh" "${options[@]}" ;;
        list) (( $# )) || set -- all; pn_select "$@" && pn_list ;;
        plan) pn_select "$@" && pn_plan ;;
        doctor) pn_select "$@" && pn_doctor "$json" ;;
        install|repair|update) pn_select "$@" && pn_apply "$command" ;;
        remove|purge) pn_select_removal "$@" && pn_remove "$command" ;;
        system) pn_system "$@" ;;
        bloodhound) pn_bh_command "$@" ;;
        nuclei|nmap)
            action=${1:-}
            [[ $# == 1 && ( $command == nuclei && $action == templates || $command == nmap && $action == scripts ) ]] || { pn_error 'Use nuclei templates or nmap scripts.'; return 2; }
            pn_select "$command" || return
            pn_tool_state "$command"
            [[ $PN_STATUS == ready ]] || { pn_error "Run install $command first."; return 1; }
            pn_confirm || return
            if (( ! PN_DRY )); then pn_lock && pn_log_init || return; fi
            if [[ $command == nuclei ]]; then
                pn_run 'Update Nuclei templates for the invoking user' pn_as_user nuclei -update-templates
            else
                (( PN_DRY )) || pn_platform_check || return
                pn_run 'Refresh Nmap script database' pn_root nmap --script-updatedb
            fi ;;
        *) pn_error "Unknown command: $command"; pn_help >&2; rc=2; return "$rc" ;;
    esac
}
