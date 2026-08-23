#!/usr/bin/env bash
# 02-devices.sh - list external GPU candidates and the topology behind each.
#
# Read-only. Safe to run at any time, root not required.
#
# WHY YOU MIGHT NEED IT
#
# run.sh auto-detects the card and needs no arguments when exactly one
# display controller sits behind a Thunderbolt/USB4 tunnel. Run this when:
#
#   * auto-detection reports more than one candidate and asks you to choose
#   * the card is not detected at all and you want to see what the kernel sees
#   * you want the exact GPU=<bdf> string to paste into another command
#
# USAGE
#   ./scripts/02-devices.sh            candidates plus their topology
#   ./scripts/02-devices.sh --all      every display controller, including internal ones

set -uo pipefail
SELFDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/egpu-lib.sh
source "$SELFDIR/../lib/egpu-lib.sh"

MODE=candidates
for a in "$@"; do case $a in
    --all) MODE=all ;;
    -h|--help) egpu_usage "$0"; exit 0 ;;
    *) echo "Unknown argument: $a" >&2; exit 2 ;;
esac; done

if [[ $MODE == all ]]; then
    echo "All display controllers on this machine:"
    printf '  %-14s %-8s %-9s %s\n' ADDRESS VENDOR LOCATION DESCRIPTION
    while IFS='|' read -r bdf vid vname where desc; do
        [[ -z $bdf ]] && continue
        printf '  %-14s %-8s %-9s %s\n' "$bdf" "$vname" "$where" "${desc:0:56}"
    done < <(egpu_all_display)
    echo
    echo "Only 'tunneled' entries are eGPU candidates. A 'local' card is on a"
    echo "physical slot inside the machine - this package does not touch those."
    exit 0
fi

mapfile -t CAND < <(egpu_candidates)

if (( ${#CAND[@]} == 0 )); then
    echo "No display controller found behind a Thunderbolt/USB4 tunnel."
    echo
    echo "Things to check, in order:"
    echo "  1. Is the enclosure powered on and the cable seated?"
    echo "     Power-cycle the enclosure; a warm reboot often drops the tunnel."
    echo "  2. Is the tunnel authorised?   boltctl list"
    echo "     Status must say 'connected', not 'disconnected'."
    echo "  3. Does the kernel see anything new?   lspci -t"
    echo "  4. Is the card on a physical slot rather than a tunnel?"
    echo "     $EGPU_SCRIPTS/02-devices.sh --all"
    exit 1
fi

echo "Found ${#CAND[@]} external GPU candidate(s)."
for line in "${CAND[@]}"; do
    IFS='|' read -r bdf vid vname desc <<<"$line"
    echo
    echo "-------------------------------------------------------------------"
    echo "  $vname  $bdf"
    echo "  $desc"
    echo "-------------------------------------------------------------------"
    if egpu_resolve "$bdf" >/dev/null 2>&1; then
        egpu_print_topology
    else
        echo "  topology could not be resolved"
    fi
    b1=$(egpu_bar_size "$bdf" 1)
    printf '  %-14s %s\n' "BAR1 now" "${b1:-unassigned}"
    drv=$(basename "$(readlink -f "$PCI_DEVICES/$bdf/driver" 2>/dev/null)" 2>/dev/null)
    printf '  %-14s %s\n' "driver" "${drv:-none bound}"
    echo "  chain (card -> host):"
    printf '      %s\n' "$bdf"
    while read -r a; do
        [[ -z $a ]] && continue
        printf '      %s  %s\n' "$a" "$(lspci -s "${a#*:}" 2>/dev/null | cut -d: -f3- | cut -c1-46)"
    done < <(egpu_ancestors "$bdf")
done

echo
if (( ${#CAND[@]} == 1 )); then
    echo "One candidate, so no argument is needed:"
    echo "    sudo ./run.sh"
else
    echo "More than one candidate - name the card explicitly:"
    for line in "${CAND[@]}"; do
        echo "    sudo GPU=$(cut -d'|' -f1 <<<"$line") ./run.sh"
    done
fi
