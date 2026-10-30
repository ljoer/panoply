# shellcheck shell=bash
pn_banner() {
    printf '  Pentest workstation provisioning · %s\n\n' "$(cat "$PN_ROOT/VERSION")"
}

pn_menu() {
    [[ -t 0 && -t 1 ]] || { pn_help; return 0; }
    local choice rc=0
    if (( PN_ANIMATE && PN_COLOR )); then
        bash "$PN_ROOT/assets/logo.sh" || return
    fi
    while true; do
        pn_banner
        printf '  1  Check installed tools (doctor)\n  2  Install a profile\n  3  Repair a profile\n  4  Browse available tools\n  5  Set up/start BloodHound only\n  6  Remove or purge tools\n  Q  Quit\n\n'
        read -r -p 'Choose: ' choice || return 0
        case "$choice" in
            1) pn_menu_select && pn_doctor no; rc=$? ;;
            2) pn_menu_select && pn_apply install; rc=$? ;;
            3) pn_menu_select && pn_apply repair; rc=$? ;;
            4) pn_select all && pn_list; rc=$? ;;
            5) pn_bh_setup; rc=$? ;;
            6) pn_remove_menu; rc=$? ;;
            q|Q) return 0 ;;
            *) pn_info 'Choose 1–6 or Q.'; continue ;;
        esac
        pn_finish
        (( rc == 0 )) || pn_warn "Operation finished with status $rc; review the output above."
        read -r -p 'Press Enter to continue… ' choice || return 0
        printf '\n'
    done
}

pn_menu_select() {
    local profile
    printf 'Profiles: core, infra, web, recon, credentials, desktop, development, all\n'
    read -r -p 'Profile [core]: ' profile || return 1
    PN_REFRESHED=0
    pn_select "${profile:-core}"
}

pn_list() {
    local id
    printf '%-23s %-12s %s\n' TOOL PROVIDER DESCRIPTION
    for id in "${PN_SELECTED[@]}"; do
        printf '%-23s %-12s %s\n' "$id" "${PN_PROVIDER[$id]}" "${PN_DESC[$id]}"
    done
}

pn_help() {
    cat <<'HELP'
Panoply — Kali pentest workstation provisioning

Usage: panoply [options] command [profile|tool ...]

  menu                    Interactive menu (default on a terminal)
  list [selection]        Show tools; defaults to all
  plan [selection]        Preview install/skip/repair actions; defaults to core
  doctor [selection]      Verify installed packages and offline CLI startup
  install [selection]     Install missing tools; verify the result
  remove tool|profile     Remove owned tools (including recovered log evidence)
  purge tool|profile      Also remove package configuration
  repair [selection]      Reinstall selected packages and verify them
  update [selection]      Explicitly update installed tools (does not install missing tools)
  system update           Refresh Kali package metadata
  system upgrade          Explicit full system upgrade; never reboots automatically
  nuclei templates        Explicitly update Nuclei templates as the invoking user
  nmap scripts            Explicitly refresh the Nmap script database
  bloodhound setup        Install/configure/start BloodHound only
  bloodhound configure --image REF --graph-image REF [--port PORT]
  bloodhound up|down|status|logs|credentials
                          Interactive up/setup: Ctrl+C stops BloodHound containers
  banner                  Show the blue/white animated logo
  version                 Show application version

Options: --yes, --dry-run, --no-color, --no-animation, --json (doctor only)
         --include-untracked (explicitly include pre-existing tools in remove/purge)
Profiles: core, infra, web, recon, credentials, desktop, development, all
Combine profiles/tools: panoply plan infra web chisel

Run as your normal Kali user. Only system changes invoke sudo.
NO_COLOR disables colours. Piped output has no animation or ANSI colours.
Install/repair/update log to ~/.local/state/panoply and return nonzero on failure.
HELP
}
