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

# BAR size as lspci spells it ("256M"), for ONE device.
#
# The guard and the "head -1" are load-bearing: with an empty BDF "lspci -s"
# matches EVERY device on the bus, and the caller then compares a multi-line
# string against "256M" and reports a failure that is not there.
egpu_bar_size() {
    [[ -n ${1:-} ]] || return 1
    lspci -vv -s "${1#*:}" 2>/dev/null \
        | grep -oP "Region $2:.*\[size=\K[^]]+" | head -1
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

# ===========================================================================
# SHARED SHELL PLUMBING
#
# Everything below used to be copy-pasted across the numbered scripts - up to
# five copies of the same eight lines, and in several cases only some of the
# copies carried a fix. One definition here means a fix lands everywhere.
#
# Scripts that need a different dialect define their own AFTER sourcing this
# file, and theirs wins: 1-check.sh counts pass/fail and honours --quiet, so it
# keeps its own reporters on purpose.
# ===========================================================================

# ---------------------------------------------------------------- reporting
ok()   { printf '  \033[32m+\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31mx\033[0m %s\n' "$*"; }
hdr()  { printf '\n\033[1m=== %s ===\033[0m\n' "$*"; }
# "info" MUST be defined. It is also a real binary (/usr/bin/info, the GNU
# documentation reader), so a missing definition does not fail loudly - bash
# silently runs the reader and the intended message is lost.
info() { printf '    %s\n' "$*"; }

egpu_require_root() {
    [[ $EUID -eq 0 ]] && return 0
    echo "Run with sudo: sudo $0 ${*:-}" >&2
    exit 1
}

# Print a script's header comment block as its --help text.
egpu_usage() { awk 'NR>1 && !/^#/{exit} NR>1{sub(/^# ?/,""); print}' "$1"; }

# ---------------------------------------------------------------- logging
#
# ONE timestamp per RUN, not per script. run.sh exports EGPU_STAMP, so a single
# bring-up lands under one stamp instead of five unrelated ones - previously
# every script in the chain called date(1) for itself, which made correlating
# run-*.log with the script-*.log and kernel-*.log of the same run guesswork.
egpu_stamp() { printf '%s' "${EGPU_STAMP:-$(date +%Y%m%d-%H%M%S)}"; }

# NOT plain "EGPU_LOG=" - these must survive being inherited. Sourcing this
# file in a child would otherwise wipe the parent's exported value, and the
# nesting rule below (adopt the parent's log) would never fire.
EGPU_LOG=${EGPU_LOG:-}
EGPU_KLOG=${EGPU_KLOG:-}
EGPU_TEE_PID=

# egpu_log_open <logdir> <prefix> [stamp]  -> sets EGPU_LOG, redirects output.
#
# MUST NOT be called inside a command substitution: the "exec" redirect would
# then apply to the subshell only and the script's own output would be
# untouched.
#
# NESTING IS THE TRAP HERE, and it is why EGPU_LOG is exported.
#
# run.sh calls 4-build-module, which calls 5-window and then execs
# 6-load-driver, which calls 7-bar-fallback. Every one of them used
# to open its own tee - and a nested tee does not replace the outer one, it
# stacks on top of it: the inner script's stdout goes to the inner tee, whose
# own stdout is still the OUTER tee's pipe. So each line was written once per
# level of nesting. That was survivable only because every script generated its
# own timestamp and therefore its own filename; the moment they share a stamp,
# the duplicates land in one file.
#
# So: if a parent already redirected, adopt its log and do not redirect again.
# One bring-up then produces exactly one script log, which was the point of
# sharing the stamp. Run any of these scripts on its own and it opens its own.
egpu_log_open() {
    local dir=$1 prefix=$2 stamp=${3:-}
    if [[ -n ${EGPU_LOG:-} ]]; then
        # Inherited from a parent that is already teeing into it.
        export EGPU_LOG
        return 0
    fi
    [[ -n $stamp ]] || stamp=$(egpu_stamp)
    EGPU_LOG=$dir/$prefix-$stamp.log
    mkdir -p "$dir"
    # This runs under sudo, so hand the directory back to the invoking user;
    # otherwise the next non-root run cannot write to it.
    chown "${SUDO_USER:-root}:" "$dir" 2>/dev/null || true
    exec > >(tee -a "$EGPU_LOG") 2>&1
    # NOT exported: a child must never try to wait on its parent's tee.
    EGPU_TEE_PID=$!
    export EGPU_LOG
}

# tee runs in a subprocess. Without closing our descriptors and waiting for it,
# a fast "bad ...; exit 1" returns the shell to the prompt before tee has
# written anything: the message vanishes from the SCREEN although it survives in
# the log. Four scripts carried this fix and three did not - including run.sh,
# which has the most early-exit paths of any of them.
egpu_log_flush() {
    [[ -n ${EGPU_TEE_PID:-} ]] || return 0
    exec 1>&- 2>&-
    # Empty argument would make "wait" block on every child, not this one.
    wait "$EGPU_TEE_PID" 2>/dev/null || true
    EGPU_TEE_PID=
}

# ---------------------------------------------------------------- kernel log
#
# dmesg -w into a file with a sync every 0.2 s, because on this platform
# "fallen off the bus" presents as an instant reset with no kernel output and
# pstore has no backend. Evidence has to be on disk before the reset.
# Same nesting rule as egpu_log_open, for the same reason: 6-load-driver calls
# 7-bar-fallback while its own capture is running, and two "dmesg -w" appending
# to one file interleave every message twice. If a parent is already capturing,
# adopt its file and start nothing.
EGPU_BG=()
egpu_klog_start() {
    if [[ -n ${EGPU_KLOG:-} ]]; then
        export EGPU_KLOG
        return 0
    fi
    EGPU_KLOG=$1
    export EGPU_KLOG
    stdbuf -oL dmesg -w >> "$EGPU_KLOG" &  EGPU_BG+=($!)
    ( while :; do sync; sleep 0.2; done ) & EGPU_BG+=($!)
    sleep 1
}

egpu_bg_kill() {
    local p
    for p in "${EGPU_BG[@]:-}"; do
        [[ -n $p ]] && kill "$p" 2>/dev/null
    done
    EGPU_BG=()
    sync
    return 0
}

# The standard EXIT trap. ORDER MATTERS: the background jobs inherit stdout, so
# tee would never see EOF while they are alive. Kill them first, flush second.
egpu_cleanup() { egpu_bg_kill; egpu_log_flush; }

# A marker in the kernel log, so a post-mortem can tell which step a message
# belongs to.
mark() {
    printf '\n########## %s ##########\n' "$1" >> "${EGPU_KLOG:-/dev/null}"
    sync
    echo ">>> $1"
}

# ---------------------------------------------------------------- the window
#
# ONE source of truth for the root-port window and the BAR1 size code. These
# used to be stated in three places with two different values: the old
# 3-setup wrapper exported 0x4010000000/1024/8 while 5-window.sh defaulted to
# 0xf0000000/192/7,
# and 4-build-module.sh printed a third copy as a message. Running 5-window.sh
# the way its own header documents therefore produced a 128 MB BAR1, which
# run.sh then rejected as a failure.
EGPU_WIN_BASE_DEFAULT=0x4010000000
EGPU_WIN_MB_DEFAULT=1024
EGPU_REBAR_SIZE_DEFAULT=8          # 2^8 MB = 256 MB

# Fill in and export WIN_BASE / WIN_MB / REBAR_SIZE, honouring the environment.
egpu_window_defaults() {
    WIN_BASE=${WIN_BASE:-$EGPU_WIN_BASE_DEFAULT}
    WIN_MB=${WIN_MB:-$EGPU_WIN_MB_DEFAULT}
    REBAR_SIZE=${REBAR_SIZE:-$EGPU_REBAR_SIZE_DEFAULT}
    export WIN_BASE WIN_MB REBAR_SIZE
}

# The BAR1 size we expect once the window is in place, spelled the way lspci
# spells it ("256M"). Derived, so overriding REBAR_SIZE does not turn a correct
# run into a reported failure.
egpu_bar1_expected() { printf '%dM' $(( 2 ** ${REBAR_SIZE:-$EGPU_REBAR_SIZE_DEFAULT} )); }

# ---------------------------------------------------------------- BARs
#
# There were FIVE different ways of reading BAR1 in this package. These are the
# two that are actually different questions: how big is it, and is it assigned.

# Raw base address of a BAR from sysfs. 0x0 means unassigned.
egpu_bar_base() {
    local r=$PCI_DEVICES/$1/resource
    [[ -f $r ]] || return 1
    awk -v n="$2" 'NR == n + 1 { print $1 }' "$r"
}

egpu_bar_assigned() {
    local v
    v=$(egpu_bar_base "$1" "$2") || return 1
    [[ -n $v && $v != 0x0000000000000000 ]]
}

# ---------------------------------------------------------------- the driver
EGPU_NV_MODULES=(nvidia_drm nvidia_modeset nvidia_uvm nvidia)

# Unload the stack top-down. On failure the module that would not go is left in
# EGPU_UNLOAD_FAILED, so the caller can explain the specific reason - which
# differs: nvidia_drm held by the compositor is expected and needs a session
# restart, anything else needs lsof.
EGPU_UNLOAD_FAILED=
egpu_unload_stack() {
    local m
    EGPU_UNLOAD_FAILED=
    for m in "${EGPU_NV_MODULES[@]}"; do
        [[ -d /sys/module/$m ]] || continue
        if modprobe -r "$m" 2>/dev/null; then
            ok "$m unloaded"
        else
            bad "$m NOT unloaded (refcnt=$(cat /sys/module/$m/refcnt 2>/dev/null))"
            EGPU_UNLOAD_FAILED=$m
            return 1
        fi
    done
    return 0
}

egpu_loaded_modules() {
    local m out=
    for m in nvidia nvidia_uvm nvidia_modeset nvidia_drm egpu_rp_window; do
        [[ -d /sys/module/$m ]] && out+="$m "
    done
    printf '%s' "$out"
}

# Proof that GSP is running is a non-empty firmware version from nvidia-smi.
# The requested mode in /proc/driver/nvidia/params is NOT proof: 18 = 0x12 =
# MODE_DEFAULT|POLICY_ALLOW_UNSIGNED only means "the driver decides".
egpu_gsp_version() {
    local v
    v=$(nvidia-smi -q 2>/dev/null | grep -i 'GSP Firmware Version' | sed 's/.*: *//')
    [[ -n $v && $v != N/A ]] || return 1
    printf '%s\n' "$v"
}

# The DRM card owned by the nvidia driver, plus its PCI IDs. Discovered, never
# hardcoded: card numbering moves on a machine with a USB display and a
# hot-plugged eGPU.
#
# NOTE the EGPU_CARD_* names. EGPU_VENDOR is already taken by egpu_resolve for
# the vendor of the resolved PCI device, and 10-/11- used to call this one
# EGPU_VENDOR too - harmless only as long as they did not source this file.
EGPU_CARD=; EGPU_CARD_BDF=; EGPU_CARD_VENDOR=; EGPU_CARD_DEVICE=
egpu_nv_card() {
    local c drv
    EGPU_CARD=; EGPU_CARD_BDF=; EGPU_CARD_VENDOR=; EGPU_CARD_DEVICE=
    for c in /sys/class/drm/card[0-9]*; do
        [[ -e $c/device/driver ]] || continue
        drv=$(basename "$(readlink -f "$c/device/driver")")
        [[ $drv == nvidia ]] || continue
        EGPU_CARD=$(basename "$c")
        EGPU_CARD_BDF=$(basename "$(readlink -f "$c/device")")
        EGPU_CARD_VENDOR=$(cat "$c/device/vendor" 2>/dev/null)
        EGPU_CARD_DEVICE=$(cat "$c/device/device" 2>/dev/null)
        return 0
    done
    return 1
}

# One row per connector of a card: name, status, EDID size, first mode.
# Returns non-zero when no connector reports "connected".
egpu_print_connectors() {
    local card=$1 conn st ed live=0
    [[ -n $card ]] || return 1
    printf '      %-12s %-14s %-8s %s\n' CONNECTOR STATUS EDID MODE
    for conn in /sys/class/drm/"$card"-*; do
        [[ -e $conn/status ]] || continue
        st=$(cat "$conn/status")
        ed=$(wc -c < "$conn/edid" 2>/dev/null || echo 0)
        [[ $st == connected ]] && live=1
        printf '      %-12s %-14s %-8s %s\n' "${conn##*/$card-}" "$st" "${ed}B" \
            "$(head -1 "$conn/modes" 2>/dev/null || echo '-')"
    done
    (( live ))
}

# ---------------------------------------------------------------- PCIe link
EGPU_LNKCTL2=CAP_EXP+30.w          # Link Control 2
EGPU_LNKCTL=CAP_EXP+10.w           # Link Control
EGPU_LNKSTA=CAP_EXP+12.w           # Link Status

egpu_speed_name() {
    case $(( $1 & 0xf )) in
        1) echo "Gen1 2.5GT/s" ;; 2) echo "Gen2 5GT/s"  ;; 3) echo "Gen3 8GT/s"  ;;
        4) echo "Gen4 16GT/s" ;; 5) echo "Gen5 32GT/s" ;; *) echo "?($1)" ;;
    esac
}

egpu_show_link() {
    local dev c2 st
    for dev in "$@"; do
        [[ -n $dev ]] || continue
        c2=$(setpci -s "$dev" "$EGPU_LNKCTL2" 2>/dev/null) \
            || { printf '      %s: no read\n' "$dev"; continue; }
        st=$(setpci -s "$dev" "$EGPU_LNKSTA" 2>/dev/null) || st=0000
        printf '      %s  Target=%s  HW-Auto-Speed-Disable=%s  LnkSta=%s\n' "$dev" \
            "$(egpu_speed_name $((0x$c2)))" \
            "$([[ $((0x$c2 & 0x20)) -ne 0 ]] && echo SET || echo unset)" \
            "$(egpu_speed_name $((0x$st)))"
    done
}

# Target Link Speed = Gen<n>, plus bit 5 (Hardware Autonomous Speed Disable).
# Both are what stop the Gen3<->Gen4 oscillation behind the tunnel from
# retraining inside the GSP handshake window.
egpu_cap_apply() {
    local speed=$1 dev tgt
    shift
    tgt=$(printf '%04x' "$speed")
    for dev in "$@"; do
        [[ -n $dev ]] || continue
        setpci -s "$dev" "$EGPU_LNKCTL2"="$tgt":000f \
            || { bad "writing Target Link Speed on $dev failed"; return 1; }
        setpci -s "$dev" "$EGPU_LNKCTL2"=0020:0020 \
            || { bad "writing bit 5 on $dev failed"; return 1; }
        ok "$dev -> Target Gen$speed + bit5"
    done
}

egpu_cap_clear() {
    local dev
    for dev in "$@"; do
        [[ -n $dev ]] || continue
        setpci -s "$dev" "$EGPU_LNKCTL2"=0004:000f 2>/dev/null
        setpci -s "$dev" "$EGPU_LNKCTL2"=0000:0020 2>/dev/null
    done
    return 0
}

# ---------------------------------------------------------------- ReBAR
#
# The Resizable BAR extended capability. Its offset used to be written down as
# 0xbb0 in two scripts - the value on the machine this was developed on, and the
# last hardware-specific constant in a package whose whole selling point is that
# nothing about the topology is. Walk the extended capability list instead: it
# starts at 0x100 and every header carries the offset of the next one in bits
# [31:20].
EGPU_REBAR_CAP_ID=0x0015

egpu_pci_dword() { setpci -s "$1" "$(printf '%x' "$2").L" 2>/dev/null; }

egpu_rebar_cap() {
    local dev=$1 off=0x100 raw h id depth=0
    off=$((off))
    while (( off >= 0x100 && depth++ < 64 )); do
        raw=$(egpu_pci_dword "$dev" "$off") || return 1
        [[ -n $raw ]] || return 1
        h=$((16#$raw))
        (( h == 0 || h == 0xffffffff )) && return 1
        id=$(( h & 0xffff ))
        (( id == EGPU_REBAR_CAP_ID )) && { printf '%d\n' "$off"; return 0; }
        off=$(( (h >> 20) & 0xfff ))
    done
    return 1
}

# Offset of the ReBAR *control* register for one BAR index. Layout per the spec:
# capability header at +0x00, then for each resizable BAR a capability register
# at +0x04+8i and a control register at +0x08+8i. The control register holds the
# BAR index in bits [2:0] and the size code in bits [13:8].
egpu_rebar_entry() {
    local dev=$1 bar=$2 cap n i off v
    cap=$(egpu_rebar_cap "$dev") || return 1
    v=$(egpu_pci_dword "$dev" $((cap + 8))) || return 1
    n=$(( ( $((16#$v)) >> 5 ) & 0x7 ))
    for ((i = 0; i < n; i++)); do
        off=$(( cap + 8 + 8 * i ))
        v=$(egpu_pci_dword "$dev" "$off") || continue
        (( ( $((16#$v)) & 0x7 ) == bar )) && { printf '%d\n' "$off"; return 0; }
    done
    return 1
}

# Current size code at a control-register offset. 2^code MB.
egpu_rebar_get() {
    local v
    v=$(egpu_pci_dword "$1" "$2") || return 1
    printf '%d\n' $(( ( $((16#$v)) >> 8 ) & 0x3f ))
}

# Write a size code and verify the card accepted it. A bridge reset can restore
# the previous size, so callers re-apply before every attempt rather than once.
egpu_rebar_set() {
    local dev=$1 off=$2 want=$3 old new got
    old=$(egpu_pci_dword "$dev" "$off") || return 1
    new=$(( ( $((16#$old)) & ~0x00003f00 ) | (want << 8) ))
    setpci -s "$dev" "$(printf '%x' "$off").L=$(printf '%08x' "$new")" || return 1
    got=$(egpu_rebar_get "$dev" "$off") || return 1
    (( got == want ))
}
