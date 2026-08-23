#!/usr/bin/env bash
# 8-link-cap-gsp.sh - the cautious variant of the link cap plus GSP.
#
# run.sh does the same thing inline and is what you normally want. Use this
# one when a run might hang the machine: it detaches itself as a systemd unit,
# drops the graphical session, and captures the kernel log to a file with a
# sync every 0.2 s, so evidence survives a hard reset. Also the way to revert
# (--off) and to arm panic-on-stall (--arm-panic).
#
# THE MECHANISM IT IMPLEMENTS
#
# Behind a Thunderbolt tunnel the PCIe link oscillates Gen3<->Gen4. The driver
# retrains it upwards to Gen4, and that retrain inside the GSP RPC handshake
# window drops the card off the bus - an instant reset with no kernel output,
# no oops and no AER. Two fields in Link Control 2 (CAP_EXP+0x30) decide it:
#
#   bit 5      Hardware Autonomous Speed Disable - stops the oscillation
#   bits [3:0] Target Link Speed - the ceiling (3 = Gen3)
#
# The cap must be applied BEFORE nvidia.ko binds. Confirmed on this hardware
# 2026-08-21: with the cap, nvidia-smi survives, GSP reports its firmware
# version, and the card's own HDMI output works.
#
# WHAT IT DOES NOT TOUCH
#
# The root-port window and the BAR assignment. Link speed and GSP are not
# resources, so there is no need to repeat 3-setup.
#
# RISK
#
# --retrain forces a link retrain. If the tunnel drops, the card falls off the
# bus and the enclosure needs a power cycle, losing the in-memory allocation.
# That is why retrain is not the default: Target Link Speed already constrains
# every future retrain, and bit 5 takes effect immediately.
#
# USAGE
#
#   sudo ./8-link-cap-gsp.sh              # Gen3 + bit 5, GSP on
#   sudo CAP_SPEED=2 ./8-link-cap-gsp.sh  # Gen2 ceiling
#   sudo ./8-link-cap-gsp.sh --retrain    # force a retrain as well
#   sudo ./8-link-cap-gsp.sh --off        # revert: GSP off, cap removed
#   sudo ./8-link-cap-gsp.sh --arm-panic  # panic on kernel stall (diagnostics)

set -uo pipefail

SELFDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # the package is self-locating
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
SYSCTL=/etc/sysctl.d/99-egpu-panic.conf
LOGDIR=$SELFDIR/logs
STAMP=$(egpu_stamp)
# Named after THIS script. The logs used to be written as "7-link-cap-*", left
# over from before the renumbering, which made them look like output of
# 7-bar-fallback.sh.
KLOG=$LOGDIR/8-link-cap-kernel-$STAMP.log

CAP_SPEED=${CAP_SPEED:-3}          # 1|2|3|4 - Target Link Speed
WANT_OFF=0
WANT_RETRAIN=0
WANT_PANIC=0        # panic on stall: only when asked for
for a in "$@"; do
    case $a in
        --off)     WANT_OFF=1 ;;
        --retrain) WANT_RETRAIN=1 ;;
        --arm-panic) WANT_PANIC=1 ;;
        -h|--help) egpu_usage "$0"; exit 0 ;;
        *) echo "Unknown argument: $a" >&2; exit 1 ;;
    esac
done

egpu_require_root "[--off] [--retrain]"
[[ $CAP_SPEED =~ ^[1-4]$ ]] || { echo "ERROR: CAP_SPEED must read 1..4" >&2; exit 1; }

# --- preflight ---
#
# HAVE_HW=0 means the card is not on the bus. When applying the cap that is
# fatal. With --off it is NOT: after a failed attempt the machine resets,
# the card usually drops out of the tunnel, and what matters then is restoring
# the GSP block - otherwise 3-setup.sh walks straight back into it. Reverting
# must ALWAYS work.
HAVE_HW=1
if [[ ! -d /sys/bus/pci/devices/$GPU ]]; then
    if (( WANT_OFF )); then
        HAVE_HW=0
        echo "NOTE: card $GPU not present - reverting only the GSP configuration,"
        echo "       there is no link cap to remove (it would not survive a reset anyway)."
    else
        echo "ERROR: card $GPU not present - nothing to cap." >&2
        echo "  Power-cycle the enclosure, then run sudo ./run.sh" >&2
        exit 1
    fi
fi
# Bridge above the card. Resolved by lib/egpu-lib.sh from the sysfs parent,
# never hardcoded: bus numbers behind a Thunderbolt tunnel shift between
# machines, between ports and between hot-plugs. BRIDGE= overrides.
if (( HAVE_HW )); then
    echo "Bridge above the card: $BRIDGE"
    lspci -s "${BRIDGE#*:}" 2>/dev/null | sed 's/^/  /'
    if ! lspci -s "${BRIDGE#*:}" 2>/dev/null | grep -qiE 'thunderbolt|usb4'; then
        echo "WARNING: $BRIDGE does not look like a Thunderbolt/USB4 bridge." >&2
        echo "  The link-speed cap only makes sense behind a tunnel." >&2
        exit 1
    fi
fi
if (( HAVE_HW )) && [[ ! -d /sys/bus/pci/devices/$BRIDGE ]]; then
    echo "ERROR: bridge $BRIDGE not present." >&2
    exit 1
fi

# Detach from the session, because a hang is possible.
#
# --off does NOT do that: it only restores configuration, there is nothing
# to hang the machine with, and killing the session while reverting is hostile.
MYTTY=$(tty 2>/dev/null || echo '?')
if (( ! WANT_OFF )) && [[ $MYTTY != /dev/tty[0-9]* && ${EGPU_DETACHED:-0} != 1 ]]; then
    command -v systemd-run >/dev/null || { echo "ERROR: on $MYTTY and systemd-run is missing" >&2; exit 1; }
    echo "You are on $MYTTY. Detaching as a systemd unit (the graphical session will go)."
    echo "When it finishes: Ctrl+Alt+F1, then"
    echo "  sudo cat \$(ls -t $LOGDIR/8-link-cap-*.log | head -1)"
    echo "Starting in 5 s (Ctrl+C aborts)..."
    sleep 5
    exec systemd-run --unit=egpu-8-link-cap-gsp --collect \
        -p IgnoreOnIsolate=yes -p Type=oneshot -p TimeoutStartSec=900 \
        -E EGPU_DETACHED=1 -E CAP_SPEED="$CAP_SPEED" \
        -E GPU="$GPU" -E BRIDGE="$BRIDGE" "$0" "$@"
fi

egpu_log_open "$LOGDIR" 8-link-cap "$STAMP"
trap egpu_cleanup EXIT
SLOG=$EGPU_LOG

show_link() {
    echo "  --- $1 ---"
    if (( ! HAVE_HW )); then echo "    (card not present - nothing to read)"; return 0; fi
    egpu_show_link "$BRIDGE" "$GPU"
}

echo "==================================================================="
echo " 8-link-cap-gsp: $([[ $WANT_OFF == 1 ]] && echo 'REVERT - cap removed, GSP disabled' \
                                     || echo "cap Gen$CAP_SPEED + bit5, GSP ENABLED")"
echo " log: $SLOG   (kernel: $KLOG)"
echo "==================================================================="

# --- REVERT: short, self-contained path ---
#
# Must be reliable and work with no card on the bus, because this is what
# you run after a failed attempt, often right after the machine reset.
# Loads nothing - restores the configuration and exits. Then: reboot + 3-setup.
if (( WANT_OFF )); then
    echo
    echo "=== 1. Unloading the nvidia stack (if any) ==="
    egpu_unload_stack || echo "  a reboot fixes this"

    echo
    echo "=== 2. Restoring the GSP block ==="
    printf 'options nvidia NVreg_EnableGpuFirmware=0\n' > "$GSPOFF"
    echo "  wrote $GSPOFF:"
    sed 's/^/    /' "$GSPOFF"
    shopt -s nullglob
    for f in "$GSPOFF".disabled-*; do rm -f "$f" && echo "  removed old copy $(basename "$f")"; done
    shopt -u nullglob

    echo
    echo "=== 3. Removing the link cap ==="
    if (( HAVE_HW )); then
        show_link "link BEFORE removing the cap"
        egpu_cap_clear "$BRIDGE" "$GPU" && echo "  Target -> Gen4, bit5 cleared"
        show_link "link AFTER removing the cap"
        echo "  (only a reboot returns the window fully to its firmware state)"
    else
        echo "  skipped - card not present, cap it would not have survived the reset anyway"
    fi

    cat <<EOF

=== REVERTED ===
  GSP is disabled in the configuration. Next:
      sudo reboot
      # power-cycle the enclosure, plug into THE SAME port
      sudo ./run.sh
EOF
    exit 0
fi

echo
echo "=== 1. Panic on kernel stall ==="
# NOT by default. Diagnosis is over (GSP works), and softlockup_panic=1
# means every transient kernel stall ends in a reboot and lost work.
# Enable only for a new risky experiment.
if (( WANT_PANIC )); then
    cat > "$SYSCTL" <<'EOF'
# Stall -> panic -> warm reboot. Armed deliberately for experiments (--arm-panic).
kernel.hung_task_panic = 1
kernel.softlockup_panic = 1
kernel.hardlockup_panic = 1
kernel.panic = 15
kernel.sysrq = 1
EOF
    echo "  ARMED (--arm-panic) - a kernel stall will end in a reboot"
    sysctl -p "$SYSCTL" 2>&1 | sed 's/^/    /'
else
    echo "  skipped - panic settings left alone (add --arm-panic to change them)"
    printf "    currently: softlockup_panic=%s hardlockup_panic=%s panic=%s\n" \
        "$(sysctl -n kernel.softlockup_panic 2>/dev/null)" \
        "$(sysctl -n kernel.hardlockup_panic 2>/dev/null)" \
        "$(sysctl -n kernel.panic 2>/dev/null)"
fi

echo
echo "=== 2. Entry state ==="
printf "  BAR1: %s\n" "$(egpu_bar_size "$GPU" 1)"
printf "  GSP:  %s\n" "$(grep -oP 'EnableGpuFirmware: \K\S+' /proc/driver/nvidia/params 2>/dev/null || echo 'none (module not loaded)')"
printf "  modules: %s\n" "$(egpu_loaded_modules)"
show_link "link BEFORE the change"

echo
echo "=== 3. Dropping the graphical session ==="
if systemctl is-active graphical.target >/dev/null 2>&1; then
    systemctl isolate multi-user.target; sleep 4; echo "  dropped"
else
    echo "  already inactive"
fi
systemctl stop nvidia-persistenced 2>/dev/null && echo "  stopped nvidia-persistenced" || true

echo
echo "=== 4. Capturing the kernel log ==="
egpu_klog_start "$KLOG"
echo "  active"

echo
echo "=== 5. Unloading the nvidia stack (the cap MUST precede the bind) ==="
mark "BEFORE unloading"
egpu_unload_stack || { echo "  aborting, a reboot will be needed" >&2; exit 1; }
mark "AFTER unloading"

echo
echo "=== 6. Applying the cap BEFORE loading nvidia ==="
mark "cap $BRIDGE and $GPU"
egpu_cap_apply "$CAP_SPEED" "$BRIDGE" "$GPU" || exit 2
if (( WANT_RETRAIN )); then
    mark "BEFORE retrain $BRIDGE"
    echo "  forcing a retrain on $BRIDGE (the tunnel may drop here)"
    setpci -s "$BRIDGE" "$EGPU_LNKCTL"=0020:0020 && echo "  retrain issued" || echo "  retrain FAILED" >&2
    sleep 2
    mark "AFTER retrain"
    if [[ ! -d /sys/bus/pci/devices/$GPU ]]; then
        echo "  THE CARD FELL OFF THE BUS after the retrain." >&2
        echo "  Power-cycle the enclosure, then: sudo $0 --off && sudo reboot" >&2
        exit 3
    fi
else
    echo "  retrain skipped (add --retrain if GSP still dies)"
fi
show_link "link AFTER the change"

echo
echo "=== 7. Enabling GSP ==="
if [[ -f $GSPOFF ]]; then
    mv "$GSPOFF" "$GSPOFF.disabled-$STAMP"
    echo "  removed $GSPOFF (backup .disabled-$STAMP) - GSP enabled"
else
    echo "  $GSPOFF no longer exists - GSP enabled"
fi
modprobe --dry-run --ignore-install --show-depends nvidia 2>&1 | tail -1 | tr ' ' '\n' | grep NVreg | sed 's/^/    /' || true

echo
echo "=== 8. Loading nvidia ==="
mark "BEFORE modprobe nvidia"
if ! modprobe --ignore-install nvidia; then
    rc=$?; mark "ERROR nvidia rc=$rc"; dmesg | tail -25 | sed 's/^.*\] /    /'; exit $rc
fi
mark "AFTER modprobe nvidia"
sleep 3
printf "  GSP requested mode: %s\n" "$(grep -oP 'EnableGpuFirmware: \K\S+' /proc/driver/nvidia/params 2>/dev/null || echo '?')"
dmesg | tail -40 | grep -iE 'gsp|lockdown|firmware|xid' | tail -10 | sed 's/^.*\] /    /' || true

echo
echo "=== 9. nvidia-smi - THIS IS WHERE FIVE EARLIER ATTEMPTS RESET THE MACHINE ==="
mark "BEFORE nvidia-smi"
if nvidia-smi; then mark "AFTER nvidia-smi OK"; else rc=$?; mark "AFTER nvidia-smi ERROR rc=$rc"; fi
show_link "link after GPU initialisation"

echo
echo "=== 10. nvidia_uvm + modeset + drm ==="
modprobe --ignore-install nvidia_uvm     && echo "  nvidia_uvm OK"     || echo "  nvidia_uvm failed"
mark "BEFORE nvidia_modeset"
modprobe --ignore-install nvidia_modeset && echo "  nvidia_modeset OK" || echo "  nvidia_modeset failed"
# See run.sh for why this is needed - without it /dev/nvidia-modeset never
# appears and Vulkan presentation fails with VK_ERROR_UNKNOWN.
[[ -x /sbin/ub-device-create ]] && /sbin/ub-device-create 2>/dev/null || true
[[ -e /dev/nvidia-modeset ]] || { mknod /dev/nvidia-modeset c 195 254 2>/dev/null && chmod 666 /dev/nvidia-modeset 2>/dev/null; }
echo "  /dev/nvidia-modeset: $([[ -e /dev/nvidia-modeset ]] && echo present || echo MISSING)"
mark "BEFORE nvidia_drm"
modprobe --ignore-install nvidia_drm modeset=1 fbdev=1 && echo "  nvidia_drm OK" || echo "  nvidia_drm failed"
mark "AFTER nvidia_drm"
sleep 4

echo
echo "=== 11. CONNECTORS - does the card read EDID (the real test) ==="
if ! egpu_nv_card; then
    echo "  no DRM card from nvidia"
else
    egpu_print_connectors "$EGPU_CARD" || true
    echo
    echo "  AUX/EDID errors from nvidia-modeset (empty = the card reads EDID):"
    dmesg | grep -i 'nvidia-modeset' | grep -iE 'edid|aux' | tail -6 | sed 's/^.*\] /    /' || echo "    (none)"
fi

echo
echo "=== 12. Did power management come alive (proof GSP really runs) ==="
sleep 5
nvidia-smi --query-gpu=pstate,power.draw,clocks.mem,clocks.sm,temperature.gpu --format=csv 2>/dev/null | sed 's/^/  /'
echo "  (with GSP running expect P8 and ~20 W instead of P0 and ~50 W)"

cat <<EOF

=== WHAT NEXT ===
  If the card now reads EDID (EDID != 0B on the connected port):
      plug a monitor into the card and: sudo ./run.sh --restart-ui
  If GSP still dies:
      sudo CAP_SPEED=2 $0 --retrain
      then CAP_SPEED=1 (Gen1 - large bandwidth loss, but it tests the mechanism)
  Back to the known-good configuration:
      sudo $0 --off  &&  sudo reboot  &&  sudo ./3-setup.sh
  If it hangs: the kernel log is in $KLOG (synced every 0.2 s). pstore has NO backend
               (measured: ramoops has no reservation), so do not expect a post-reset dump.
EOF
