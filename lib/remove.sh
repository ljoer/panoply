# shellcheck shell=bash
# Package ownership records and explicit, previewed removal. Never autoremove.
pn_valid_package() { [[ $1 =~ ^[a-z0-9][a-z0-9+.-]*(:[a-z0-9]+)?$ ]]; }

pn_track_packages() {
    local id=$1 package temp
    shift
    (( $# )) || return 0
    temp=$(mktemp) || return
    [[ ! -f $PN_MANAGED/packages/$id ]] || cat -- "$PN_MANAGED/packages/$id" > "$temp"
    for package in "$@"; do
        pn_valid_package "$package" || { rm -f -- "$temp"; return 1; }
        pn_package_removable "$package" purge && printf '%s\n' "$package" >> "$temp"
    done
    if [[ -s $temp ]]; then
        sort -u -o "$temp" "$temp"
        pn_root install -d -m 755 -- "$PN_MANAGED/packages" &&
            pn_root install -m 644 -- "$temp" "$PN_MANAGED/packages/$id"
        local rc=$?
        rm -f -- "$temp"; return "$rc"
    fi
    rm -f -- "$temp"
}

pn_package_removable() {
    local status
    status=$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null)
    pn_status_present "$status" || [[ $2 == purge && $status == *' config-files' ]]
}

pn_protected_package() {
    case "${1%%:*}" in
        apt|dpkg|sudo|bash|coreutils|libc6|systemd|systemd-*|linux-image-*|python3|python3-minimal|python3-venv|python3-pip|python3.[0-9]*|pipx|golang*|nodejs|npm|docker*|containerd*|openssl|ca-certificates|git|curl|jq) return 0 ;;
        *) return 1 ;;
    esac
}

pn_select_removal() {
    (( $# )) || { pn_error 'Select an explicit tool or profile to remove.'; return 2; }
    PN_RESOLVE_DEPS=0
    pn_select "$@"
    local rc=$?
    PN_RESOLVE_DEPS=1
    return "$rc"
}

pn_removal_candidates() {
    local id=$1 mode=$2 group package
    local groups=() choices=()
    PN_REMOVE_CANDIDATES=()
    IFS=, read -r -a groups <<< "${PN_SPEC[$id]}"
    for group in "${groups[@]}"; do
        IFS=/ read -r -a choices <<< "$group"
        for package in "${choices[@]}"; do
            pn_valid_package "$package" || return 2
            pn_package_removable "$package" "$mode" || continue
            pn_protected_package "$package" && { pn_warn "Preserving shared/system package: $package"; continue; }
            if (( PN_INCLUDE_UNTRACKED )) || pn_package_owned "$id" "$package"; then
                [[ -z ${PN_RECOVERED[$id:$package]:-} ]] || pn_info "Recovered ownership: $id / $package — ${PN_RECOVERED[$id:$package]} (previously unselected package)."
                PN_REMOVE_CANDIDATES+=("$package")
            else
                pn_skip "$package: pre-existing or ownership unknown; not installed by Panoply's tracker. Keeping it."
            fi
        done
    done
}

pn_remove_simulate() {
    local mode=$1 output package
    shift
    output=$(LC_ALL=C apt-get -s "$mode" -- "$@") || { pn_error 'APT could not calculate a removal plan.'; return 1; }
    while IFS= read -r package; do
        [[ -z $package ]] && continue
        if pn_protected_package "$package"; then pn_error "APT would remove protected package $package; stopped."; return 1; fi
        local found=0 selected
        for selected in "$@"; do [[ $package == "$selected" ]] && found=1; done
        (( found )) || { pn_error "APT would also remove unselected package $package; stopped."; return 1; }
    done < <(awk '/^(Remv|Purg) / {print $2}' <<< "$output")
    printf '%s\n' "$output"
}

pn_untrack_absent() {
    local id=$1 package temp rc=0
    [[ -f $PN_MANAGED/packages/$id ]] || return 0
    temp=$(mktemp) || return
    while IFS= read -r package; do
        pn_valid_package "$package" || continue
        pn_package_removable "$package" purge && printf '%s\n' "$package" >> "$temp"
    done < "$PN_MANAGED/packages/$id"
    if [[ -s $temp ]]; then pn_root install -m 644 -- "$temp" "$PN_MANAGED/packages/$id"; rc=$?
    else pn_root rm -f -- "$PN_MANAGED/packages/$id"; rc=$?; fi
    rm -f -- "$temp"; return "$rc"
}

pn_remove() {
    local mode=$1 id package simulation confirmation failed=0 path blocked=0
    local -A plans=()
    local eligible=()
    local packages=() source_tools=()
    local -A seen=()
    pn_recover_scan
    for id in "${PN_SELECTED[@]}"; do
        pn_inventory "$id"
        printf 'Selected: %s\n  %s\n' "$id" "$PN_PACKAGE_DETAILS"
        [[ -z $PN_PATH_DETAILS ]] || printf '  Executables: %s\n' "$PN_PATH_DETAILS"
        case "${PN_PROVIDER[$id]}" in
            bloodhound) pn_warn 'Use bloodhound down to stop the server. Database volumes and its configuration are retained.' ;;
            go)
                for path in "${PN_PATHS[@]}"; do
                    [[ $path == "$PN_TOOL_BIN/$id" ]] || pn_skip "$id: extra executable $path will be preserved; remove it using its original installer."
                done
                if [[ -e $PN_TOOL_BIN/$id || -L $PN_TOOL_BIN/$id ]]; then
                    if [[ -f $PN_TOOL_BIN/.panoply-$id.source ]] || (( PN_INCLUDE_UNTRACKED )); then source_tools+=("$id")
                    else pn_warn "$id is untracked; keeping it. Use --include-untracked to include it."; fi
                fi ;;
            *)
                pn_removal_candidates "$id" "$mode" || return
                for package in "${PN_REMOVE_CANDIDATES[@]}"; do
                    [[ ${seen[$package]+exists} ]] || packages+=("$package")
                    seen[$package]=1
                done ;;
        esac
    done
    if (( ${#packages[@]} == 0 && ${#source_tools[@]} == 0 )); then
        pn_skip 'No eligible installed tools were selected.'
        pn_removal_verify "$mode"
        return
    fi
    printf '%s plan\n' "$mode"
    for package in "${packages[@]}"; do printf '  APT: %s\n' "$package"; done
    for id in "${source_tools[@]}"; do printf '  Executable: %s/%s\n' "$PN_TOOL_BIN" "$id"; done
    pn_info 'Shared runtimes, user data and BloodHound volumes will be kept. No autoremove is run.'
    if (( ${#packages[@]} )); then
        if simulation=$(pn_remove_simulate "$mode" "${packages[@]}"); then
            plans[batch]=$simulation
        else
            pn_warn 'Combined plan blocked; checking independent removals. Dependencies outside each plan will be kept.'
            for package in "${packages[@]}"; do
                if simulation=$(pn_remove_simulate "$mode" "$package"); then
                    eligible+=("$package"); plans[$package]=$simulation
                else
                    pn_skip "$package: dependency conflict; keeping it."
                    blocked=1
                fi
            done
            packages=("${eligible[@]}")
        fi
        for simulation in "${plans[@]}"; do printf '%s\n' "$simulation"; done
    fi
    (( PN_DRY )) && { pn_info 'Dry run only; nothing removed. Listed untracked/protected tools and extra executable paths will remain.'; return "$blocked"; }
    if (( ${#packages[@]} == 0 && ${#source_tools[@]} == 0 )); then return "$blocked"; fi
    pn_confirm && pn_platform_check && pn_lock && pn_log_init || return
    for id in "${PN_SELECTED[@]}"; do pn_recover_record "$id" || return; done
    if [[ ${plans[batch]+yes} ]]; then
        confirmation=$(pn_remove_simulate "$mode" "${packages[@]}") || return
        [[ $confirmation == "${plans[batch]}" ]] || { pn_error 'APT removal plan changed; rerun to review it.'; return 1; }
        pn_run "$mode managed packages" pn_root env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=60 "$mode" -y -- "${packages[@]}" || failed=1
    else
        for package in "${packages[@]}"; do
            confirmation=$(pn_remove_simulate "$mode" "$package") || { failed=1; continue; }
            if [[ $confirmation != "${plans[$package]}" ]]; then
                pn_error "$package: plan changed; keeping it."; failed=1; continue
            fi
            pn_run "$mode $package" pn_root env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=60 "$mode" -y -- "$package" || failed=1
        done
    fi
    for package in "${packages[@]}"; do
        if pn_package_removable "$package" "$mode"; then pn_error "$package is still present after $mode."; failed=1; fi
    done
    for id in "${source_tools[@]}"; do
        pn_run "Remove $id executable" pn_root rm -f -- "$PN_TOOL_BIN/$id" "$PN_TOOL_BIN/.panoply-$id.source" || failed=1
    done
    for id in "${PN_SELECTED[@]}"; do pn_untrack_absent "$id" || failed=1; done
    (( blocked == 0 )) || failed=1
    hash -r
    pn_removal_verify "$mode" || failed=1
    if (( failed == 0 )); then
        if (( PN_INCLUDE_UNTRACKED )); then
            pn_success "$mode cleanup finished for selected tools regardless of origin. Retained data/configuration is noted above."
        else
            pn_success "$mode cleanup finished for eligible Panoply-owned tools. Pre-existing tools, shared runtimes and data were kept; this does not mean the profile is absent."
        fi
    else pn_error "$mode incomplete: selected tools remain or an operation failed. Review the remaining evidence above."; fi
    return "$failed"
}

# Verify the entire selection, including skipped items, after every removal.
pn_removal_verify() {
    local mode=$1 id remaining=0 package owned key
    local records=()
    for id in "${PN_SELECTED[@]}"; do
        pn_inventory "$id"
        if (( ! PN_INCLUDE_UNTRACKED )); then
            owned=0
            records=()
            if [[ ${PN_PROVIDER[$id]} == go ]]; then
                if [[ -f $PN_TOOL_BIN/.panoply-$id.source && ( -e $PN_TOOL_BIN/$id || -L $PN_TOOL_BIN/$id ) ]]; then owned=1; fi
            else
                [[ ! -f $PN_MANAGED/packages/$id ]] || mapfile -t records < "$PN_MANAGED/packages/$id"
                for key in "${!PN_RECOVERED[@]}"; do
                    [[ $key != "$id:"* ]] || records+=("${key#*:}")
                done
                for package in "${records[@]}"; do
                    pn_valid_package "$package" || continue
                    pn_protected_package "$package" && continue
                    pn_package_removable "$package" "$mode" && owned=1
                done
            fi
            if (( owned )); then
                pn_error "$id: Panoply-owned payload remains: $PN_PACKAGE_DETAILS $PN_PATH_DETAILS"
                remaining=1
            elif (( PN_PRESENT || PN_RESIDUAL || ${#PN_PATHS[@]} )) || [[ ${PN_PROVIDER[$id]} == bloodhound ]]; then
                pn_skip "$id: only preserved/pre-existing tools, configuration or data remain."
            else pn_success "$id: no managed payload remains."; fi
            continue
        fi
        if [[ ${PN_PROVIDER[$id]} == bloodhound ]]; then
            pn_skip 'bloodhound: server/configuration and volumes retained; use bloodhound down to stop it.'
            remaining=1
        elif (( PN_PRESENT || ${#PN_PATHS[@]} )); then
            # Residual configuration is handled separately for remove vs purge below.
            pn_error "$id remains: $PN_PACKAGE_DETAILS $PN_PATH_DETAILS"
            remaining=1
        elif [[ $mode == purge ]] && (( PN_RESIDUAL )); then
            pn_error "$id retains package configuration: $PN_PACKAGE_DETAILS"
            remaining=1
        else
            pn_success "$id: no selected package payload or known executable remains."
            (( PN_RESIDUAL == 0 )) || pn_info "$id: package configuration retained by remove; use purge to clear it."
        fi
        [[ -z $PN_DETAILS || ${PN_PROVIDER[$id]} != wordlist ]] || pn_skip "$PN_DETAILS"
    done
    return "$remaining"
}

pn_remove_menu() {
    local mode target scope previous=$PN_INCLUDE_UNTRACKED rc
    read -r -p 'Tool or profile to remove: ' target || return 1
    [[ -n $target ]] || return 1
    read -r -p 'Remove or purge package configuration too? [remove/purge]: ' mode || return 1
    case "$mode" in remove|purge) ;; *) pn_error 'Choose remove or purge.'; return 2 ;; esac
    printf '  1  Undo Panoply installs (tracked or recovered ownership)\n  2  Remove selected tools regardless of origin\n'
    read -r -p 'Removal scope [1]: ' scope || return 1
    case "${scope:-1}" in
        1) PN_INCLUDE_UNTRACKED=0; pn_info 'Undo Panoply installs: pre-existing Kali tools are kept.' ;;
        2) PN_INCLUDE_UNTRACKED=1; pn_warn 'Regardless of origin: selected pre-existing tools are included. Shared/system packages, external executable copies and data remain protected.' ;;
        *) pn_error 'Choose removal scope 1 or 2.'; return 2 ;;
    esac
    pn_select_removal "$target" && pn_remove "$mode"
    rc=$?
    PN_INCLUDE_UNTRACKED=$previous
    return "$rc"
}
