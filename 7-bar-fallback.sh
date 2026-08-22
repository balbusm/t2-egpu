#!/usr/bin/env bash
# 7-bar-fallback.sh - fallback when BAR1 came out unassigned. Called by
# 6-load-driver.sh, not run directly in a normal bring-up.
#
# WHAT IT DOES
#
# Shrinks BAR1 through ReBAR so the request fits, then escalates the level the
# kernel reallocates from. A rescan only reassigns resources below the bridge
# it starts from, so each level detaches a larger subtree:
#
#   level 1  detach the enclosure, rescan from the host-side Thunderbolt port
#   level 2  detach the Thunderbolt controller subtree, rescan from the root port
#   level 3  the same, but a global rescan - last resort
#
# The ladder is DERIVED from the discovered chain (lib/egpu-lib.sh), so it
# adapts to a different machine, enclosure or Thunderbolt port.

set -uo pipefail

SELFDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # the package is self-locating
# shellcheck source=lib/egpu-lib.sh
source "$SELFDIR/lib/egpu-lib.sh"
if ! egpu_resolve "${GPU:-}"; then
    echo "Cannot resolve eGPU topology. Run ./2-devices.sh to see what is present." >&2
    exit 1
fi


DEV=$EGPU_GPU
CAP=0xbb0
TARGET_BAR=1
TARGET_SIZE=6                 # 2^6 MB = 64 MB
EXP_CAP_ID=0x0015

LOGDIR=$SELFDIR/logs
STAMP=$(date +%Y%m%d-%H%M%S)
KLOG=$LOGDIR/kernel-$STAMP.log
SLOG=$LOGDIR/script-$STAMP.log

[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo $0" >&2; exit 1; }
[[ -d /sys/bus/pci/devices/$DEV ]] || {
    echo "ERROR: $DEV does not exist - plug the enclosure in." >&2; exit 1; }

mkdir -p "$LOGDIR"; chown "${SUDO_USER:-root}:" "$LOGDIR" 2>/dev/null || true
exec > >(tee -a "$SLOG") 2>&1

BG=()
cleanup() { for p in "${BG[@]:-}"; do kill "$p" 2>/dev/null || true; done; sync; }
trap cleanup EXIT

mark() { printf '\n########## %s ##########\n' "$1" >> "$KLOG"; sync; echo ">>> $1"; }

echo "=== logi ==="
echo "  kernel:  $KLOG"
echo "  log: $SLOG"

stdbuf -oL dmesg -w >> "$KLOG" &  BG+=($!)
( while :; do sync; sleep 0.2; done ) & BG+=($!)
sleep 1

rd() { setpci -s "$DEV" "$(printf '%x' $1).L" 2>/dev/null; }

rebar_entry_off() {
    local hdr cap_id ctrl0 n i off v
    hdr=$((16#$(rd $CAP))); cap_id=$((hdr & 0xffff))
    (( cap_id == EXP_CAP_ID )) || return 1
    ctrl0=$((16#$(rd $((CAP + 0x08))))); n=$(( (ctrl0 >> 5) & 0x7 ))
    for ((i = 0; i < n; i++)); do
        off=$((CAP + 0x08 + 8 * i)); v=$((16#$(rd $off)))
        (( (v & 0x7) == TARGET_BAR )) && { echo $off; return 0; }
    done
    return 1
}

# Set BAR1 to 64 MB if it is not already. Returns 0 when, on exit,
# the card reports 64 MB. A bridge reset can restore 256 MB, which is why
# called before EVERY attempt.
apply_rebar() {
    local off cur new back got
    off=$(rebar_entry_off) || { echo "  ERROR: no ReBAR capability entry for BAR1"; return 1; }
    cur=$(( ($((16#$(rd $off))) >> 8) & 0x3f ))
    if (( cur == TARGET_SIZE )); then
        echo "  ReBAR BAR1 already = 64 MB"
        return 0
    fi
    echo "  ReBAR BAR1 = $((2 ** cur)) MB -> ustawiam 64 MB"
    new=$(( ($((16#$(rd $off))) & ~0x00003f00) | (TARGET_SIZE << 8) ))
    setpci -s "$DEV" "$(printf '%x' $off).L=$(printf '%08x' $new)" || return 1
    back=$((16#$(rd $off))); got=$(( (back >> 8) & 0x3f ))
    (( got == TARGET_SIZE )) || { echo "  ERROR: the card did not accept the size"; return 1; }
    echo "  confirmed: 64 MB"
}

bar1_assigned() {
    local v
    [[ -f /sys/bus/pci/devices/$DEV/resource ]] || return 1
    v=$(awk 'NR==2 { print $1 }' /sys/bus/pci/devices/$DEV/resource)
    [[ $v != 0x0000000000000000 ]]
}

show_state() {
    echo "  --- BAR-y ---"
    awk 'NR<=4 { printf "    BAR%d start=%s flags=%s\n", NR-1, $1, $3 }' \
        /sys/bus/pci/devices/$DEV/resource 2>/dev/null || echo "    device not present"
    echo "  --- window prefetchable ---"
    # Walk the card's real ancestor chain instead of a written-down list -
    # the chain differs per machine and per Thunderbolt port.
    while read -r b; do
        [[ -z $b ]] && continue
        printf "    %s: %s\n" "$b" \
            "$(lspci -vv -s "${b#*:}" 2>/dev/null | grep -i 'Prefetchable' | sed 's/^\s*//' || echo '?')"
    done < <(egpu_ancestors "$DEV")
}

# --- escalation ladder, DERIVED from the discovered chain ---
#
# "description|device to remove|what to rescan". Each level detaches a larger
# subtree, because a rescan only reassigns resources below the bridge it starts
# from. GLOBAL is the last resort.
#
# The chain from the card upwards is, for example:
#   GPU -> enclosure downstream -> enclosure upstream -> host TB port -> ...
#          -> host TB upstream -> root port
# so level 1 detaches the enclosure and rescans from the host-side TB port,
# level 2 detaches everything below the root port.
mapfile -t CHAIN < <(egpu_ancestors "$DEV")
ENCLOSURE=${CHAIN[1]:-${CHAIN[0]:-}}      # enclosure upstream port
HOST_PORT=${CHAIN[2]:-$EGPU_ROOT_PORT}    # host-side TB downstream port
LEVELS=()
[[ -n $ENCLOSURE && -n $HOST_PORT ]] && \
    LEVELS+=("level 1: detach enclosure, rescan $HOST_PORT|$ENCLOSURE|$HOST_PORT")
[[ -n $EGPU_TB_UPSTREAM ]] && \
    LEVELS+=("level 2: detach TB controller subtree, rescan $EGPU_ROOT_PORT|$EGPU_TB_UPSTREAM|$EGPU_ROOT_PORT")
[[ -n $EGPU_TB_UPSTREAM ]] && \
    LEVELS+=("level 3: detach TB controller subtree, global rescan|$EGPU_TB_UPSTREAM|GLOBAL")
if (( ${#LEVELS[@]} == 0 )); then
    echo "Cannot build an escalation ladder - topology too shallow." >&2
    exit 1
fi
echo "Escalation ladder for $DEV:"
printf '  %s\n' "${LEVELS[@]%%|*}"

for spec in "${LEVELS[@]}"; do
    IFS='|' read -r desc rmdev scan <<< "$spec"
    echo
    echo "=============================================================="
    echo "$desc"
    echo "=============================================================="

    if [[ ! -d /sys/bus/pci/devices/$DEV ]]; then
        echo "  card disappeared - aborting"
        break
    fi

    apply_rebar || { echo "  cannot set ReBAR, aborting"; break; }

    mark "BEFORE remove ($rmdev)"
    if [[ -d /sys/bus/pci/devices/$rmdev ]]; then
        echo 1 > /sys/bus/pci/devices/$rmdev/remove
    else
        echo "  $rmdev does not exist - skipping remove"
    fi
    sleep 2
    mark "AFTER remove ($rmdev)"

    mark "BEFORE rescan ($scan)"
    if [[ $scan == GLOBAL ]]; then
        echo 1 > /sys/bus/pci/rescan
    else
        echo 1 > /sys/bus/pci/devices/$scan/rescan
    fi
    sleep 4
    mark "AFTER rescan ($scan)"

    echo
    show_state

    if bar1_assigned; then
        echo
        echo "=============================================================="
        echo "  SUCCESS at this level"
        echo "=============================================================="
        lspci -vv -s "$DEV" 2>/dev/null | grep -E "Region" | sed 's/^/  /'
        cat <<'EOF'

  Do NOT load the driver from inside GNOME - switch to a text console:
    sudo systemctl isolate multi-user.target
    sudo modprobe nvidia
    nvidia-smi

  If it hangs: the blacklist in /etc/modprobe.d keeps the driver out on the next boot
  guarantees a clean next boot, and the log is in:
EOF
        echo "    $KLOG"
        sync
        exit 0
    fi

    echo "  BAR1 still unassigned - escalating"
done

echo
echo "=============================================================="
echo "  No escalation level managed to assign BAR1."
echo "=============================================================="
echo "  Log kernel: $KLOG"
echo "  Look for 'can't assign' after the last rescan marker."
sync
