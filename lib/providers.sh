# shellcheck shell=bash
pn_apt_refresh() {
    (( PN_REFRESHED )) && return 0
    pn_run 'Refresh package metadata' pn_root apt-get -o DPkg::Lock::Timeout=60 update || return
    PN_REFRESHED=1
}

pn_apt_install() {
    local id=$1 operation=$2
    pn_apt_refresh || return
    if (( PN_DRY )); then
        pn_info "    Package requirements: ${PN_SPEC[$id]}"
        return 0
    fi
    pn_packages_resolve "$id" available || { pn_error "$id: package requirements unavailable: ${PN_SPEC[$id]}"; return 1; }
    local flags=()
    [[ $operation == update ]] && flags+=(--only-upgrade)
    [[ $operation == repair ]] && flags+=(--reinstall)
    local new_packages=() package rc
    for package in "${PN_PACKAGES[@]}"; do
        # Do not adopt pre-existing partial installs or residual configuration.
        pn_package_removable "$package" purge || new_packages+=("$package")
    done
    pn_run "$operation $id" pn_root env DEBIAN_FRONTEND=noninteractive apt-get \
        -o DPkg::Lock::Timeout=60 install -y --no-install-recommends "${flags[@]}" -- "${PN_PACKAGES[@]}"
    rc=$?
    pn_track_packages "$id" "${new_packages[@]}" || return 1
    return "$rc"
}

pn_go_verify() {
    local id=$1
    local arguments=()
    read -r -a arguments <<< "${PN_PROBE[$id]}"
    [[ -x $PN_TOOL_BIN/$id ]] && timeout 10 "$PN_TOOL_BIN/$id" "${arguments[@]}" </dev/null >/dev/null 2>&1
}

pn_go_install() (
    local id=$1 temp
    if (( PN_DRY )); then
        pn_info "Would build ${PN_SPEC[$id]} as $PN_USER and install $PN_TOOL_BIN/$id"; return 0
    fi
    pn_as_user mkdir -p -- "$PN_DATA" || return
    temp=$(pn_as_user mktemp -d "$PN_DATA/.go-build.XXXXXX") || return
    trap 'pn_as_user rm -rf -- "$temp"' EXIT
    pn_run "Build $id from its Go source" pn_as_user env GOBIN="$temp" go install "${PN_SPEC[$id]}" || return
    [[ -x $temp/$id ]] || { pn_error "Go did not produce the expected $id executable."; return 1; }
    local arguments=()
    read -r -a arguments <<< "${PN_PROBE[$id]}"
    pn_run "Check built $id executable" pn_as_user timeout 10 "$temp/$id" "${arguments[@]}" || return
    pn_run "Create tool executable directory" pn_root install -d -m 755 -- "$PN_TOOL_BIN" || return
    pn_run "Install $id executable" pn_root install -m 755 -- "$temp/$id" "$PN_TOOL_BIN/$id" || return
    printf '%s\n' "${PN_SPEC[$id]}" > "$temp/source"
    pn_root install -m 644 -- "$temp/source" "$PN_TOOL_BIN/.panoply-$id.source"
)

pn_docker_verify() {
    PN_COMPOSE=()
    command -v docker >/dev/null || return 1
    timeout 10 docker --version >/dev/null 2>&1 || return 1
    if timeout 10 docker compose version >/dev/null 2>&1; then
        PN_COMPOSE=(docker compose)
    elif command -v docker-compose >/dev/null && timeout 10 docker-compose version >/dev/null 2>&1; then
        PN_COMPOSE=(docker-compose)
    else
        return 1
    fi
}

pn_peass_verify() {
    local listing path lower
    PN_PEASS_LINUX='' PN_PEASS_WINDOWS=''
    pn_packages_resolve peass installed || return 1
    listing=$(dpkg-query -L "${PN_PACKAGES[@]}" 2>/dev/null) || return 1
    while IFS= read -r path; do
        [[ -f $path ]] || continue
        lower=${path,,}
        [[ $lower == */linpeas.sh ]] && PN_PEASS_LINUX=$path
        [[ $lower == */winpeas*.exe ]] && PN_PEASS_WINDOWS=$path
    done <<< "$listing"
    [[ -n $PN_PEASS_LINUX && -n $PN_PEASS_WINDOWS ]]
}

pn_wordlist_prepare() {
    if (( PN_DRY )); then pn_info "    Extract rockyou into $PN_DATA/wordlists"; return 0; fi
    pn_run 'Prepare user-owned rockyou wordlist' pn_as_user bash -c '
        set -e
        umask 077
        dest=$1/wordlists
        mkdir -p -- "$dest"
        [[ -s $dest/rockyou.txt ]] && exit 0
        temp=$(mktemp "$dest/.rockyou.XXXXXX")
        trap '\''rm -f -- "$temp"'\'' EXIT
        if [[ -f /usr/share/wordlists/rockyou.txt ]]; then
            cat /usr/share/wordlists/rockyou.txt > "$temp"
        elif [[ -f /usr/share/wordlists/rockyou.txt.gz ]]; then
            gzip -dc /usr/share/wordlists/rockyou.txt.gz > "$temp"
        else
            printf "rockyou asset missing from wordlists package.\n" >&2; exit 1
        fi
        [[ -s $temp ]]
        mv -- "$temp" "$dest/rockyou.txt"
    ' _ "$PN_DATA"
}

pn_tool_apply() {
    local id=$1 operation=$2
    case "${PN_PROVIDER[$id]}" in
        go) pn_go_install "$id" ;;
        bloodhound) pn_bh_prepare ;;
        wordlist) pn_apt_install "$id" "$operation" && pn_wordlist_prepare ;;
        *) pn_apt_install "$id" "$operation" ;;
    esac
}

pn_plan() {
    local operation=${1:-install} id state action
    printf '%-23s %-11s %-14s %s\n' TOOL ACTION STATE REQUIREMENTS
    for id in "${PN_SELECTED[@]}"; do
        pn_tool_state "$id"
        if [[ $operation == repair ]]; then
            action=REINSTALL
        elif [[ $operation == update ]]; then
            if [[ $PN_STATUS == missing ]]; then action=MISSING; else action=UPGRADE; fi
        else
            case "$PN_STATUS" in
                ready) action=SKIP ;;
                missing|residual|external) action=INSTALL ;;
                broken|partial) action=REPAIR ;;
                needs-config) action=CONFIGURE ;;
            esac
        fi
        if [[ ${PN_PROVIDER[$id]} == bloodhound && $action != SKIP ]]; then action=CONFIGURE; fi
        printf '%-23s %-11s ' "$id" "$action"
        printf -v state '%-14s' "$PN_STATUS"
        pn_tint "$PN_STATUS" "$state"
        printf ' %s\n' "${PN_SPEC[$id]:-local configuration}"
    done
}

pn_apply() {
    local operation=$1 id dep blocked failed=0 ready=0 changed=0 pending=0 effective_operation
    local dependencies=()
    local -A outcomes=()
    pn_plan "$operation"
    pn_confirm || return
    if (( ! PN_DRY )); then
        pn_platform_check || return
        pn_lock && pn_log_init || return
    fi
    for id in "${PN_SELECTED[@]}"; do
        blocked=0
        IFS=, read -r -a dependencies <<< "${PN_DEPS[$id]}"
        for dep in "${dependencies[@]}"; do
            [[ -z $dep ]] && continue
            if [[ ${outcomes[$dep]:-failed} != ok ]]; then blocked=1; fi
        done
        if (( blocked )); then
            pn_error "$id: skipped because a dependency failed."
            outcomes[$id]=failed; ((failed+=1)); continue
        fi
        pn_tool_state "$id"
        if [[ $operation == install && $PN_STATUS == ready ]]; then
            pn_skip "$id (already installed and verified)"; outcomes[$id]=ok; ((ready+=1)); continue
        fi
        if [[ $operation == update && ( $PN_STATUS == missing || $PN_STATUS == external || $PN_STATUS == residual ) ]]; then
            pn_error "$id is missing; use install first."
            outcomes[$id]=failed; ((failed+=1)); continue
        fi
        effective_operation=$operation
        if [[ $operation == install && ( $PN_STATUS == broken || $PN_STATUS == partial ) ]]; then effective_operation=repair; fi
        if ! pn_tool_apply "$id" "$effective_operation"; then
            outcomes[$id]=failed; ((failed+=1)); continue
        fi
        if (( PN_DRY )); then outcomes[$id]=ok; ((changed+=1)); continue; fi
        pn_tool_state "$id"
        if [[ $PN_STATUS == ready ]]; then
            pn_message success VERIFIED "$id"; outcomes[$id]=ok; ((changed+=1))
        elif [[ $PN_STATUS == needs-config ]]; then
            pn_warn "NEEDS CONFIG: $id — check its port and database secret settings with bloodhound configure or inspect its .env."
            outcomes[$id]=pending; ((pending+=1))
        else
            pn_error "$id: post-install verification failed."
            outcomes[$id]=failed; ((failed+=1))
        fi
    done
    if (( PN_DRY )); then
        printf '\nDry run: %s already ready, %s planned, %s blocked. No changes applied.\n' "$ready" "$changed" "$failed"
    else
        printf '\nSummary: '
        pn_tint skip "$ready already ready"; printf ', '
        pn_tint success "$changed verified"; printf ', '
        if (( pending )); then pn_tint warning "$pending need configuration"; else printf '%s need configuration' "$pending"; fi
        printf ', '
        if (( failed )); then pn_tint error "$failed failed"; else printf '%s failed' "$failed"; fi
        printf '.\n'
    fi
    (( failed == 0 && pending == 0 ))
}

pn_json_string() {
    local value=$1
    value=${value//\\/\\\\}; value=${value//\"/\\\"}
    value=${value//$'\n'/\\n}; value=${value//$'\r'/\\r}; value=${value//$'\t'/\\t}
    printf '"%s"' "$value"
}

pn_doctor() {
    local json=$1 id failed=0 sep='' version state
    pn_recover_scan
    hash -r
    [[ $json == yes ]] || pn_launcher_info
    [[ $json == yes ]] && printf '['

    for id in "${PN_SELECTED[@]}"; do
        pn_tool_state "$id"
        if [[ $id == bloodhound && $PN_STATUS == ready ]]; then pn_bh_observe; fi
        [[ $PN_STATUS == ready ]] || failed=1
        version=$PN_PACKAGE_DETAILS
        if [[ $json == yes ]]; then
            printf '%s{"tool":' "$sep"; pn_json_string "$id"
            printf ',"status":'; pn_json_string "$PN_STATUS"
            printf ',"packages":'; pn_json_string "${version% }"
            printf ',"executables":'; pn_json_string "$PN_PATH_DETAILS"
            printf ',"details":'; pn_json_string "$PN_DETAILS"
            printf ',"application_root":'; pn_json_string "$PN_ROOT"
            printf '}'; sep=','

        else
            printf '%-23s ' "$id"
            printf -v state '%-14s' "$PN_STATUS"
            pn_tint "$PN_STATUS" "$state"
            printf ' %s\n' "${version% }"
            [[ -z $PN_PATH_DETAILS ]] || printf '  Executables: %s\n' "$PN_PATH_DETAILS"
            [[ -z $PN_DETAILS ]] || printf '  %s\n' "$PN_DETAILS"
            if [[ $id == peass && $PN_STATUS == ready ]]; then
                printf '  Linux: %s\n  Windows: %s\n' "$PN_PEASS_LINUX" "$PN_PEASS_WINDOWS"
            fi
        fi
    done
    [[ $json == yes ]] && printf ']\n'
    return "$failed"
}
