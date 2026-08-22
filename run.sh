#!/usr/bin/env bash
# run.sh - bring the external GPU up. This is the only script you normally run.
#
# Works in your terminal: it does not detach through systemd and does not kill
# your graphical session, so you see progress as it happens. A copy goes to
# logs/.
#
# WHAT IT DOES, AND WHY IN THIS ORDER
#
#   1-check      prerequisites. Missing files under /etc show up not as an
#                error but as a machine RESET, so they are verified first.
#   3-setup      root-port window and BARs (calls 4-build-module -> 5-window
#                -> 6-load-driver).
#   link cap     Target Link Speed + Hardware Autonomous Speed Disable on the
#                bridge above the card.
#   GSP          firmware enabled, then the driver stack is loaded.
#
#   primary GPU  --primary-gpu (step 10, 10-primary-gpu.sh). A udev tag making
#                the card mutter's primary GPU, after which applications render
#                on it natively.
#
# WITHOUT IT the card comes up and sits idle while the Radeon does the
# rendering: measured 20-30 fps against ~120. That is not a broken card, it is
# nothing having asked it to work.
#
# An earlier route through session environment variables (10-default-gpu.sh,
# step 10) was REMOVED 2026-08-22: --primary-gpu achieves the same thing and
# more, and the variables actively got in the way before an unplug, because
# VK_LOADER_DRIVERS_SELECT=*nvidia* hides every other GPU from Vulkan.
#
# THREE ORDERING CONSTRAINTS - the whole structure follows from them:
#
#   1. the cap must come AFTER 5-window, because remove+rescan destroys and
#      recreates the device, discarding any cap applied earlier
#   2. the cap must come BEFORE nvidia.ko binds, or the driver retrains the
#      link to Gen4 inside the GSP handshake window and the card falls off the
#      bus (an instant reset, seen five times)
#   3. GSP only together with the cap - never GSP without it
#
# That is why this script inserts NVreg_EnableGpuFirmware=0 as a safety net
# for the duration of 3-setup and removes it only once the cap is in place.
#
# RISK
#
# The graphical session stays up, so an unexpected reset costs you unsaved
# work. GSP with the cap is verified, but on a single machine. The cautious
# variant that detaches from the session is 8-link-cap-gsp.sh.
#
# TOPOLOGY
#
# The card, the bridge above it and the root port are discovered, never
# hardcoded - see lib/egpu-lib.sh. Override with GPU=<bdf> or BRIDGE=<bdf>.
# Run ./2-devices.sh to list candidates.
#
# USAGE
#
#   sudo ./run.sh                      # THE EVERYDAY COMMAND. With no
#                                      # arguments it applies two defaults:
#                                      # --restart-ui and --primary-gpu. So it
#                                      # brings the card up, makes it the
#                                      # compositor's primary GPU and restarts
#                                      # the session.
#                                      #
#                                      # That means the bare command is the
#                                      # most consequential one: it costs your
#                                      # open windows. It prints what it is
#                                      # about to do and waits 5 s first.
#                                      #
#                                      # ANY flag suppresses both defaults.
#   sudo GPU=<bdf> ./run.sh            # pick a card when several are present
#                                      (get <bdf> from ./2-devices.sh)
#   sudo CAP_SPEED=2 ./run.sh        # lower link ceiling (1..4, default 3)
#   sudo ./run.sh --retrain          # force a link retrain
#   sudo ./run.sh --no-gsp           # load without GSP
#   sudo ./run.sh --off              # revert to the no-GSP configuration
#   sudo ./run.sh --skip-preflight   # skip the 1-check gate
#   sudo ./run.sh --primary-gpu      # make the CARD the compositor's primary
#                                    # GPU, so the monitor attached to it is
#                                    # composited and scanned out on the same
#                                    # card - no Thunderbolt round trip.
#                                    #
#                                    # Measured today (primary = Radeon): the
#                                    # external monitor loses ~24% to that
#                                    # round trip - 137.9 fps against 181.1 on
#                                    # the internal panel, same render size,
#                                    # same rendering GPU.
#                                    #
#                                    # The cost MOVES rather than vanishing:
#                                    # external drops to zero tunnel crossings,
#                                    # while the internal panel starts carrying
#                                    # the whole composited desktop instead of
#                                    # just window buffers. Worth it only if
#                                    # you mostly work on the external monitor.
#                                    #
#                                    # VERIFIED WORKING 2026-08-22. GravityMark
#                                    # went 137.9 -> 230 fps on the external
#                                    # monitor and 181.1 -> ~150 on the internal
#                                    # panel: the predicted trade, measured.
#                                    #
#                                    # Still note the blast radius: the closed
#                                    # NVIDIA driver is now the compositing GPU
#                                    # across a Thunderbolt tunnel, so a card
#                                    # that falls off the bus takes the whole
#                                    # session with it, not just applications.
#                                    # Safe at boot though - the card is absent
#                                    # then, so the udev rule matches nothing.
#                                    # Recovery and details:
#                                    #   ./10-primary-gpu.sh --help
#                                    #
#                                    # Needs a session restart to take effect;
#                                    # combine with --restart-ui.
#   sudo ./run.sh --no-primary-gpu   # remove that override again
#   sudo ./run.sh --reset            # GPU selection back to stock: removes the
#                                    # primary-GPU udev rule, so the Radeon
#                                    # composites again after a restart.
#                                    #
#                                    # Works with the card absent - it is
#                                    # handled before topology discovery, so
#                                    # you can still clean up after an unplug.
#                                    #
#                                    # Touches no driver state. That is --off.
#
# UNPLUGGING THE CARD WHILE THE MACHINE RUNS - two phases, in this order:
#
#   sudo ./run.sh --release          # phase 1: drop GPU selection, tag the
#                                    # card mutter-device-ignore, restart the
#                                    # session. Afterwards mutter no longer
#                                    # holds the card.
#                                    # THE CABLE IS NOT SAFE TO PULL YET.
#   sudo ./run.sh --unload           # phase 2, after logging back in: unload
#                                    # the nvidia stack and verify nothing
#                                    # holds the card. NOW the cable can go.
#
# Both delegate to 11-teardown.sh, which explains the reasoning and the
# caveats - including that a replug may need a reboot, and that powering the
# machine off is simpler if you have nothing running outside the session.
# UNTESTED.
#   sudo ./run.sh --restart-ui       # also restart the session, so the
#                                   # compositor picks up the card:
#                                   #   card already up -> restart only
#                                   #   card not up     -> bring up, then restart

set -uo pipefail

GPU=${GPU:-}
BRIDGE=${BRIDGE:-}
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # the package is self-locating
SELFDIR="$DIR"

# ---------- --reset: HANDLED HERE ON PURPOSE, BEFORE ANYTHING ELSE ----------
#
# --reset undoes the GPU-SELECTION layer - who COMPOSITES (step 10) - and puts
# it back to stock.
#
# It runs before egpu_resolve deliberately. The reason you reach for --reset is
# usually that the card is going away or is already gone (see the hot-unplug
# notes in FINDINGS.md), and egpu_resolve exits when there is no card to
# resolve. Parsing it with the other flags would make it unusable in exactly
# the situation it exists for.
#
# NOT the same as --off:
#   --off    reverts the DRIVER-level configuration (GSP, link cap). Needs the
#            card, and ends with "reboot, then run again".
#   --reset  touches no driver state at all. Only undoes GPU selection.
# --release and --unload delegate wholesale to 11-teardown.sh, and for the same
# reason they live up here: you reach for them when the card is on its way out,
# so they must not depend on discovering it. "exec" keeps it a pure front door -
# no duplicated restart logic, one place that knows how teardown works.
for a in "$@"; do case $a in
    --release) exec "$DIR/11-teardown.sh" --release ;;
    --unload)  exec "$DIR/11-teardown.sh" --unload ;;
esac; done

for a in "$@"; do
    [[ $a == --reset ]] || continue
    printf '\n\033[1m=== RESET - GPU selection back to stock ===\033[0m\n'
    [[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo $0 --reset" >&2; exit 1; }
    rc=0
    # Compositing first: it is the one that needs root and the one that decides
    # whether the desktop depends on the card at all.
    if [[ -x $DIR/10-primary-gpu.sh ]]; then
        "$DIR/10-primary-gpu.sh" --off || rc=1
    else
        echo "  ! missing $DIR/10-primary-gpu.sh" >&2; rc=1
    fi
    printf '\n'
    echo "  Compositing returns to the Radeon at the next session restart:"
    echo "      sudo $0 --restart-ui"
    echo
    echo "  The card and its driver are untouched. Nothing points at it any"
    echo "  more, which is the state you want before unplugging - but note the"
    echo "  real blocker for that is still nvidia_drm being held by the"
    echo "  compositor. See 'Hot unplug' in FINDINGS.md."
    exit $rc
done

# shellcheck source=lib/egpu-lib.sh
source "$SELFDIR/lib/egpu-lib.sh"
if ! egpu_resolve "${GPU:-}"; then
    echo "Cannot resolve eGPU topology. Run ./2-devices.sh to see what is present." >&2
    exit 1
fi
# Adopt what discovery found. Skipping this leaves GPU empty, and an empty
# argument to "lspci -s" matches EVERY device instead of one - which silently
# turns any BAR check into a multi-line answer.
GPU=$EGPU_GPU
BRIDGE=${BRIDGE:-$EGPU_BRIDGE}

GSPOFF=/etc/modprobe.d/zzzz-egpu-gsp-off.conf
LOGDIR=$DIR/logs
STAMP=$(date +%Y%m%d-%H%M%S)
SLOG=$LOGDIR/run-$STAMP.log
CAP_SPEED=${CAP_SPEED:-3}
WANT_RETRAIN=0; WANT_GSP=1; WANT_OFF=0; SKIP_PRE=0; RESTART_UI=0
PRIMARY_GPU=keep

for a in "$@"; do case $a in
    --retrain) WANT_RETRAIN=1 ;;
    --no-gsp)  WANT_GSP=0 ;;
    --off)     WANT_OFF=1; WANT_GSP=0; SKIP_PRE=1 ;;
    --skip-preflight) SKIP_PRE=1 ;;
    --restart-ui) RESTART_UI=1 ;;
    --primary-gpu)    PRIMARY_GPU=on ;;
    --no-primary-gpu) PRIMARY_GPU=off ;;
    # All three are handled above, before egpu_resolve, so that they work with
    # the card absent. Listed here only so they are not "unknown argument".
    --reset|--release|--unload) ;;
    -h|--help) awk 'NR>1 && !/^#/{exit} NR>1{sub(/^# ?/,""); print}' "$0"; exit 0 ;;
    *) echo "Unknown argument: $a" >&2; exit 1 ;;
esac; done

# ---------- DEFAULTS, APPLIED ONLY WHEN CALLED WITH NO ARGUMENTS ----------
#
# "sudo ./run.sh" with nothing else means the everyday workflow: bring the card
# up, make it the compositor's primary GPU, restart the session so both take
# effect.
#
# ⚠ THIS MAKES THE BARE COMMAND THE MOST CONSEQUENTIAL ONE, not the safest.
# It restarts the session - every open window is lost - and switches
# compositing to the eGPU. That switch is verified working here, but it makes
# the card a single point of failure for the whole desktop. Recovery, if a
# session ever does not come back: 10-primary-gpu.sh --help.
#
# PASSING ANY FLAG SUPPRESSES BOTH DEFAULTS, so explicit invocations stay
# predictable. That also means the two useful subsets need no extra flags -
# just name the one you want:
#
#     sudo ./run.sh --restart-ui        # restart, but Radeon keeps compositing
#     sudo ./run.sh --primary-gpu       # install the rule, restart it yourself
#     sudo ./run.sh --skip-preflight    # plain bring-up, neither of the two
#
# Deliberately NOT "on unless negated": that would make every invocation
# destructive, including ones like --retrain where a session restart is beside
# the point.
DEFAULTS_APPLIED=0
if (( $# == 0 )); then
    RESTART_UI=1
    PRIMARY_GPU=on
    DEFAULTS_APPLIED=1
fi

LNKCTL2=CAP_EXP+30.w
LNKCTL=CAP_EXP+10.w
LNKSTA=CAP_EXP+12.w

[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo $0" >&2; exit 1; }
[[ $CAP_SPEED =~ ^[1-4]$ ]] || { echo "ERROR: CAP_SPEED must read 1..4" >&2; exit 1; }

mkdir -p "$LOGDIR"; chown "${SUDO_USER:-root}:" "$LOGDIR" 2>/dev/null || true
exec > >(tee -a "$SLOG") 2>&1

ok()   { printf '  \033[32m+\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31mx\033[0m %s\n' "$*"; }
hdr()  { printf '\n\033[1m=== %s ===\033[0m\n' "$*"; }
# NOTE: "info" must be defined here. It is also a real binary (/usr/bin/info,
# the GNU documentation reader), so a missing definition does not fail loudly -
# bash silently runs the reader and the intended message is lost.
info() { printf '    %s\n' "$*"; }

gsp_running() {
    local v; v=$(nvidia-smi -q 2>/dev/null | grep -i 'GSP Firmware Version' | sed 's/.*: *//')
    [[ -n $v && $v != N/A ]] && { echo "$v"; return 0; }; return 1
}
# One value, for one device. "head -1" is a guard: if GPU were ever empty,
# lspci would report every device on the bus and the caller would compare a
# multi-line string against "256M".
bar1() {
    [[ -n ${GPU:-} ]] || return 1
    lspci -vv -s "${GPU#*:}" 2>/dev/null \
        | grep -oP 'Region 1:.*\[size=\K[^]]+' | head -1
}
unload_stack() {
    local m
    for m in nvidia_drm nvidia_modeset nvidia_uvm nvidia; do
        [[ -d /sys/module/$m ]] || continue
        if modprobe -r "$m" 2>/dev/null; then ok "$m unloaded"
        else
            bad "$m NOT unloaded (refcnt=$(cat /sys/module/$m/refcnt 2>/dev/null))"
            if [[ $m == nvidia_drm ]]; then
                info "Normal while a graphical session is running: the compositor"
                info "holds /dev/dri/card0 open. The card is already up - what"
                info "needs restarting is the session, not the card:"
                info "    sudo $0 --restart-ui"
            else
                info "check: sudo lsof /dev/nvidia*  ;  systemctl stop nvidia-persistenced"
            fi
            return 1
        fi
    done
    return 0
}
show_link() {
    local dev c2 st
    for dev in "$BRIDGE" "$GPU"; do
        c2=$(setpci -s "$dev" "$LNKCTL2" 2>/dev/null) || { echo "      $dev: no read"; continue; }
        st=$(setpci -s "$dev" "$LNKSTA" 2>/dev/null) || st=0000
        printf "      %s  Target=Gen%d  bit5=%s  LnkSta=Gen%d\n" "$dev" \
            "$((0x$c2 & 0xf))" \
            "$([[ $((0x$c2 & 0x20)) -ne 0 ]] && echo yes || echo no)" \
            "$((0x$st & 0xf))"
    done
}

echo "==================================================================="
echo " run  $STAMP"
echo " log: $SLOG"
echo "==================================================================="

# Never let the defaults be a surprise - state them in the terminal and in the
# log, before anything is touched, while Ctrl+C is still free.
if (( DEFAULTS_APPLIED )); then
    hdr "Defaults applied (no arguments given)"
    ok "--restart-ui   the session WILL be restarted - open windows are lost"
    ok "--primary-gpu  the card becomes the compositor's primary GPU"
    info "Verified here: external monitor 137.9 -> 230 fps, internal 181.1 -> ~150"
    warn "the card becomes a single point of failure for the whole desktop"
    info "Recovery if the desktop does not come back:"
    info "  Ctrl+Alt+F3, then: sudo $DIR/10-primary-gpu.sh --off"
    info "  followed by:       sudo systemctl restart gdm"
    info "  or just reboot - the rule lives in /run and the card is absent at boot"
    info ""
    info "Not what you wanted? Ctrl+C now. Any explicit flag disables both:"
    info "  sudo $0 --skip-preflight   # plain bring-up, no restart, no switch"
    warn "continuing in 5 s"
    sleep 5
fi

# ---------- REVERT ----------
if (( WANT_OFF )); then
    hdr "REVERTING to the no-GSP configuration"
    unload_stack || warn "a reboot fixes this"
    printf 'options nvidia NVreg_EnableGpuFirmware=0\n' > "$GSPOFF"
    ok "restored $GSPOFF"
    shopt -s nullglob; for f in "$GSPOFF".disabled-*; do rm -f "$f"; ok "removed $(basename "$f")"; done; shopt -u nullglob
    if [[ -d /sys/bus/pci/devices/$GPU ]]; then
        BRIDGE=${BRIDGE:-$(basename "$(dirname "$(readlink -f /sys/bus/pci/devices/"$GPU")")")}
        for dev in "$BRIDGE" "$GPU"; do
            setpci -s "$dev" "$LNKCTL2"=0004:000f 2>/dev/null
            setpci -s "$dev" "$LNKCTL2"=0000:0020 2>/dev/null
        done
        ok "cap removed"
    else
        warn "card not present - no cap to remove"
    fi
    echo; echo "Next: sudo reboot, then sudo $0"
    exit 0
fi
# ---------- RESTART UI ----------
#
# --restart-ui is a MODIFIER, not a separate action:
#
#   card already up  ->  restart the session only, skip the bring-up
#   card not up      ->  bring it up first, then restart the session
#
# WHY THE FIRST CASE MUST SKIP THE PIPELINE
#
# You reach for this exactly when the card is up but the monitor stays black. At
# that moment the compositor holds /dev/dri/card0 open, so nvidia_drm has a
# non-zero refcount and CANNOT be unloaded. Running the bring-up would abort at
# the unload step and never get to the restart - the option would be useless
# precisely when it is needed. So when the card is already working we go
# straight to the restart and touch nothing.
#
# WHY THE SECOND CASE MUST NOT RESTART FIRST
#
# Restarting the session before the card exists accomplishes nothing: the
# compositor comes back and still finds no GPU. The card has to be up first,
# which is why the restart then happens at the very end of this script.

# "Up" means the driver is loaded, talks to the card, and the window is in
# place. Anything less and the bring-up has work to do.
card_is_up() {
    [[ -d /sys/module/nvidia ]] || return 1
    [[ $(bar1) == 256M ]] || return 1
    nvidia-smi >/dev/null 2>&1 || return 1
    return 0
}

restart_ui() {
    hdr "Restarting the display manager"
    local DM
    DM=$(systemctl show display-manager.service -p Id --value 2>/dev/null)
    DM=${DM:-gdm.service}
    printf "      %-12s %s\n" "unit" "$DM"
    if [[ -d /sys/module/nvidia_drm ]]; then
        printf "      %-12s refcnt=%s (held by the compositor - expected)\n" \
            "nvidia_drm" "$(cat /sys/module/nvidia_drm/refcnt 2>/dev/null)"
    fi
    warn "restarting in 5 s - every open window will be lost"
    warn "press Ctrl+C to cancel"
    sleep 5
    # MUST be detached: restarting the display manager kills the session this
    # script runs in, which would take the script down mid-call. A transient
    # systemd unit outlives that session.
    if systemd-run --collect --unit=egpu-restart-ui \
            systemctl restart "$DM" >/dev/null 2>&1; then
        ok "restart handed off to systemd"
        return 0
    fi
    bad "could not hand off the restart"
    info "do it by hand: sudo systemctl restart $DM"
    return 1
}

if (( RESTART_UI )) && card_is_up; then
    hdr "Card is already up - restarting the session only"
    printf "      %-12s %s\n" "GPU" "$GPU"
    printf "      %-12s %s\n" "BAR1" "$(bar1)"
    v=$(gsp_running) && printf "      %-12s %s\n" "GSP" "$v"
    info "The bring-up is skipped: nothing to do to the card, and the"
    info "compositor is holding it open anyway."
    restart_ui; exit $?
fi
if (( RESTART_UI )); then
    hdr "Card is not up yet - bringing it up first, then restarting the session"
fi

# ---------- 0. PREREQUISITES ----------
# Missing files under /etc show up not as an error but as a machine RESET, so
# they are verified BEFORE we touch hardware. --skip-preflight deliberately only.
if (( ! SKIP_PRE )); then
    hdr "0. Prerequisites (1-check.sh)"
    if [[ ! -x $DIR/1-check.sh ]]; then
        bad "missing $DIR/1-check.sh - package incomplete"; exit 1
    fi
    if "$DIR/1-check.sh" --quiet; then
        ok "prerequisites satisfied"
    else
        bad "prerequisites NOT satisfied - aborting before touching the hardware"
        echo
        "$DIR/1-check.sh" | grep -E 'FAIL|missing' || true
        echo
        info "Full report:   sudo $DIR/1-check.sh"
        info "Attempt a fix: sudo $DIR/1-check.sh --fix"
        info "Skip anyway:   sudo $0 --skip-preflight"
        exit 1
    fi
fi

# ---------- 1. ENTRY STATE ----------
hdr "1. Entry state"
if [[ ! -d /sys/bus/pci/devices/$GPU ]]; then
    bad "card $GPU not present on the PCI bus"
    echo
    info "The Thunderbolt tunnel is not established. Do this:"
    info "  1. unplug the TB cable from the enclosure"
    info "  2. power the enclosure off and on"
    info "  3. plug the cable back in (the same port as always)"
    info "  4. boltctl list | grep -A2 TBT   -> must read 'connected'"
    info "  5. run this again"
    exit 1
fi
ok "card $GPU present  ($EGPU_VENDOR_NAME)"
printf "      %-12s %s\n" "BAR1" "$(bar1 || echo 'none - window not set up')"
printf "      %-12s %s\n" "modules" "$(for m in nvidia nvidia_uvm nvidia_modeset nvidia_drm egpu_rp_window; do
    [[ -d /sys/module/$m ]] && printf '%s ' "$m"; done; echo)"
if v=$(gsp_running); then ok "GSP already running ($v)"; else warn "GSP not running (yet)"; fi

# ---------- 2. WINDOW AND BARs ----------
hdr "2. Root-port window and BARs"
if [[ $(bar1) == 256M ]]; then
    ok "BAR1 = 256M, window already in place - skipping 3-setup"
else
    warn "BAR1 not set up - running 3-setup.sh"
    # CRITICAL: 3-setup ends in modprobe nvidia. Without the GSP block and
    # without the cap this is exactly the configuration that reset the machine.
    printf 'options nvidia NVreg_EnableGpuFirmware=0\n' > "$GSPOFF"
    ok "GSP block inserted for the duration of 3-setup (safety net)"
    [[ -x $DIR/3-setup.sh ]] || { bad "missing $DIR/3-setup.sh"; exit 1; }
    if "$DIR/3-setup.sh"; then ok "3-setup succeeded"
    else bad "3-setup failed - no point continuing"; exit 1; fi
    [[ $(bar1) == 256M ]] || { bad "BAR1 still != 256M ($(bar1))"; exit 1; }
fi

# ---------- 3. BRIDGE ----------
hdr "3. Bridge above the card"
ok "$BRIDGE"
lspci -s "${BRIDGE#*:}" 2>/dev/null | sed 's/^/      /'
lspci -s "${BRIDGE#*:}" 2>/dev/null | grep -qiE 'thunderbolt|usb4' \
    || { bad "not a Thunderbolt/USB4 bridge - aborting"; exit 1; }
show_link

# ---------- 4. UNLOAD ----------
hdr "4. Unloading the nvidia stack (the cap must precede the bind)"
systemctl stop nvidia-persistenced 2>/dev/null && ok "stopped nvidia-persistenced" || true
unload_stack || { bad "cannot unload - aborting"; exit 1; }
[[ -d /sys/module/nvidia ]] || ok "stack is clean"

# ---------- 5. LINK CAP ----------
hdr "5. PCIe link speed cap (Gen$CAP_SPEED + bit 5)"
TGT=$(printf '%04x' "$CAP_SPEED")
for dev in "$BRIDGE" "$GPU"; do
    setpci -s "$dev" "$LNKCTL2"="$TGT":000f || { bad "writing Target on $dev failed"; exit 2; }
    setpci -s "$dev" "$LNKCTL2"=0020:0020   || { bad "writing bit 5 on $dev failed"; exit 2; }
    ok "$dev -> Target Gen$CAP_SPEED + bit5"
done
if (( WANT_RETRAIN )); then
    warn "forcing a retrain on $BRIDGE - the tunnel may drop here"
    setpci -s "$BRIDGE" "$LNKCTL"=0020:0020 && ok "retrain issued"
    sleep 2
    [[ -d /sys/bus/pci/devices/$GPU ]] || {
        bad "THE CARD FELL OFF THE BUS"
        info "power-cycle the enclosure, then: sudo $0 --off && sudo reboot"; exit 3; }
    ok "card survived the retrain"
fi
show_link

# ---------- 6. GSP ----------
hdr "6. GSP mode"
if (( WANT_GSP )); then
    if [[ -f $GSPOFF ]]; then mv "$GSPOFF" "$GSPOFF.disabled-$STAMP"; ok "GSP ENABLED"
    else ok "GSP ENABLED (there was no block anyway)"; fi
else
    printf 'options nvidia NVreg_EnableGpuFirmware=0\n' > "$GSPOFF"; ok "GSP disabled (--no-gsp)"
fi

# ---------- 7. LOAD ----------
hdr "7. Loading the driver"
modprobe --ignore-install nvidia || { bad "modprobe nvidia failed"; exit 4; }
ok "nvidia loaded"
sleep 2
if nvidia-smi >/dev/null 2>&1; then ok "nvidia-smi passes (this is where the reset used to happen)"
else bad "nvidia-smi failed"; exit 5; fi
if v=$(gsp_running); then ok "GSP RUNNING - firmware $v"
elif (( WANT_GSP )); then warn "GSP requested, but the firmware reports no version"
else ok "GSP disabled as requested"; fi
for m in nvidia_uvm nvidia_modeset; do
    modprobe --ignore-install $m && ok "$m" || warn "$m failed"
done
# WHY ub-device-create IS CALLED HERE
#
# Ubuntu creates the /dev/nvidia* nodes with /sbin/ub-device-create (shipped by
# nvidia-kernel-common-610), triggered by a udev rule that fires when nvidia
# BINDS to the PCI device. At that moment nvidia_modeset is not loaded yet - we
# load it here, by hand, and our own /etc/udev/rules.d/71-nvidia.rules has the
# "RUN+=/sbin/modprobe nvidia-modeset" line commented out on purpose (auto-load
# hung the machine during bring-up).
#
# So nothing ever created /dev/nvidia-modeset, and NOTHING VISIBLE BROKE:
# compute, CUDA, rendering and KMS all use other nodes. Only Vulkan does
# open("/dev/nvidia-modeset") - it got ENOENT and the driver reported
# VK_ERROR_UNKNOWN, which cost a full day of chasing a phantom driver bug.
# vulkaninfo did not even error, it segfaulted.
#
# Re-running the helper after nvidia_modeset is up creates the missing node.
# It is idempotent, so calling it unconditionally is safe.
if [[ -x /sbin/ub-device-create ]]; then
    /sbin/ub-device-create 2>/dev/null || true
fi
if [[ -e /dev/nvidia-modeset ]]; then
    ok "/dev/nvidia-modeset present (Vulkan presentation needs it)"
else
    # Fall back to creating it directly. Major 195 is shared by nvidia,
    # nvidia-modeset and nvidiactl (see /proc/devices); nvidiactl is minor 255,
    # GPUs are 0..N, nvidia-modeset is 254.
    mknod /dev/nvidia-modeset c 195 254 2>/dev/null && chmod 666 /dev/nvidia-modeset 2>/dev/null \
        && ok "/dev/nvidia-modeset created by hand" \
        || bad "/dev/nvidia-modeset MISSING - Vulkan presentation will fail with VK_ERROR_UNKNOWN"
fi
# fbdev is repeated for the same reason as modeset: modprobe.d is concatenated
# and the kernel takes the last value, so stating both here makes the effective
# configuration deterministic no matter what an older install left behind.
# Both are the driver's own defaults - see "modinfo -p nvidia-drm".
modprobe --ignore-install nvidia_drm modeset=1 fbdev=1 \
    && ok "nvidia_drm modeset=1 fbdev=1" || warn "nvidia_drm failed"
sleep 3

# ---------- 8. CARD OUTPUTS ----------
hdr "8. Card outputs"
nvcard=""
for c in /sys/class/drm/card[0-9]*; do
    [[ -e $c/device/driver ]] || continue
    [[ $(basename "$(readlink -f "$c/device/driver")") == nvidia ]] && nvcard=$(basename "$c")
done
if [[ -z $nvcard ]]; then
    warn "no DRM card owned by nvidia - KMS inactive"
else
    printf "      %-12s %-14s %-8s %s\n" CONNECTOR STATUS EDID MODE
    live=0
    for conn in /sys/class/drm/$nvcard-*; do
        [[ -e $conn/status ]] || continue
        st=$(cat "$conn/status"); ed=$(wc -c < "$conn/edid" 2>/dev/null || echo 0)
        [[ $st == connected ]] && live=1
        printf "      %-12s %-14s %-8s %s\n" "${conn##*/$nvcard-}" "$st" "${ed}B" \
            "$(head -1 "$conn/modes" 2>/dev/null || echo '-')"
    done
    (( live )) && ok "card sees a monitor" || warn "card sees no monitor (plugged in? powered on?)"
fi

# A connector can be "connected" with a valid EDID and still show nothing,
# because reading EDID and driving a display are different things. Driving it is
# the compositor's job, and the compositor has to know the output exists.
#
# What we learned here (mutter 50.1, Wayland): mutter DOES pick up a hot-plugged
# GPU - its own log says "Added device '/dev/dri/card0' (nvidia-drm) using
# atomic mode setting". What can still be missing is a CONNECTOR hotplug event:
# if the monitor was already attached when the driver loaded, mutter may have
# enumerated connectors before the driver finished detecting them, and it will
# not re-probe on its own. Replugging the cable generates that event.
#
# So the cheap remedy comes first. Restarting the session is the fallback.
if [[ -n ${nvcard:-} ]]; then
    stuck=""
    for conn in /sys/class/drm/$nvcard-*; do
        [[ -e $conn/status && -e $conn/enabled ]] || continue
        [[ $(cat "$conn/status") == connected && $(cat "$conn/enabled") == disabled ]] \
            && stuck="$stuck ${conn##*/$nvcard-}"
    done
    if [[ -n $stuck ]]; then
        echo
        warn "connected but not driven:$stuck"
        info "The card reads the monitor; nothing has set a mode on it yet."
        info "Try in this order:"
        info "  1. unplug and replug the monitor cable - generates a connector"
        info "     hotplug event, which is usually all that is missing"
        info "  2. restart the session (costs your open windows):"
        info "       sudo $0 --restart-ui"
    fi
fi

# ---------- 9. TELEMETRY ----------
hdr "9. Telemetry"
nvidia-smi --query-gpu=pstate,power.draw,temperature.gpu,fan.speed,clocks.current.sm,clocks.current.memory \
    --format=csv 2>/dev/null | sed 's/^/      /'
T=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader 2>/dev/null)
F=$(nvidia-smi --query-gpu=fan.speed --format=csv,noheader,nounits 2>/dev/null)
if [[ ${F:-1} == 0 && ${T:-99} -lt 60 ]]; then
    ok "fans at 0% and ${T}C is zero-RPM mode, NORMAL for this card"
    info "It stops the fans below ~60C and spins them up on its own under load."
fi

# ---------- 10. COMPOSITOR'S PRIMARY GPU (opt-in) ----------
#
# This decides who COMPOSITES, which controls how many times a frame crosses
# the tunnel:
#
#   primary = Radeon (default)   internal 1 crossing, external 2
#   primary = RTX                internal 1 crossing, external 0
#
# The external monitor stops crossing the tunnel entirely; the internal panel
# starts carrying the whole composited desktop instead of just window buffers.
# Worth it only if you mostly work on the external monitor - hence opt-in.
#
# Must run AFTER the driver is loaded: 10-primary-gpu.sh reads the card's PCI
# IDs from the live device rather than hardcoding them.
if [[ $PRIMARY_GPU != keep ]]; then
    hdr "10. Compositor's primary GPU (--primary-gpu)"
    if [[ ! -x $DIR/10-primary-gpu.sh ]]; then
        warn "missing $DIR/10-primary-gpu.sh - skipping"
    elif [[ $PRIMARY_GPU == on ]]; then
        # NON-FATAL on purpose: this is an optimisation on top of a card that
        # already works. It must not turn a good bring-up into a failure.
        if "$DIR/10-primary-gpu.sh" --on; then
            (( RESTART_UI )) || {
                warn "not active yet - it needs a session restart"
                info "    sudo $0 --restart-ui"
                info "or re-run with --restart-ui to do both in one go."
            }
        else
            warn "could not set the primary GPU - the card is up regardless"
        fi
    else
        "$DIR/10-primary-gpu.sh" --off || warn "could not remove the primary-GPU override"
    fi
fi

if (( RESTART_UI )); then
    restart_ui || true
fi

hdr "DONE"
echo "  Check outputs later:  sudo $DIR/9-check-outputs.sh --force"
echo "  Who composites:       $DIR/10-primary-gpu.sh --status"
echo "  GPU selection reset:  sudo $0 --reset"
echo "  Restart the session:  sudo $0 --restart-ui"
echo "  Revert to no-GSP:     sudo $0 --off"
echo "  Log of this run:      $SLOG"
