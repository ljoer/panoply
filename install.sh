#!/usr/bin/env bash
#application installation, does not installtools
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
prefix=/usr/local
if [[ ${1:-} == --prefix && $# == 2 ]]; then prefix=${2%/}; elif (( $# )); then
    printf 'Usage: bash install.sh [--prefix /absolute/path]\n' >&2; exit 2
fi
[[ $prefix == /* && $prefix != / ]] || { printf 'Choose an absolute non-root prefix.\n' >&2; exit 2; }
[[ ! -e $prefix/bin/panoply || -L $prefix/bin/panoply ]] || { printf 'Refusing to replace an unrelated regular file at %s/bin/panoply\n' "$prefix" >&2; exit 1; }
if (( EUID != 0 )) && [[ ! -d $prefix || ! -w $prefix ]]; then
    printf 'Run with sudo for %s, or choose --prefix "$HOME/.local".\n' "$prefix" >&2; exit 1
fi
release=$(cat "$root/VERSION")-$(date -u +%Y%m%dT%H%M%SZ)-$$
base=$prefix/lib/panoply/releases
mkdir -p -- "$base" "$prefix/bin"
stage=$(mktemp -d "$base/.stage.XXXXXX")
link=$prefix/bin/.panoply.$$
trap 'rm -rf -- "$stage"; rm -f -- "$link"' EXIT
for entry in bin lib config profiles assets LICENSE NOTICE README.md VERSION; do
    cp -R -- "$root/$entry" "$stage/"
done
chmod -R a+rX -- "$stage"
chmod 755 -- "$stage" "$stage/bin/panoply" "$stage/assets/logo.sh"
dest=$base/$release
mv -- "$stage" "$dest"
ln -s -- "$dest/bin/panoply" "$link"
mv -Tf -- "$link" "$prefix/bin/panoply"
printf 'Installed %s/bin/panoply\nSource/configuration: %s\n' "$prefix" "$dest"
printf 'Previous releases remain under %s for manual rollback.\n' "$base"
