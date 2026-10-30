# shellcheck shell=bash
# Shared process, privilege and state services. Sourcing has no side effects.
pn_tint() {
    local kind=$1 text=$2 fd=${3:-1} color
    case "$kind" in
        success|ready) color='38;2;80;210;150' ;;
        warning|missing|needs-config|partial|external|residual|configured) color='38;2;245;195;90' ;;
        error|broken) color='38;2;255;105;115' ;;
        skip) color='38;2;155;175;200' ;;
        *) color='38;2;85;167;255' ;;
    esac
    if [[ ${PN_COLOR:-0} == 1 && -t $fd ]]; then
        printf '\033[%sm%s\033[0m' "$color" "$text" >&"$fd"
    else
        printf '%s' "$text" >&"$fd"
    fi
}

pn_message() {
    local kind=$1 label=$2
    shift 2
    pn_tint "$kind" "$label  $*" 2
    printf '\n' >&2
}
pn_error() { pn_message error ERROR "$@"; }
pn_info() { pn_message info INFO "$@"; }
pn_success() { pn_message success DONE "$@"; }
pn_warn() { pn_message warning WARNING "$@"; }
pn_skip() { pn_message skip SKIPPED "$@"; }

pn_init() {
    PN_DRY=0 PN_YES=0 PN_COLOR=1 PN_ANIMATE=1 PN_REFRESHED=0
    PN_RESOLVE_DEPS=1 PN_INCLUDE_UNTRACKED=0
    PN_LOG='' PN_LOCKED=0
    PN_USER=${SUDO_USER:-$(id -un)}
    local record
    record=$(getent passwd "$PN_USER") || { pn_error 'Cannot resolve the invoking user.'; return 2; }
    IFS=: read -r PN_USER _ PN_UID PN_GID _ PN_HOME _ <<< "$record"
    [[ $PN_HOME == /* ]] || { pn_error 'User home must be absolute.'; return 2; }
    PN_STATE=${PANOPLY_STATE_DIR:-$PN_HOME/.local/state/panoply}
    PN_DATA=${PANOPLY_DATA_DIR:-$PN_HOME/.local/share/panoply}
    PN_TOOL_BIN=${PANOPLY_BIN_DIR:-/usr/local/bin}
    PN_MANAGED=${PANOPLY_MANAGED_DIR:-/var/lib/panoply}
    [[ $PN_STATE == /* && $PN_DATA == /* && $PN_TOOL_BIN == /* && $PN_MANAGED == /* ]] || { pn_error 'Application paths must be absolute.'; return 2; }
    [[ -t 2 && -z ${NO_COLOR+x} && ${TERM:-dumb} != dumb ]] || PN_COLOR=0
    PN_BH_DIR=$PN_DATA/bloodhound
    declare -gA PN_PROVIDER=() PN_SPEC=() PN_CHECKS=() PN_PROBE=() PN_DESC=() PN_DEPS=()
    declare -ga PN_IDS=() PN_SELECTED=() PN_PACKAGES=() PN_COMPOSE=()
    declare -gA PN_VISITING=() PN_SEEN=() PN_RECOVERED=()
}

pn_as_user() {
    if (( EUID == 0 && PN_UID != 0 )); then
        runuser -u "$PN_USER" -- env HOME="$PN_HOME" "$@"
    else
        "$@"
    fi
}

pn_root() {
    if (( EUID == 0 )); then "$@"; else sudo -- "$@"; fi
}

pn_platform_check() {
    [[ $(uname -s) == Linux ]] || { pn_error 'Installation requires Kali Linux.'; return 2; }
    local id
    id=$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')
    [[ $id == kali ]] || { pn_error 'Installation is supported on Kali Linux only; list, plan and doctor remain available.'; return 2; }
}

pn_lock() {
    (( PN_LOCKED )) && return 0
    (( PN_DRY )) && return 0
    command -v flock >/dev/null || { pn_error 'flock is required (util-linux).'; return 2; }
    pn_as_user mkdir -p -- "$PN_STATE" || return 1
    pn_as_user touch -- "$PN_STATE/install.lock" || return 1
    exec 9>"$PN_STATE/install.lock" || return 1
    flock -n 9 || { pn_error 'Another Panoply operation is running.'; return 1; }
    PN_LOCKED=1
}

pn_log_init() {
    (( PN_DRY )) && return 0
    PN_LOG=$PN_STATE/$(date -u +%Y%m%dT%H%M%SZ)-$$.log
    pn_as_user bash -c 'umask 077; : > "$1"' _ "$PN_LOG" || return 1
    pn_info "Log: $PN_LOG"
}

pn_run() {
    local description=$1 rc
    shift
    pn_info "==> $description"
    if (( PN_DRY )); then
        printf '    ' >&2; printf '%q ' "$@" >&2; printf '\n' >&2
        return 0
    fi
    if [[ -n $PN_LOG ]]; then
        printf '\n==> %s\n' "$description" >> "$PN_LOG"
        "$@" 2>&1 | tee -a "$PN_LOG" >&2
        local results=("${PIPESTATUS[@]}")
        rc=${results[0]}
        (( rc == 0 && results[1] != 0 )) && rc=${results[1]}
    else
        "$@" >&2
        rc=$?
    fi
    if (( rc == 0 )); then
        pn_success "$description"
    else
        pn_error "$description failed (exit $rc)."
    fi
    return "$rc"
}

pn_confirm() {
    (( PN_YES || PN_DRY )) && return 0
    [[ -t 0 ]] || { pn_error 'Use --yes for unattended changes, or use plan first.'; return 2; }
    local answer
    read -r -p 'Apply this plan? [y/N] ' answer || return 1
    [[ $answer == y || $answer == Y ]]
}

pn_finish() {
    if (( PN_LOCKED )); then flock -u 9; exec 9>&-; PN_LOCKED=0; fi
    [[ -t 2 && ${PN_COLOR:-0} == 1 ]] && printf '\033[0m\033[?25h' >&2
    return 0
}
