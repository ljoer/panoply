# shellcheck shell=bash
# BloodHound uses a fixed project and user-owned persistent configuration.
pn_bh_get() {
    [[ -f $PN_BH_DIR/.env ]] || return 1
    awk -v key="$1" 'index($0,key "=")==1 {print substr($0,length(key)+2); exit}' "$PN_BH_DIR/.env"
}

pn_image_valid() {
    local image=$1 tail digest
    [[ $image =~ ^[a-zA-Z0-9][a-zA-Z0-9._:/@-]+$ ]] || return 1
    tail=${image##*/}
    if [[ $image == *@* ]]; then
        digest=${image##*@}
        [[ $digest =~ ^sha256:[a-fA-F0-9]{64}$ ]]
    else
        [[ $tail =~ ^[^:]+:[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,127}$ ]]
    fi
}

pn_port_valid() { [[ $1 =~ ^[0-9]{4,5}$ ]] && (( 10#$1 >= 1024 && 10#$1 <= 65535 )); }

pn_bh_verify() {
    [[ -f $PN_BH_DIR/compose.yml && -f $PN_BH_DIR/.env ]] || return 1
    local image graph postgres
    image=$(pn_bh_get BLOODHOUND_IMAGE); graph=$(pn_bh_get NEO4J_IMAGE)
    pn_image_valid "${image:-specterops/bloodhound:latest}" || return 1
    pn_image_valid "${graph:-neo4j:4.4}" || return 1
    postgres=$(pn_bh_get POSTGRES_IMAGE)
    pn_image_valid "${postgres:-postgres:16}" || return 1
    pn_port_valid "$(pn_bh_get BLOODHOUND_PORT)" || return 1
    [[ $(pn_bh_get POSTGRES_PASSWORD) =~ ^[a-f0-9]{48}$ && $(pn_bh_get NEO4J_PASSWORD) =~ ^[a-f0-9]{48}$ ]]
}

pn_bh_prepare() {
    if (( PN_DRY )); then
        pn_info "    Prepare $PN_BH_DIR (no containers started)."; return 0
    fi
    pn_as_user bash -c 'umask 077; mkdir -p -- "$1"; chmod 700 -- "$1"' _ "$PN_BH_DIR" || return
    pn_as_user cp -- "$PN_ROOT/assets/compose.yml" "$PN_BH_DIR/compose.yml" || return
    if [[ ! -f $PN_BH_DIR/.env ]]; then
        local postgres neo4j
        postgres=$(openssl rand -hex 24) || return
        neo4j=$(openssl rand -hex 24) || return
        pn_as_user bash -c 'umask 077; cat > "$1"' _ "$PN_BH_DIR/.env" <<EOF
BLOODHOUND_IMAGE=specterops/bloodhound:latest
NEO4J_IMAGE=neo4j:4.4
POSTGRES_IMAGE=postgres:16
BLOODHOUND_PORT=8080
POSTGRES_PASSWORD=$postgres
NEO4J_PASSWORD=$neo4j
EOF
    fi
    # Upgrade the blank values / literal placeholders from the earlier release.
    # Preserve real custom image references, ports and all existing secrets.
    pn_as_user bash -c '
        set -e; umask 077
        file=$1
        temp=$(mktemp "${file}.XXXXXX")
        trap '\''rm -f -- "$temp"'\'' EXIT
        app_seen=0; graph_seen=0
        while IFS= read -r line || [[ -n $line ]]; do
            case "$line" in
                BLOODHOUND_IMAGE=*)
                    app_seen=1
                    case "${line#*=}" in ""|*:REVIEWED_RELEASE) line="BLOODHOUND_IMAGE=specterops/bloodhound:latest" ;; esac ;;
                NEO4J_IMAGE=*)
                    graph_seen=1
                    case "${line#*=}" in ""|*:COMPATIBLE_RELEASE) line="NEO4J_IMAGE=neo4j:4.4" ;; esac ;;
            esac
            printf "%s\n" "$line" >> "$temp"
        done < "$file"
        (( app_seen )) || printf "BLOODHOUND_IMAGE=specterops/bloodhound:latest\n" >> "$temp"
        (( graph_seen )) || printf "NEO4J_IMAGE=neo4j:4.4\n" >> "$temp"
        if cmp -s -- "$temp" "$file"; then chmod 600 -- "$file"; else mv -- "$temp" "$file"; fi
    ' _ "$PN_BH_DIR/.env"
}

pn_bh_configure() {
    local image='' graph='' port='' key value
    while (( $# )); do
        (( $# >= 2 )) || { pn_error 'configure options require values.'; return 2; }
        key=$1 value=$2; shift 2
        case "$key" in
            --image) image=$value ;;
            --graph-image) graph=$value ;;
            --port) port=$value ;;
            *) pn_error "Unknown configure option: $key"; return 2 ;;
        esac
    done
    [[ -z $image ]] || pn_image_valid "$image" || { pn_error 'Use a valid BloodHound image tag or digest.'; return 2; }
    [[ -z $graph ]] || pn_image_valid "$graph" || { pn_error 'Use an explicit compatible Neo4j image tag or digest.'; return 2; }
    [[ -z $port ]] || pn_port_valid "$port" || { pn_error 'Port must be 1024–65535.'; return 2; }
    (( PN_DRY )) && { pn_info 'Would update BloodHound configuration.'; return 0; }
    pn_lock || return
    pn_bh_prepare || return
    # Fixed shell source, with all user values passed as positional arguments.
    pn_as_user bash -c '
        set -e; umask 077
        file=$1; image=$2; graph=$3; port=$4
        temp=$(mktemp "${file}.XXXXXX")
        trap '\''rm -f -- "$temp"'\'' EXIT
        while IFS= read -r line || [[ -n $line ]]; do
            case "$line" in
                BLOODHOUND_IMAGE=*) [[ -z $image ]] || line="BLOODHOUND_IMAGE=$image" ;;
                NEO4J_IMAGE=*) [[ -z $graph ]] || line="NEO4J_IMAGE=$graph" ;;
                BLOODHOUND_PORT=*) [[ -z $port ]] || line="BLOODHOUND_PORT=$port" ;;
            esac
            printf "%s\n" "$line" >> "$temp"
        done < "$file"
        mv -- "$temp" "$file"
    ' _ "$PN_BH_DIR/.env" "$image" "$graph" "$port" || return
    if pn_bh_verify; then pn_success 'BloodHound configuration saved.'
    else pn_error 'Configuration is incomplete or invalid; inspect the port and database secret settings.'; return 1; fi
}

pn_bh_setup() {
    pn_info 'Set up BloodHound only: install its prerequisites, prepare configuration and start the server.'
    PN_REFRESHED=0
    pn_select bloodhound || return
    pn_apply install || return
    local previous_yes=$PN_YES rc
    PN_YES=1
    pn_bh_command up
    rc=$?
    PN_YES=$previous_yes
    return "$rc"
}

pn_bh_compose() {
    pn_root "${PN_COMPOSE[@]}" --project-name panoply-bloodhound \
        --project-directory "$PN_BH_DIR" --env-file "$PN_BH_DIR/.env" -f "$PN_BH_DIR/compose.yml" "$@"
}

pn_bh_choose_port() {
    local port running
    port=$(pn_bh_get BLOODHOUND_PORT)
    [[ $port == 8080 ]] || return 0
    command -v ss >/dev/null || return 0
    running=$(pn_bh_compose ps -q bloodhound 2>/dev/null) || return 1
    [[ -z $running ]] || return 0
    while ss -lntH "sport = :$port" | grep -q .; do
        ((port+=1))
        (( port <= 8100 )) || { pn_error 'No free BloodHound port in 8080–8100.'; return 1; }
    done
    if [[ $port != 8080 ]]; then
        pn_warn "Port 8080 is busy; using available port $port."
        pn_bh_configure --port "$port" || return
    fi
}

pn_bh_credentials() {
    local result=${1:-} username source password port
    port=$(pn_bh_get BLOODHOUND_PORT)
    printf '\nBloodHound login\n  URL:              http://127.0.0.1:%s\n' "$port"
    if ! command -v jq >/dev/null; then
        printf '  Username:         admin (default account)\n'
        pn_error 'jq is required to extract credentials; run install jq.'
        return 1
    fi
    # Service-specific logs are streamed in full so the initial message need not
    # be within the last 100 lines. Do not route this output through pn_run/logs.
    if [[ -z $result ]] && ! result=$(pn_bh_read_credentials); then
        printf '  Username:         admin (default account)\n'
        printf '  Initial password: unavailable (could not read application logs)\n'
        return 1
    fi
    username=$(jq -r '.username' <<< "$result") || return
    source=$(jq -r '.username_source' <<< "$result") || return
    printf '  Username:         %s (%s)\n' "$username" "$source"
    if [[ $(jq -r '.password == null' <<< "$result") == true ]]; then
        printf '  Initial password: unavailable in retained startup logs\n'
        pn_info 'No recognised initial-password message was found. Logs may have rotated or this image may use a different format. No password was reset.'
        return 1
    fi
    password=$(jq -r '.password' <<< "$result") || return
    printf '  Initial password: %s\n' "$password"
    printf '\nThis is the initial password from startup logs; it may have been changed.\n'
}

pn_bh_command() {
    local action=${1:-status}
    (( $# )) && shift
    if [[ $action == setup ]]; then
        (( $# == 0 )) || { pn_error 'bloodhound setup takes no extra arguments.'; return 2; }
        pn_bh_setup; return
    fi
    if [[ $action == configure ]]; then pn_bh_configure "$@"; return; fi
    (( $# == 0 )) || { pn_error 'Unexpected BloodHound arguments.'; return 2; }
    case "$action" in up|down|status|logs|credentials) ;; *) pn_error 'Use bloodhound configure, up, down, status, logs or credentials.'; return 2 ;; esac
    if (( PN_DRY )); then pn_info "Would run BloodHound $action using $PN_BH_DIR/compose.yml"; return 0; fi
    pn_bh_verify || { pn_error 'Run bloodhound setup for automatic standalone installation and configuration.'; return 1; }
    pn_docker_verify || { pn_error 'Docker and Compose are not ready; run doctor docker.'; return 1; }
    case "$action" in
        status) pn_bh_compose ps ;;
        logs) pn_bh_compose logs --tail 100 ;;
        credentials) pn_bh_credentials ;;
        down) pn_confirm && pn_lock && pn_log_init && pn_run 'Stop BloodHound (retain volumes)' pn_bh_compose down ;;
        up) pn_bh_start_session ;;
    esac
}

# Doctor never elevates privileges or starts services. Report inaccessible state honestly.
pn_bh_observe() {
    local running port
    PN_STATUS=configured
    PN_DETAILS='Configuration valid; live service not verified.'
    if ! pn_docker_verify; then
        PN_DETAILS+=' Docker/Compose client unavailable.'; return 0
    fi
    if ! timeout 10 docker info >/dev/null 2>&1; then
        PN_DETAILS+=' Docker daemon stopped or inaccessible to this user (no sudo attempted).'; return 0
    fi
    running=$(timeout 10 "${PN_COMPOSE[@]}" --project-name panoply-bloodhound \
        --project-directory "$PN_BH_DIR" --env-file "$PN_BH_DIR/.env" -f "$PN_BH_DIR/compose.yml" \
        ps -q bloodhound 2>/dev/null) || { PN_DETAILS+=' Cannot inspect the Compose project.'; return 0; }
    if [[ -z $running ]]; then PN_DETAILS+=' BloodHound container is not running.'; return 0; fi
    port=$(pn_bh_get BLOODHOUND_PORT)
    if curl --fail --silent --max-time 2 "http://127.0.0.1:$port/" >/dev/null; then
        PN_STATUS=ready; PN_DETAILS="BloodHound container present and HTTP responding on 127.0.0.1:$port."
    else PN_STATUS=broken; PN_DETAILS='BloodHound container present but HTTP is not ready.'; fi
}

pn_bh_read_credentials() {
    pn_bh_compose logs --no-color bloodhound 2>/dev/null | jq -Rn -f "$PN_ROOT/lib/bh-credentials.jq"
}

# Subshell keeps session signal handlers separate from the menu handlers.
pn_bh_start_session() (
    PN_BH_STOP=0
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'pn_bh_session_cleanup "$PN_BH_STOP" "$?"' EXIT
    pn_confirm && pn_platform_check && pn_lock && pn_log_init || return
    # Refresh old managed templates, retaining database secrets and volumes.
    pn_bh_prepare || return
    pn_run 'Validate Compose configuration' pn_bh_compose config --quiet || return
    if ! pn_root docker info >/dev/null 2>&1; then
        pn_run 'Start Docker daemon' pn_root systemctl start docker || return
    fi
    pn_bh_choose_port || return
    [[ ! -t 0 ]] || PN_BH_STOP=1
    pn_run 'Start BloodHound' pn_bh_compose up -d || return
    # Check the app via HTTP; detached container launch alone is not readiness.
    local port attempt credentials_shown=0 result
    port=$(pn_bh_get BLOODHOUND_PORT)
    for ((attempt=0;attempt<60;attempt++)); do
        if (( ! credentials_shown )); then
            result=$(pn_bh_read_credentials) || result=''
            if [[ -n $result ]] && jq -e '.password != null' <<< "$result" >/dev/null; then
                pn_bh_credentials "$result" && credentials_shown=1
            fi
        fi
        if curl --fail --silent --max-time 2 "http://127.0.0.1:$port/" >/dev/null; then
            pn_success 'BloodHound is ready.'
            if (( ! credentials_shown )); then
                if pn_bh_credentials; then credentials_shown=1
                else pn_warn 'Initial password could not be recovered from retained logs; no password reset.'; fi
            fi
            if (( PN_BH_STOP )); then
                pn_info 'BloodHound is running. Press Ctrl+C to stop its containers (volumes and logs retained).'
                while :; do
                    sleep 2
                    if (( ! credentials_shown )); then
                        result=$(pn_bh_read_credentials) || result=''
                        if [[ -n $result ]] && jq -e '.password != null' <<< "$result" >/dev/null; then
                            pn_bh_credentials "$result" && credentials_shown=1
                        fi
                    fi
                done
            fi
            return 0
        fi
        sleep 2
    done
    pn_error 'BloodHound did not become HTTP-ready within the startup window; inspect bloodhound logs.'
    return 1
)

pn_bh_session_cleanup() {
    local stop=$1 rc=$2
    trap '' INT TERM
    if (( stop )); then
        pn_info 'Stopping BloodHound containers; database volumes and startup logs retained.'
        pn_bh_compose stop || { pn_error 'Could not stop BloodHound; run panoply bloodhound down.'; rc=1; }
    fi
    pn_finish
    return "$rc"
}
