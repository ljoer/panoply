# Panoply

Bash tool installer for Kali Linux.

![Panoply terminal demo](assets/panoply-kali-terminal.gif)

## Install or update

Extract or clone this repository, open a terminal in its directory, then run:

```bash
sudo bash install.sh
panoply version
panoply
```

If your shell selects another copy, check `type -a panoply` or run
`/usr/local/bin/panoply` explicitly.

## Manual

Besides the menu, you can run it like this:

```text
panoply [options] command [profile|tool ...]
```

| Command | Purpose |
| --- | --- |
| `menu` | Interactive menu; default when no command is given |
| `list [selection]` | Browse tools; defaults to `all` |
| `doctor [selection]` | Inspect current packages, executables and readiness |
| `plan [selection]` | Preview installation actions |
| `install [selection]` | Install missing tools and verify them |
| `repair [selection]` | Reinstall/rebuild selected tools |
| `update [selection]` | Update installed selected tools |
| `remove selection` | Remove eligible tools; keep package configuration |
| `purge selection` | Also remove package-managed configuration |
| `bloodhound setup` | Install prerequisites, configure and start BloodHound |
| `bloodhound up` | Start the configured BloodHound project |
| `bloodhound down` | Stop/remove its containers; retain database volumes |
| `bloodhound status` | Show container status |
| `bloodhound logs` | Show recent logs |
| `bloodhound credentials` | Retrieve initial login from retained logs; never reset it |
| `system update` | Refresh Kali package metadata |
| `system upgrade` | Explicit system upgrade |
| `nuclei templates` | Update Nuclei templates |
| `nmap scripts` | Update the Nmap script database |
| `banner`, `version`, `help` | Show branding, version or help |

Selection defaults to `core` for plan, doctor and installation commands.
Profiles: `core`, `infra`, `web`, `recon`, `credentials`, `desktop`, `development`, `all`.
Combine profiles and tool names, for example `panoply install infra chisel`.

## Options

`--dry-run` previews changes. `--yes` skips confirmation. `--json` formats doctor
output. `--no-color` and `--no-animation` disable terminal effects.
`--include-untracked` selects removal regardless of origin.

## Removal modes

Menu option 6 offers:

1. **Undo Panoply installs:** only recorded installs or ownership recovered from
   explicit new-package entries in retained Panoply installation logs.
2. **Remove selected tools regardless of origin:** also include selected
   pre-existing tools. CLI equivalent: `--include-untracked`.

```bash
panoply --dry-run remove all
panoply remove all
panoply --include-untracked purge chisel
```

Both modes preview dependencies and preserve shared/system components, user data,
extra executable copies and BloodHound volumes. Conflicting packages are skipped;
independently safe removals can proceed. No autoremove is run. Missing ownership
evidence is not guessed. Recovered ownership is saved before removal.

`remove` keeps package configuration; `purge` deletes it too. Neither deletes
personal configuration or database volumes. For managed Go binaries, both delete
the executable and its ownership marker. Doctor still reports preserved tools.

## BloodHound

```bash
panoply bloodhound setup
panoply bloodhound credentials
```

Interactive setup/up displays the initial login when available and stays attached.
**Ctrl+C stops BloodHound containers**, retaining volumes and logs. It does not
stop the shared Docker daemon. Missing/rotated credential logs cannot be recovered
by resetting a password automatically.

For background startup: `panoply --yes bloodhound up </dev/null`.
Stop it explicitly with `panoply bloodhound down`.

Optional configuration:

```bash
panoply bloodhound configure --port 8090
# Also accepts --image IMAGE:TAG and --graph-image IMAGE:TAG
```

Docker uses Kali's `docker.io` and `docker-cli`, with `docker compose` or
`docker-compose`. Existing database secrets and volumes are preserved.

## Go tools

Kerbrute, Sourcemapper and github-subdomains build from upstream Go modules.
Prerequisites are installed automatically. Example: `panoply install github-subdomains`.
GitHub searches require a token; installation and doctor do not.

## Files and exit status

- Application: `/usr/local/lib/panoply/releases/`; launcher: `/usr/local/bin/panoply`.
- Logs: `~/.local/state/panoply/`; data: `~/.local/share/panoply/`.
- Package ownership: `/var/lib/panoply/packages/`.
- Exit `0`: successful operation or nothing eligible; `1`: failure/incomplete
  result; `2`: usage/platform error; `130`/`143`: interrupted/terminated.
