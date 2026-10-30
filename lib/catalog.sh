# shellcheck shell=bash
# Declarative tool registry and profile/dependency resolution.
pn_catalog_load() {
    local id provider spec checks probe deps description extra
    while IFS='|' read -r id provider spec checks probe deps description extra; do
        [[ -z $id || $id == \#* ]] && continue
        [[ $id =~ ^[a-z0-9][a-z0-9-]*$ && -z $extra && -n $description ]] || { pn_error "Invalid catalogue row: $id"; return 2; }
        [[ ! ${PN_PROVIDER[$id]+exists} ]] || { pn_error "Duplicate tool: $id"; return 2; }
        case "$provider" in apt|go|peass|wordlist|bloodhound|docker) ;; *) pn_error "Unknown provider: $provider"; return 2 ;; esac
        PN_IDS+=("$id") PN_PROVIDER[$id]=$provider PN_SPEC[$id]=$spec
        PN_CHECKS[$id]=$checks PN_PROBE[$id]=$probe PN_DEPS[$id]=$deps PN_DESC[$id]=$description
    done < "$PN_ROOT/config/tools.catalog"
    [[ ${#PN_IDS[@]} -gt 0 ]]
}

pn_select_one() {
    local item=$1 entry dependency
    [[ $item =~ ^[a-z0-9][a-z0-9-]*$ ]] || { pn_error "Invalid selection: $item"; return 2; }
    [[ ${PN_SEEN[$item]+exists} ]] && return 0
    [[ ! ${PN_VISITING[$item]+exists} ]] || { pn_error "Dependency/profile cycle: $item"; return 2; }
    PN_VISITING[$item]=1
    if [[ -f $PN_ROOT/profiles/$item.profile ]]; then
        while IFS= read -r entry || [[ -n $entry ]]; do
            [[ -z $entry || $entry == \#* ]] && continue
            pn_select_one "${entry#@}" || return
        done < "$PN_ROOT/profiles/$item.profile"
    elif [[ ${PN_PROVIDER[$item]+exists} ]]; then
        local dependencies=()
        IFS=, read -r -a dependencies <<< "${PN_DEPS[$item]}"
        if (( PN_RESOLVE_DEPS )); then
            for dependency in "${dependencies[@]}"; do
                [[ -z $dependency ]] || pn_select_one "$dependency" || return
            done
        fi
        PN_SELECTED+=("$item")
    else
        pn_error "Unknown tool or profile: $item"; return 2
    fi
    unset 'PN_VISITING[$item]'
    PN_SEEN[$item]=1
}

pn_select() {
    PN_SELECTED=() PN_SEEN=() PN_VISITING=()
    (( $# )) || set -- core
    local item
    for item in "$@"; do pn_select_one "$item" || return; done
}

pn_package_installed() {
    [[ $(dpkg-query -W -f='${Status}' "$1" 2>/dev/null) == *' ok installed' ]]
}

pn_package_available() {
    local candidate
    candidate=$(apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ {print $2; exit}')
    [[ -n $candidate && $candidate != '(none)' ]]
}

# Commas require every group; slashes offer distribution package alternatives.
pn_packages_resolve() {
    local id=$1 mode=$2 group candidate found
    local groups=() choices=()
    PN_PACKAGES=()
    IFS=, read -r -a groups <<< "${PN_SPEC[$id]}"
    for group in "${groups[@]}"; do
        [[ -z $group ]] && continue
        found=''
        IFS=/ read -r -a choices <<< "$group"
        for candidate in "${choices[@]}"; do
            if pn_package_installed "$candidate"; then found=$candidate; break; fi
        done
        if [[ -z $found && $mode == available ]]; then
            for candidate in "${choices[@]}"; do
                if pn_package_available "$candidate"; then found=$candidate; break; fi
            done
        fi
        [[ -n $found ]] || return 1
        [[ " ${PN_PACKAGES[*]} " == *" $found "* ]] || PN_PACKAGES+=("$found")
    done
}

pn_command_find() {
    local group=$1 name
    local names=()
    IFS=/ read -r -a names <<< "$group"
    for name in "${names[@]}"; do
        if command -v "$name" >/dev/null 2>&1; then command -v "$name"; return 0; fi
    done
    return 1
}

pn_commands_check() {
    local id=$1 verify=$2 group path rc
    local groups=() arguments=()
    IFS=, read -r -a groups <<< "${PN_CHECKS[$id]}"
    for group in "${groups[@]}"; do
        path=$(pn_command_find "$group") || return 1
        if [[ $verify == yes && ${PN_PROBE[$id]} != presence ]]; then
            read -r -a arguments <<< "${PN_PROBE[$id]}"
            timeout 10 "$path" "${arguments[@]}" </dev/null >/dev/null 2>&1
            rc=$?
            (( rc == 0 )) || return 1
        fi
    done
    if [[ $verify == yes && $id == python-runtime ]]; then
        timeout 10 python3 -c 'import venv, ensurepip' </dev/null >/dev/null 2>&1 || return 1
    fi
    return 0
}

pn_tool_state() {
    local id=$1
    hash -r
    pn_inventory "$id"
    if [[ ${PN_PROVIDER[$id]} == bloodhound ]]; then
        if pn_bh_verify; then PN_STATUS=ready; else PN_STATUS=needs-config; fi
    elif [[ ${PN_PROVIDER[$id]} == go ]]; then
        if [[ ( -e $PN_TOOL_BIN/$id || -L $PN_TOOL_BIN/$id ) && ! -x $PN_TOOL_BIN/$id ]]; then PN_STATUS=broken
        elif [[ ! -x $PN_TOOL_BIN/$id ]]; then
            if (( ${#PN_PATHS[@]} )); then PN_STATUS=external; else PN_STATUS=missing; fi
        elif pn_go_verify "$id"; then PN_STATUS=ready
        else PN_STATUS=broken; fi
    elif ! pn_packages_resolve "$id" installed; then
        if (( PN_PRESENT )); then PN_STATUS=partial
        elif (( ${#PN_PATHS[@]} )); then PN_STATUS=external
        elif (( PN_RESIDUAL )); then PN_STATUS=residual
        else PN_STATUS=missing; fi
    else
        case "${PN_PROVIDER[$id]}" in
            peass) if pn_peass_verify; then PN_STATUS=ready; else PN_STATUS=broken; fi ;;
            wordlist) if [[ -s $PN_DATA/wordlists/rockyou.txt ]]; then PN_STATUS=ready; else PN_STATUS=broken; fi ;;
            docker) if pn_docker_verify; then PN_STATUS=ready; else PN_STATUS=broken; fi ;;
            apt) if pn_commands_check "$id" yes; then PN_STATUS=ready; else PN_STATUS=broken; fi ;;
        esac
    fi
}
