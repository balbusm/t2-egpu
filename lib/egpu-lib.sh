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

# ---------------------------------------------------------------------------
# WHERE THE PACKAGE LIVES
#
# Derived from THIS file's own location, so no script has to reason about how
# deep it sits. run.sh is in the package root, the numbered scripts are one
# level down in scripts/, and lib/ is directly under the root - which is the one
# fact this needs to know.
#
# A script only has to find the library; everything else comes from here. That
# is the whole reason this exists: before scripts/ was a directory, "$SELFDIR"
# meant both "where I am" and "where the package is", and those are now
# different things in nine files out of eleven.
EGPU_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EGPU_ROOT="$(cd "$EGPU_LIB_DIR/.." && pwd)"
EGPU_SCRIPTS="$EGPU_ROOT/scripts"
EGPU_LOGS="$EGPU_ROOT/logs"
EGPU_MODULE="$EGPU_ROOT/module"
EGPU_BUILD="$EGPU_ROOT/build/module"
export EGPU_ROOT EGPU_SCRIPTS EGPU_LOGS EGPU_MODULE EGPU_BUILD

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
# file, and theirs wins: 01-check.sh counts pass/fail and honours --quiet, so it
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

# NOT plain "EGPU_LOG=" - it must survive being inherited. Sourcing this file
# in a child would otherwise wipe the parent's exported value, and the nesting
# rule below (adopt the parent's log) would never fire.
EGPU_LOG=${EGPU_LOG:-}
EGPU_TEE_PID=

# egpu_log_open <logdir> <prefix> [stamp]  -> sets EGPU_LOG, redirects output.
#
# MUST NOT be called inside a command substitution: the "exec" redirect would
# then apply to the subshell only and the script's own output would be
# untouched.
#
# NESTING IS THE TRAP HERE, and it is why EGPU_LOG is exported.
#
# run.sh calls 03-build-module, which calls 04-window and then execs
# 05-load-driver, which calls 06-bar-fallback. Every one of them used
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

# ---------------------------------------------------------------- progress
#
# This used to also append the marker to a captured kernel log. THE CAPTURE IS
# GONE. It ran "dmesg -w" into a file with a sync every 0.2 s so evidence would
# survive a hard reset, which mattered while the reset was the thing being
# diagnosed. It is not any more - cap plus GSP is verified working - and it cost
# a permanent background job per script, a nesting rule so a nested script would
# not start a second "dmesg -w" over the same file, and an EXIT trap whose
# ordering had to be right or tee would never flush. For a post-mortem, dmesg
# and "journalctl -k" hold the same messages.
mark() { echo ">>> $1"; }

# ---------------------------------------------------------------- the window
#
# ONE source of truth for the root-port window and the BAR1 size code. These
# used to be stated in three places with two different values: a setup wrapper
# that has since been removed exported 0x4010000000/1024/8 while 04-window.sh
# defaulted to 0xf0000000/192/7,
# and 03-build-module.sh printed a third copy as a message. Running 04-window.sh
# the way its own header documents therefore produced a 128 MB BAR1, which
# run.sh then rejected as a failure.
# WIN_BASE and WIN_MB describe a hole in the host address map, not the card, so
# they keep written-down defaults.
EGPU_WIN_BASE_DEFAULT=0x4010000000
EGPU_WIN_MB_DEFAULT=1024

# THE BAR1 SIZE IS NOT A DEFAULT ANY MORE - IT IS READ FROM THE CARD.
#
# It used to be a written-down 8 (2^8 = 256 MB), which is simply what this
# particular Ada card powers up with. So the ReBAR write was a no-op dressed as
# a decision, and on a card with a different native BAR1 it would have been an
# unrequested resize. Reading the control register instead means the default is
# "leave the card at the size it asks for", and REBAR_SIZE becomes a pure
# override - which is the only way it was ever really used: 06-bar-fallback
# SHRINKS BAR1 when the window cannot fit it.
#
# The fallback below is reached only when the card cannot be asked at all - no
# root, no card, or no ReBAR capability.
EGPU_REBAR_SIZE_FALLBACK=8

# Size code the card currently reports for a BAR - its own default until
# something writes the control register. Needs root: this is config space.
egpu_rebar_current() {
    local off
    off=$(egpu_rebar_entry "$1" "${2:-1}") || return 1
    egpu_rebar_get "$1" "$off"
}

# Fill in and export WIN_BASE / WIN_MB / REBAR_SIZE.
#
# CALL THIS AFTER egpu_resolve AND AFTER THE ROOT CHECK: asking the card its
# BAR1 size needs both. Callers that get it wrong land on the fallback, which is
# a silent wrong answer rather than an error, so the order matters.
egpu_window_defaults() {
    WIN_BASE=${WIN_BASE:-$EGPU_WIN_BASE_DEFAULT}
    WIN_MB=${WIN_MB:-$EGPU_WIN_MB_DEFAULT}
    if [[ -z ${REBAR_SIZE:-} ]]; then
        REBAR_SIZE=$(egpu_rebar_current "${EGPU_GPU:-}" 1) \
            || REBAR_SIZE=$EGPU_REBAR_SIZE_FALLBACK
    fi
    export WIN_BASE WIN_MB REBAR_SIZE
}

# The BAR1 size we expect once the window is in place, spelled the way lspci
# spells it ("256M"). Read from the ReBAR control register rather than from the
# assigned BAR, because an unassigned BAR has no size to report - which is
# exactly the state run.sh is testing for.
egpu_bar1_expected() { printf '%dM' $(( 2 ** ${REBAR_SIZE:-$EGPU_REBAR_SIZE_FALLBACK} )); }

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

# ---------------------------------------------------------------- topology
#
# Six scripts opened with the same four lines. This EXITS rather than returning:
# every caller treated the failure as fatal. The two places that tolerate a
# missing card - 01-check, and run.sh --off - call egpu_resolve directly.
egpu_resolve_or_die() {
    if ! egpu_resolve "${GPU:-}"; then
        echo "Cannot resolve eGPU topology. Run $EGPU_SCRIPTS/02-devices.sh to see what is present." >&2
        exit 1
    fi
    # Adopt what discovery found. Leaving GPU empty is worse than no answer:
    # "lspci -s ''" matches EVERY device instead of one, which silently turns
    # any BAR check into a multi-line answer.
    GPU=$EGPU_GPU
    BRIDGE=${BRIDGE:-$EGPU_BRIDGE}
}

# ---------------------------------------------------------------- the module
#
# module/Makefile owns the build path; ask make for it so it is stated in
# exactly one place. Sets EGPU_BUILDDIR and EGPU_KO.
egpu_module_ko() {
    local d
    d=$(make --no-print-directory -C "$EGPU_MODULE" -s print-builddir 2>/dev/null)
    EGPU_BUILDDIR=${d:-$EGPU_BUILD}
    EGPU_KO=$EGPU_BUILDDIR/egpu_rp_window.ko
}

# ---------------------------------------------------------------- GSP switch
#
# The kill switch, written as a safety net whenever the driver might bind before
# the link cap is in place and moved aside once it is. The name sorts late in
# modprobe.d on purpose.
EGPU_GSPOFF=/etc/modprobe.d/zzzz-egpu-gsp-off.conf

egpu_gsp_block() { printf 'options nvidia NVreg_EnableGpuFirmware=0\n' > "$EGPU_GSPOFF"; }

# Moved aside, not deleted, and the suffix deliberately does not end in .conf so
# modprobe ignores the leftover. Non-zero when there was no block to remove.
egpu_gsp_unblock() {
    [[ -f $EGPU_GSPOFF ]] || return 1
    mv "$EGPU_GSPOFF" "$EGPU_GSPOFF.disabled-$(egpu_stamp)"
}

# Drop the leftovers. No "shopt -s nullglob": that is global shell state, and an
# explicit existence test costs one line.
egpu_gsp_clean() {
    local f
    for f in "$EGPU_GSPOFF".disabled-*; do
        [[ -e $f ]] || continue
        rm -f "$f" && ok "removed $(basename "$f")"
    done
    return 0
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

# Load the KMS half of the stack, and make sure /dev/nvidia-modeset exists.
#
# WHY THE NODE NEEDS HELP. Ubuntu creates the /dev/nvidia* nodes with
# /sbin/ub-device-create, fired by a udev rule when nvidia BINDS to the PCI
# device. At that moment nvidia_modeset is not loaded - it is loaded here, by
# hand, and our own 71-nvidia.rules has the "RUN+=modprobe nvidia-modeset" line
# removed on purpose, because auto-loading it hung the machine during bring-up.
#
# So nothing ever created /dev/nvidia-modeset, and NOTHING VISIBLE BROKE:
# compute, CUDA, rendering and KMS all use other nodes. Only Vulkan opens this
# one. It got ENOENT, the driver answered VK_ERROR_UNKNOWN, and vulkaninfo did
# not even error - it segfaulted. That cost a full day of chasing a phantom
# driver bug, which is why the sequence lives here once instead of twice.
egpu_load_display_stack() {
    local m
    for m in nvidia_uvm nvidia_modeset; do
        modprobe --ignore-install "$m" && ok "$m" || warn "$m failed"
    done
    # Idempotent, so calling it unconditionally is safe.
    [[ -x /sbin/ub-device-create ]] && /sbin/ub-device-create 2>/dev/null || true
    if [[ -e /dev/nvidia-modeset ]]; then
        ok "/dev/nvidia-modeset present (Vulkan presentation needs it)"
    elif mknod /dev/nvidia-modeset c 195 254 2>/dev/null && chmod 666 /dev/nvidia-modeset 2>/dev/null; then
        # Major 195 is shared by nvidia, nvidia-modeset and nvidiactl (see
        # /proc/devices): nvidiactl is minor 255, GPUs are 0..N, modeset is 254.
        ok "/dev/nvidia-modeset created by hand"
    else
        bad "/dev/nvidia-modeset MISSING - Vulkan presentation will fail with VK_ERROR_UNKNOWN"
    fi
    # fbdev is stated even though 1 is the driver's own default: modprobe.d is
    # concatenated and the kernel takes the last repeated parameter, so being
    # explicit is what makes the effective configuration deterministic no matter
    # what an older install left behind.
    modprobe --ignore-install nvidia_drm modeset=1 fbdev=1 \
        && ok "nvidia_drm modeset=1 fbdev=1" || warn "nvidia_drm failed"
}

# The udev rule that hands mutter a tag for the card. 09-primary-gpu and
# 10-teardown wrote byte-identical matcher lines differing only in the tag.
#
# egpu_nv_card must have run.  $1 file, $2 tag, $3.. extra comment lines.
egpu_write_mutter_tag_rule() {
    local file=$1 tag=$2
    shift 2
    mkdir -p "$(dirname "$file")" || return 1
    {
        printf '# Written by %s\n#\n' "${0##*/}"
        printf '# %s\n' "$@"
        printf '#\n'
        printf '# Matching is on PCI vendor:device, not /dev/dri/cardN: card numbering\n'
        printf '# moves here - a USB display can take card0 and the eGPU is hot-plugged.\n'
        printf '# It matches nothing at boot, because the card is absent until run.sh has\n'
        printf '# set up the tunnel, so a normal boot is unaffected.\n'
        printf 'SUBSYSTEM=="drm", ENV{DEVTYPE}=="drm_minor", ENV{DEVNAME}=="/dev/dri/card[0-9]", SUBSYSTEMS=="pci", ATTRS{vendor}=="%s", ATTRS{device}=="%s", TAG+="%s"\n' \
            "$EGPU_CARD_VENDOR" "$EGPU_CARD_DEVICE" "$tag"
    } > "$file"
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
