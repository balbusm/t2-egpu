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
#   sudo ./run.sh
#   sudo GPU=<bdf> ./run.sh            # pick a card when several are present
#                                      (get <bdf> from ./2-devices.sh)
#   sudo CAP_SPEED=2 ./run.sh        # lower link ceiling (1..4, default 3)
#   sudo ./run.sh --retrain          # force a link retrain
#   sudo ./run.sh --no-gsp           # load without GSP
#   sudo ./run.sh --off              # revert to the no-GSP configuration
#   sudo ./run.sh --skip-preflight   # skip the 1-check gate
#   sudo ./run.sh --restart-ui       # restart the display manager at the end

set -uo pipefail

GPU=${GPU:-}
BRIDGE=${BRIDGE:-}
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # the package is self-locating
SELFDIR="$DIR"
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

for a in "$@"; do case $a in
    --retrain) WANT_RETRAIN=1 ;;
    --no-gsp)  WANT_GSP=0 ;;
    --off)     WANT_OFF=1; WANT_GSP=0; SKIP_PRE=1 ;;
    --skip-preflight) SKIP_PRE=1 ;;
    --restart-ui) RESTART_UI=1 ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $a" >&2; exit 1 ;;
esac; done

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
# ---------- RESTART UI: standalone action ----------
#
# WHY THIS IS HANDLED FIRST, BEFORE ANYTHING ELSE
#
# You reach for --restart-ui exactly when the card is up but the monitor stays
# black. At that moment the compositor holds /dev/dri/card0 open, so nvidia_drm
# has a non-zero refcount and CANNOT be unloaded. If this option sat at the end
# of the bring-up pipeline, that pipeline would abort at the unload step and
# never reach it - the option would be unreachable precisely when needed.
#
# So it is standalone: restart the display manager and exit. The card is not
# touched, because the card does not need touching.
if (( RESTART_UI )); then
    hdr "Restarting the display manager"
    DM=$(systemctl show display-manager.service -p Id --value 2>/dev/null)
    DM=${DM:-gdm.service}
    printf "      %-12s %s\n" "unit" "$DM"
    if [[ -d /sys/module/nvidia_drm ]]; then
        printf "      %-12s refcnt=%s (held by the compositor - expected)\n" \
            "nvidia_drm" "$(cat /sys/module/nvidia_drm/refcnt 2>/dev/null)"
    else
        warn "nvidia_drm is not loaded - bring the card up first, then restart the UI"
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
        exit 0
    fi
    bad "could not hand off the restart"
    info "do it by hand: sudo systemctl restart $DM"
    exit 1
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
modprobe --ignore-install nvidia_drm modeset=1 && ok "nvidia_drm modeset=1" || warn "nvidia_drm failed"
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

hdr "DONE"
echo "  Check outputs later:  sudo $DIR/9-check-outputs.sh --force"
echo "  Restart the session:  sudo $0 --restart-ui"
echo "  Revert to no-GSP:     sudo $0 --off"
echo "  Log of this run:      $SLOG"
