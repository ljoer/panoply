#!/usr/bin/env bash
# Original blue-and-white PANOPLY logo. Bash 3.2+ and sleep.
# Run: bash logo.sh [--static] [--no-color]
# Uses UTF-8 block characters and ANSI truecolor in interactive terminals.

still=0
color=1
for arg in "$@"; do
    case "$arg" in
        --static) still=1 ;;
        --no-color) color=0 ;;
        --help) printf 'Usage: bash %s [--static] [--no-color]\n' "${0##*/}"; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$arg" >&2; exit 1 ;;
    esac
done

if [[ ! -t 1 || ${TERM:-dumb} == dumb ]]; then
    printf 'PANOPLY\n'
    exit 0
fi
[[ -n ${NO_COLOR+x} ]] && color=0
cols=$(tput cols 2>/dev/null) || cols=${COLUMNS:-80}
case "$cols" in ''|*[!0-9]*) cols=80 ;; esac
if (( cols < 43 )); then
    printf 'PANOPLY\n'
    exit 0
fi

word=PANOPLY
rows=('' '' '' '' '' '' '')
for (( i=0; i<${#word}; i++ )); do
    case "${word:i:1}" in
        P) mask='11110/11001/11001/11110/11000/11000/11000' ;;
        A) mask='01110/11011/11011/11111/11011/11011/11011' ;;
        N) mask='11001/11101/11101/11011/11011/11001/11001' ;;
        O) mask='01110/11011/11011/11011/11011/11011/01110' ;;
        L) mask='11000/11000/11000/11000/11000/11000/11111' ;;
        Y) mask='11011/11011/11011/01110/00100/00100/00100' ;;
    esac
    IFS=/ read -r -a glyph <<< "$mask"
    for (( y=0; y<7; y++ )); do rows[y]+=${glyph[y]}0; done
 done

palette=('241;248;255' '241;248;255' '208;231;255' '103;180;255' '47;139;255' '30;102;245' '22;70;186')
# Match the menu's two-column indent, independent of terminal width.
pad=2
printf -v margin '%*s' "$pad" ''
esc=$'\033'
reset="${esc}[0m"
# Invoked by the EXIT trap.
# shellcheck disable=SC2329
restore_cursor() { printf '\033[0m\033[?25h'; }
trap restore_cursor EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
printf '\033[?25l'

frames=40
(( still )) && frames=1
for (( f=0; f<frames; f++ )); do
    t=$(( f*1000/39 ))
    (( still )) && t=1000
    frame=''
    (( f )) && frame+="${esc}[9A"
    frame+=$'\r\033[2K\n'
    for (( y=0; y<7; y++ )); do
        frame+=$'\r\033[2K'
        frame+=$margin
        (( color )) && frame+="${esc}[38;2;${palette[y]}m"
        shift=0
        (( t>430 && t<560 && y==3 )) && shift=2
        for (( x=0; x<41; x++ )); do
            sx=$(( x-shift ))
            pixel=0
            if (( sx>=0 )) && [[ ${rows[y]:sx:1} == 1 ]]; then pixel=1; fi
            visible=0
            (( t>760 || t>x*600/41+y*24 )) && visible=1
            (( t<240 && (x*7+y*13+f)%5>1 )) && visible=0
            if (( pixel && visible )); then frame+='█'; else frame+=' '; fi
        done
        (( color )) && frame+=$reset
        frame+=$'\n'
    done
    frame+=$'\r\033[2K\n'
    printf '%s' "$frame"
    (( still )) || sleep 0.04
done
exit 0
