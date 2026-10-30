# shellcheck shell=bash
# Recover only explicit new-package evidence in a recognised tool install section.
# Never source logs, infer ownership from Setting up/reinstall, or adopt dependencies.
pn_recover_scan() {
    local file line id='' package base candidate group
    local groups=() choices=()
    declare -gA PN_RECOVERED=()
    for file in "$PN_STATE"/*.log; do
        [[ -f $file && -r $file ]] || continue
        id=''
        while IFS= read -r line || [[ -n $line ]]; do
            line=${line%$'\r'}
            if [[ $line == '==> '* ]]; then
                id=''
                if [[ $line =~ ^'==> '(install|repair|update)' '([a-z0-9-]+)$ ]]; then
                    candidate=${BASH_REMATCH[2]}
                    [[ ${PN_PROVIDER[$candidate]:-} != go && ${PN_PROVIDER[$candidate]:-} != bloodhound && -n ${PN_PROVIDER[$candidate]:-} ]] && id=$candidate
                fi
            elif [[ -n $id && $line =~ ^Selecting\ previously\ unselected\ package\ ([a-z0-9][a-z0-9+.:_-]*)\.$ ]]; then
                package=${BASH_REMATCH[1]}; base=${package%%:*}
                IFS=, read -r -a groups <<< "${PN_SPEC[$id]}"
                for group in "${groups[@]}"; do
                    IFS=/ read -r -a choices <<< "$group"
                    for candidate in "${choices[@]}"; do
                        [[ $base == "$candidate" ]] || continue
                        PN_RECOVERED[$id:$base]=$file
                    done
                done
            fi
        done < "$file"
    done
}

pn_package_owned() {
    local id=$1 package=$2
    grep -Fxq -- "$package" "$PN_MANAGED/packages/$id" 2>/dev/null ||
        [[ -n ${PN_RECOVERED[$id:$package]:-} ]]
}

# Once the user confirms a mutation, persist evidence in the normal ownership
# store so residual configuration remains manageable even if logs are rotated.
pn_recover_record() {
    local id=$1 key package
    local packages=()
    for key in "${!PN_RECOVERED[@]}"; do
        [[ $key == "$id:"* ]] || continue
        package=${key#*:}
        grep -Fxq -- "$package" "$PN_MANAGED/packages/$id" 2>/dev/null && continue
        pn_package_removable "$package" purge || continue
        packages+=("$package")
    done
    (( ${#packages[@]} )) || return 0
    pn_track_packages "$id" "${packages[@]}" || {
        pn_error "$id: could not preserve recovered ownership; removal stopped."
        return 1
    }
}
