#!/usr/bin/env bash
# egpu-lib.sh - shared topology discovery. Source this; do not run it.
#
# WHY THIS EXISTS
#
# Everything this package does depends on four addresses that differ per
# machine, per Thunderbolt port, and even per hot-plug (bus numbers behind a
# TB tunnel shift when hpbussize changes or another device is attached):
#
#   GPU          the display controller behind the tunnel
#   BRIDGE       its immediate parent - the port whose link speed we cap
#   ROOT_PORT    the CPU root port at the top of the chain - the window we move
#   TB_UPSTREAM  the first device below the root port - what we remove/rescan
#
# Hardcoding them makes the package work on exactly one machine on exactly one
# port. Everything below derives them from sysfs instead.
#
# DISCOVERY RULES
#
#   GPU          PCI class 0x03xx (display controller) that has at least one
#                ancestor whose lspci description says Thunderbolt or USB4.
#                Vendor-agnostic: NVIDIA, AMD and Intel are all recognised.
#   BRIDGE       parent directory in the sysfs device tree.
#   ROOT_PORT    walk up until the parent directory is the host bridge
#                (pci0000:00); the last PCI device seen is the root port.
#   TB_UPSTREAM  the only real child of the root port (":pcieNNN" pseudo
#                devices are filtered out).
#   rescan path  /sys/bus/pci/devices/<ROOT_PORT>/pci_bus/<secondary>/rescan
#                where <secondary> comes from the root port's pci_bus/ entry.
#                Never devices/<ROOT_PORT>/rescan - that rescans the bus the
#                root port SITS ON (bus 00) and hangs the machine.

PCI_DEVICES=${PCI_DEVICES:-/sys/bus/pci/devices}

# Known GPU vendors. Extend here if needed.
egpu_vendor_name() {
    case "${1,,}" in
        0x10de) echo NVIDIA ;;
        0x1002|0x1022) echo AMD ;;
        0x8086) echo Intel ;;
        *)      echo "vendor ${1}" ;;
    esac
}

# True if the device is a PCI display controller (VGA 0x0300 or 3D 0x0302).
egpu_is_display() {
    local cls; cls=$(cat "$PCI_DEVICES/$1/class" 2>/dev/null) || return 1
    [[ $cls == 0x03* ]]
}

# Walk the parent chain, printing each ancestor BDF from the device upwards.
egpu_ancestors() {
    local cur="$PCI_DEVICES/$1" par pb depth=0
    while (( depth++ < 12 )); do
        par=$(dirname "$(readlink -f "$cur" 2>/dev/null)" 2>/dev/null) || return
        pb=$(basename "$par")
        [[ $pb =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$ ]] || return 0
        printf '%s\n' "$pb"
        cur=$par
    done
}

# True if any ancestor is a Thunderbolt/USB4 bridge. Matching the lspci text is
# deliberate: the controller VID:DID list grows every chip generation, and the
# kernel's pci_dev->is_thunderbolt flag is not exposed through sysfs.
egpu_is_tunneled() {
    local a
    while read -r a; do
        [[ -z $a ]] && continue
        lspci -s "${a#*:}" 2>/dev/null | grep -qiE 'thunderbolt|usb4' && return 0
    done < <(egpu_ancestors "$1")
    return 1
}

# Candidate eGPUs, one per line: BDF|vendor_id|vendor_name|description
egpu_candidates() {
    local d bdf vid
    for d in "$PCI_DEVICES"/*; do
        bdf=$(basename "$d")
        egpu_is_display "$bdf" || continue
        egpu_is_tunneled "$bdf" || continue
        vid=$(cat "$d/vendor" 2>/dev/null)
        printf '%s|%s|%s|%s\n' "$bdf" "$vid" "$(egpu_vendor_name "$vid")" \
            "$(lspci -s "${bdf#*:}" 2>/dev/null | cut -d' ' -f2- | sed 's/^[^:]*: //')"
    done
}

# Every display controller, tunneled or not - used by the lister to explain
# why a locally attached card was skipped.
egpu_all_display() {
    local d bdf vid
    for d in "$PCI_DEVICES"/*; do
        bdf=$(basename "$d")
        egpu_is_display "$bdf" || continue
        vid=$(cat "$d/vendor" 2>/dev/null)
        printf '%s|%s|%s|%s|%s\n' "$bdf" "$vid" "$(egpu_vendor_name "$vid")" \
            "$(egpu_is_tunneled "$bdf" && echo tunneled || echo local)" \
            "$(lspci -s "${bdf#*:}" 2>/dev/null | cut -d' ' -f2- | sed 's/^[^:]*: //')"
    done
}

egpu_parent_bridge() {
    local p; p=$(egpu_ancestors "$1" | head -1)
    [[ -n $p ]] && printf '%s\n' "$p"
}

# Last PCI device before the host bridge = the CPU root port.
egpu_root_port() { egpu_ancestors "$1" | tail -1; }

# Secondary bus of a bridge, as sysfs names it (e.g. "0000:02").
egpu_secondary_bus() {
    local b; b=$(ls -d "$PCI_DEVICES/$1"/pci_bus/* 2>/dev/null | head -1)
    [[ -n $b ]] && basename "$b"
}

# The single real child of a bridge; ":pcieNNN" port services are skipped.
egpu_first_child() {
    local c
    for c in "$PCI_DEVICES/$1"/[0-9a-f]*:*; do
        [[ -e $c ]] || continue
        c=$(basename "$c")
        [[ $c =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$ ]] || continue
        printf '%s\n' "$c"; return 0
    done
    return 1
}

egpu_bar_size() {
    lspci -vv -s "${1#*:}" 2>/dev/null | grep -oP "Region $2:.*\[size=\K[^]]+"
}

# Resolve the whole topology into EGPU_* variables.
#
#   $1  optional GPU BDF. Empty means auto-detect.
#
# Exits non-zero with a message on stderr when the choice is ambiguous, so
# callers never guess. Sets: EGPU_GPU EGPU_VENDOR EGPU_VENDOR_NAME EGPU_DESC
# EGPU_BRIDGE EGPU_ROOT_PORT EGPU_TB_UPSTREAM EGPU_SECONDARY_BUS
# EGPU_RP_BUS EGPU_RP_DEV EGPU_RP_FN
egpu_resolve() {
    local want=${1:-} cands n line
    if [[ -n $want ]]; then
        [[ -d $PCI_DEVICES/$want ]] || { echo "egpu-lib: no such PCI device: $want" >&2; return 1; }
        egpu_is_display "$want" || { echo "egpu-lib: $want is not a display controller" >&2; return 1; }
        line="$want|$(cat "$PCI_DEVICES/$want/vendor")|$(egpu_vendor_name "$(cat "$PCI_DEVICES/$want/vendor")")|$(lspci -s "${want#*:}" | cut -d' ' -f2- | sed 's/^[^:]*: //')"
        egpu_is_tunneled "$want" \
            || echo "egpu-lib: warning: $want is not behind a Thunderbolt/USB4 tunnel" >&2
    else
        cands=$(egpu_candidates)
        n=$(grep -c . <<<"${cands:-}")
        if [[ -z $cands ]]; then
            echo "egpu-lib: no display controller found behind a Thunderbolt/USB4 tunnel" >&2
            return 1
        elif (( n > 1 )); then
            echo "egpu-lib: $n candidates found - pick one with GPU=<bdf>" >&2
            sed 's/^/  /' <<<"$cands" >&2
            return 1
        fi
        line=$cands
    fi

    IFS='|' read -r EGPU_GPU EGPU_VENDOR EGPU_VENDOR_NAME EGPU_DESC <<<"$line"
    # Fail loudly on an empty result. An empty BDF is worse than no answer:
    # "lspci -s ''" matches every device and "[[ -d /sys/bus/pci/devices/ ]]"
    # is true, so callers silently operate on the whole bus.
    [[ -n $EGPU_GPU ]] || { echo "egpu-lib: internal error, empty GPU address" >&2; return 1; }
    EGPU_BRIDGE=$(egpu_parent_bridge "$EGPU_GPU")
    EGPU_ROOT_PORT=$(egpu_root_port "$EGPU_GPU")
    [[ -n $EGPU_BRIDGE && -n $EGPU_ROOT_PORT ]] \
        || { echo "egpu-lib: cannot resolve topology for $EGPU_GPU" >&2; return 1; }
    EGPU_SECONDARY_BUS=$(egpu_secondary_bus "$EGPU_ROOT_PORT")
    EGPU_TB_UPSTREAM=$(egpu_first_child "$EGPU_ROOT_PORT")
    local bdf=${EGPU_ROOT_PORT#*:}
    EGPU_RP_BUS=$((16#${bdf%%:*}))
    bdf=${bdf#*:}
    EGPU_RP_DEV=$((16#${bdf%%.*}))
    EGPU_RP_FN=${bdf#*.}
    export EGPU_GPU EGPU_VENDOR EGPU_VENDOR_NAME EGPU_DESC EGPU_BRIDGE \
           EGPU_ROOT_PORT EGPU_TB_UPSTREAM EGPU_SECONDARY_BUS \
           EGPU_RP_BUS EGPU_RP_DEV EGPU_RP_FN
}

egpu_print_topology() {
    printf '  %-14s %s  %s\n' "GPU"         "$EGPU_GPU"        "$EGPU_VENDOR_NAME"
    printf '  %-14s %s\n'     "bridge"      "$EGPU_BRIDGE"
    printf '  %-14s %s\n'     "root port"   "$EGPU_ROOT_PORT"
    printf '  %-14s %s\n'     "TB upstream" "${EGPU_TB_UPSTREAM:-<none>}"
    printf '  %-14s %s\n'     "rescan bus"  "${EGPU_SECONDARY_BUS:-<none>}"
    printf '  %-14s bus=0x%02x dev=0x%02x fn=%s\n' "module args" \
        "$EGPU_RP_BUS" "$EGPU_RP_DEV" "$EGPU_RP_FN"
}
