# shellcheck shell=bash
# Fresh, read-only evidence. Ownership records never determine readiness.
pn_package_status() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null; }

pn_status_present() {
    # Includes held, unpacked, half-configured and reinst-required packages.
    [[ -n $1 && $1 != *' not-installed' && $1 != *' config-files' ]]
}

pn_executable_paths() {
    local id=$1 group name dir path key
    local groups=() names=() dirs=() go_roots=()
    local -A seen=()
    PN_PATHS=()
    IFS=: read -r -a dirs <<< "$PATH"
    # Empty PATH entries mean the current directory; absent optional overrides do not.
    for dir in "${!dirs[@]}"; do [[ -n ${dirs[$dir]} ]] || dirs[$dir]=.; done
    dirs+=("$PN_TOOL_BIN" "$PN_HOME/.local/bin" "$PN_HOME/go/bin" "$PN_HOME/bin")
    [[ -z ${GOBIN:-} ]] || dirs+=("$GOBIN")
    IFS=: read -r -a go_roots <<< "${GOPATH:-$PN_HOME/go}"
    for dir in "${go_roots[@]}"; do [[ -z $dir ]] || dirs+=("$dir/bin"); done
    IFS=, read -r -a groups <<< "${PN_CHECKS[$id]}"
    for group in "${groups[@]}"; do
        IFS=/ read -r -a names <<< "$group"
        for name in "${names[@]}"; do
            for dir in "${dirs[@]}"; do
                [[ -n $dir ]] || dir=.
                path=$dir/$name
                [[ -f $path && -x $path ]] || continue
                # Collapse /bin and /usr/bin directory aliases, but keep distinct symlinks.
                key=$(cd -- "$dir" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "$name") || continue
                [[ ${seen[$key]+yes} ]] && continue
                seen[$key]=1
                PN_PATHS+=("$key")
            done
        done
    done
}

pn_inventory() {
    local id=$1 group package status ownership path version
    local groups=() choices=()
    local -A seen=()
    PN_PRESENT=0 PN_RESIDUAL=0 PN_PACKAGE_DETAILS='' PN_PATH_DETAILS='' PN_DETAILS=''
    if [[ ${PN_PROVIDER[$id]} != go && ${PN_PROVIDER[$id]} != bloodhound ]]; then
        IFS=, read -r -a groups <<< "${PN_SPEC[$id]}"
        for group in "${groups[@]}"; do
            IFS=/ read -r -a choices <<< "$group"
            for package in "${choices[@]}"; do
                [[ ${seen[$package]+yes} ]] && continue
                seen[$package]=1
                status=$(pn_package_status "$package")
                [[ -n $status ]] || status='unknown ok not-installed'
                pn_status_present "$status" && ((PN_PRESENT+=1))
                [[ $status != *' config-files' ]] || ((PN_RESIDUAL+=1))
                ownership=untracked
                [[ -z ${PN_RECOVERED[$id:$package]:-} ]] || ownership=recovered-from-install-log
                grep -Fxq -- "$package" "$PN_MANAGED/packages/$id" 2>/dev/null && ownership=tracked
                version=$(dpkg-query -W -f='${Version}' "$package" 2>/dev/null)
                PN_PACKAGE_DETAILS+="$package${version:+=$version} [$status; $ownership] "
            done
        done
    fi
    pn_executable_paths "$id"
    for path in "${PN_PATHS[@]}"; do
        PN_PATH_DETAILS+="${PN_PATH_DETAILS:+; }$path"
    done
    case "${PN_PROVIDER[$id]}" in
        go)
            PN_DETAILS="Expected source: ${PN_SPEC[$id]}; managed destination: $PN_TOOL_BIN/$id."
            if [[ -f $PN_TOOL_BIN/.panoply-$id.source ]]; then
                PN_DETAILS+=' Ownership marker present (not proof of current binary identity).'
            else PN_DETAILS+=' No ownership marker.'; fi ;;
        bloodhound)
            PN_DETAILS='BloodHound configuration missing or invalid; use bloodhound setup. Database volumes are retained.' ;;
        wordlist)
            [[ ! -e $PN_DATA/wordlists/rockyou.txt ]] || PN_DETAILS="User data retained: $PN_DATA/wordlists/rockyou.txt" ;;
    esac
}

pn_launcher_info() {
    local installed
    installed=$(type -P panoply || true)
    printf 'Running Panoply %s from %s\n' "$(cat "$PN_ROOT/VERSION")" "$PN_ROOT"
    if [[ -n $installed ]]; then
        installed=$(readlink -f -- "$installed")
        printf 'PATH launcher: %s\n' "$installed"
        [[ $installed == "$PN_ROOT/bin/panoply" ]] || pn_warn 'PATH selects a different application copy. Re-run install.sh from the fixed repository to update it.'
    fi
}
