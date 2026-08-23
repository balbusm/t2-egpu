#!/usr/bin/env bash
# 09-primary-gpu.sh - make the eGPU the compositor's PRIMARY GPU, so the monitor
# on the card is driven without crossing the Thunderbolt tunnel at all.
#
# READ THIS BEFORE RUNNING IT. This is the one script in the package that can
# leave you without a desktop. Recovery is at the bottom.
#
# WHAT PROBLEM IT SOLVES
#
# From mutter's own documentation:
#
#     Mutter composites all buffer content on the primary GPU, regardless of
#     display connections. When displays attach to secondary GPUs, content must
#     be copied from primary to secondary.
#
# boot_vga=1 sits on the Radeon, so the Radeon is primary and HDMI-A-4 - which
# is physically on the RTX - is a SECONDARY GPU OUTPUT. Every displayed frame
# therefore makes a round trip through the tunnel. Measured, same 1600x900
# render, same rendering GPU, only the screen changed:
#
#     screen 0  eDP-1   (internal, on the Radeon)   181.1 fps   score 30249
#     screen 1  HDMI-4  (external, on the RTX)      137.9 fps   score 23036
#
#     rxpci (into the card):  265 MB/s internal  ->  482 MB/s external
#
# ~24% lost, and inbound PCIe traffic per frame up 2.4x - the composited image
# coming back to the card to be scanned out.
#
# RESULT, measured after switching (2026-08-22)
#
#     external monitor   137.9  ->  230 fps    (+67%)
#     internal panel     181.1  ->  ~150 fps   (-17%)
#
# So it works, and it is the predicted trade rather than a free win: the
# external monitor stops crossing the tunnel altogether, and the internal panel
# starts carrying the whole composited desktop instead of just window buffers.
# Switch this on if you mostly work on the external monitor; leave it off if
# you mostly use the built-in panel.
#
# Also confirmed: with the card as primary, applications land on it WITHOUT any
# offload variables. GravityMark reported "Vendor: NVIDIA Corporation" with no
# environment set at all, and gnome-shell itself sits at ~575 MiB of the card's
# memory. That is why the old environment-variable route (10-default-gpu.sh) was
# deleted on 2026-08-22 - it had nothing left to add.
#
# WHAT THIS CHANGES, AND WHAT IT COSTS
#
# With the eGPU as primary, the external monitor is composited and scanned out
# on the SAME card: zero tunnel crossings for display. Applications also render
# there natively, with no environment variables involved.
#
# But the cost MOVES, it does not vanish: the internal panel (eDP-1, on the
# Radeon) becomes the secondary-GPU output and starts paying the copy instead.
#
#     This is a win ONLY if you mostly work on the external monitor.
#     If you mostly use the built-in panel, it is a straight loss.
#
# WHY NOT "JUST DISABLE THE RADEON"
#
# Because eDP-1 exists ONLY on the Radeon. i915 exposes DP-1..3 and HDMI-A-1..3
# and no eDP connector at all, so there is no iGPU path to the built-in panel
# to fall back on. Disabling the Radeon would very likely mean no internal
# display. The udev tag below is the supported mechanism and needs none of that.
#
# WHY THIS IS SAFE AT BOOT
#
# The rule matches on the card's PCI IDs, and the card does not exist at boot
# on this machine - it is always hot-plugged. So at login the rule matches
# nothing, mutter picks the Radeon as always, and the desktop comes up normally.
# The rule only takes effect in a session started while the card is present.
#
# PERSISTENCE - THIS BOOT ONLY BY DEFAULT
#
# udev reads rules from three places, and one of them is volatile:
#
#     /etc/udev/rules.d       persistent, survives reboot
#     /run/udev/rules.d       tmpfs - GONE after reboot        <- default here
#     /usr/lib/udev/rules.d   distribution-owned
#
# Default is /run, to match the rest of this package: the card's whole BAR
# allocation lives in RAM, and a reboot puts you back to stock behaviour without
# having to undo anything.
#
# Without this, "safe at boot" would be technically true but practically
# misleading: the file would still be on disk, so the next run.sh + session
# restart would silently re-enable the override without you asking for it.
#
# --persist writes to /etc instead, if you decide you always want it.
# --off removes BOTH locations - a forgotten /etc copy would otherwise keep
# the override alive while --status of the /run copy showed nothing.
#
# Matching is on PCI vendor:device, NOT on /dev/dri/cardN. The card number is
# not stable here: card0 is a USB display (appletbdrm) and the eGPU is
# hot-plugged, so numbering moves.
#
# RISKS - none of these are hypothetical
#
#   - the NVIDIA proprietary driver becomes the compositing GPU across a
#     Thunderbolt tunnel. It works here, but that makes the card a single
#     point of failure for the whole desktop rather than for applications
#   - the blast radius grows. Today a card that falls off the bus kills
#     applications; as primary it kills the whole desktop. On this platform
#     "fallen off the bus" is documented as an instant reset with no log
#   - all-ways-egpu reports laggy desktops with GNOME Wayland FRACTIONAL
#     SCALING after a display-manager restart. This machine uses fractional
#     scaling (2880x1800 panel reported as a 3456x2160 logical desktop), so
#     that warning applies here - it did not bite in practice, but one session
#     is not a sample
#
# USAGE
#
#   sudo ./09-primary-gpu.sh --on             # this boot only (rule in /run)
#   sudo ./09-primary-gpu.sh --on --persist   # survives reboot (rule in /etc)
#   sudo ./09-primary-gpu.sh --off            # remove from BOTH locations
#   ./09-primary-gpu.sh --status              # what is installed and whether it
#                                            # survives a reboot
#
# Neither --on nor --off takes effect until the session restarts. Nothing
# happens to the running desktop at the moment you run this.
#
# RECOVERY, if the desktop does not come back
#
#   1. Ctrl+Alt+F3            switch to a text console and log in
#   2. sudo rm -f /run/udev/rules.d/62-egpu-primary-gpu.rules \
#                 /etc/udev/rules.d/62-egpu-primary-gpu.rules
#   3. sudo udevadm control --reload
#   4. sudo systemctl restart gdm
#
# Or simply REBOOT, which is the better answer in a panic: the card is absent
# at boot so the rule cannot match, and with the default (/run) the rule is
# gone entirely.

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/egpu-lib.sh
source "$DIR/lib/egpu-lib.sh"          # reporters, egpu_nv_card, egpu_usage

RULE_NAME=62-egpu-primary-gpu.rules
RULE_RUN=/run/udev/rules.d/$RULE_NAME     # volatile - default
RULE_ETC=/etc/udev/rules.d/$RULE_NAME     # persistent - --persist

MODE=status; PERSIST=0
for a in "$@"; do case $a in
    --on)  MODE=on ;;
    --off) MODE=off ;;
    --persist) PERSIST=1 ;;
    --status) MODE=status ;;
    -h|--help) egpu_usage "$0"; exit 0 ;;
    *) echo "Unknown argument: $a" >&2; exit 1 ;;
esac; done


# ---------- STATUS ----------
if [[ $MODE == status ]]; then
    hdr "The rule"
    found=0
    if [[ -f $RULE_RUN ]]; then
        found=1
        ok "installed: $RULE_RUN"
        info "THIS BOOT ONLY - /run is tmpfs, a reboot removes it"
        grep -v '^#' "$RULE_RUN" | grep -v '^$' | sed 's/^/      /'
    fi
    if [[ -f $RULE_ETC ]]; then
        found=1
        ok "installed: $RULE_ETC"
        warn "PERSISTENT - survives reboot, so run.sh + a session restart will"
        warn "re-enable this even without --primary-gpu"
        grep -v '^#' "$RULE_ETC" | grep -v '^$' | sed 's/^/      /'
    fi
    (( found )) || info "not installed - the Radeon stays primary"

    hdr "GPUs and who owns the internal panel"
    for c in /sys/class/drm/card[0-9]*; do
        b=$(basename "$c"); [[ $b == *-* ]] && continue
        drv=$(basename "$(readlink -f "$c/device/driver")" 2>/dev/null)
        bv=$(cat "$c/device/boot_vga" 2>/dev/null)
        conns=$(for x in "$c"-*; do [[ -e $x/status ]] && printf '%s ' "${x##*/$b-}"; done)
        printf "      %-7s %-11s boot_vga=%-2s %s\n" "$b" "${drv:-?}" "${bv:-n/a}" "$conns"
    done

    hdr "What mutter actually chose"
    # mutter logs the primary GPU when it initialises. Only readable for the
    # user's own session; if empty, that is not a failure, just no log retained.
    p=$(journalctl --user -b 2>/dev/null | grep -oiE 'primary (gpu|device)[^,]*' | tail -3)
    if [[ -n $p ]]; then echo "$p" | sed 's/^/      /'
    else info "(nothing in this boot's session log - restart the session to see it)"; fi
    exit 0
fi

egpu_require_root "${*:-}"

# ---------- OFF ----------
if [[ $MODE == off ]]; then
    hdr "Removing the primary-GPU override"
    # BOTH locations, always. Removing only the one we would have written leaves
    # a forgotten copy in the other silently keeping the override alive.
    gone=0
    for f in "$RULE_RUN" "$RULE_ETC"; do
        [[ -f $f ]] || continue
        rm -f "$f" && { ok "removed $f"; gone=1; }
    done
    (( gone )) || info "no rule file in either location"

    # Everything below runs WHETHER OR NOT a file was removed, and that is the
    # point. Deleting the rule only affects FUTURE device events; a tag already
    # applied to the live device stays in udev's database. So the state "file
    # gone, tag still on the card" is reachable - and in it, a session restart
    # still picks the card as primary while --off reports success. Gating the
    # cleanup on "did we delete something" would make this script useless in
    # exactly the case where it is needed most.
    stale() {
        local c out=""
        for c in /sys/class/drm/card[0-9]*; do
            [[ $(basename "$c") == *-* ]] && continue
            [[ $(udevadm info "$c" 2>/dev/null) == *mutter-device-preferred-primary* ]] \
                && out="$out $(basename "$c")"
        done
        printf '%s' "$out"
    }
    udevadm control --reload 2>/dev/null && ok "udev rules reloaded"
    if [[ -n $(stale) ]]; then
        udevadm trigger --subsystem-match=drm 2>/dev/null && ok "drm devices retriggered"
        left=$(stale)
        if [[ -n $left ]]; then
            warn "the tag is STILL on:$left"
            info "udev keeps it until the device is re-added. The rule is gone,"
            info "so a reboot clears it for certain and it cannot come back."
        else
            ok "stale tag cleared - no card carries it any more"
        fi
    else
        ok "no card carries mutter-device-preferred-primary"
    fi
    echo
    info "The running session is unchanged - mutter reads udev tags only when"
    info "it starts. The Radeon becomes primary again at the next restart:"
    info "    sudo $DIR/run.sh --restart-ui"
    info ""
    info "NOT 'systemctl isolate graphical.target': when the system is already"
    info "IN graphical.target that is a no-op and nothing restarts. Use the"
    info "line above, which hands the restart to a transient systemd unit so"
    info "it survives killing the session it was started from."
    exit 0
fi

# ---------- ON ----------
hdr "Finding the eGPU"
if ! egpu_nv_card; then
    bad "no DRM card owned by the nvidia driver"
    info "The card has to be up before its PCI IDs can be read:"
    info "    sudo $DIR/run.sh --restart-ui"
    exit 1
fi
ok "$EGPU_CARD  $EGPU_CARD_BDF  vendor=$EGPU_CARD_VENDOR device=$EGPU_CARD_DEVICE"
[[ -n $EGPU_CARD_VENDOR && -n $EGPU_CARD_DEVICE ]] || { bad "could not read PCI IDs"; exit 1; }

# Sanity check worth having: if the card has no connected output, making it
# primary buys nothing and costs the internal panel a copy path.
live=0
for x in /sys/class/drm/$EGPU_CARD-*; do
    [[ -e $x/status ]] || continue
    [[ $(cat "$x/status") == connected ]] && live=1
done
if (( ! live )); then
    warn "no monitor is connected to the card"
    info "As primary it would composite for outputs on OTHER GPUs, which is"
    info "the expensive direction. This is very likely not what you want."
fi

hdr "Installing the rule"
if (( PERSIST )); then
    RULE=$RULE_ETC
    warn "--persist: this will SURVIVE REBOOT"
else
    RULE=$RULE_RUN
    ok "this boot only - /run is tmpfs, a reboot removes it"
fi
mkdir -p "$(dirname "$RULE")" || { bad "cannot create $(dirname "$RULE")"; exit 1; }
# A copy in the other location would keep overriding after --off of this one,
# or silently outlive a reboot the user thought was a clean slate.
OTHER=$([[ $RULE == "$RULE_RUN" ]] && echo "$RULE_ETC" || echo "$RULE_RUN")
if [[ -f $OTHER ]]; then
    warn "a rule also exists at $OTHER"
    info "Remove both first if that is not what you want: sudo $0 --off"
fi
cat > "$RULE" <<EOF
# Make the external GPU mutter's primary device, so the monitor attached to it
# is composited and scanned out on the same card - no Thunderbolt round trip.
# Written by $DIR/09-primary-gpu.sh
#
# Matching is on PCI vendor:device, not /dev/dri/cardN: card numbering moves on
# this machine (card0 is a USB display, the eGPU is hot-plugged).
#
# This matches nothing at boot, because the card is not present until run.sh
# has set up the tunnel. A normal boot is therefore unaffected.
SUBSYSTEM=="drm", ENV{DEVTYPE}=="drm_minor", ENV{DEVNAME}=="/dev/dri/card[0-9]", SUBSYSTEMS=="pci", ATTRS{vendor}=="$EGPU_CARD_VENDOR", ATTRS{device}=="$EGPU_CARD_DEVICE", TAG+="mutter-device-preferred-primary"
EOF
ok "wrote $RULE"
udevadm control --reload 2>/dev/null && ok "udev rules reloaded"
udevadm trigger --subsystem-match=drm 2>/dev/null && ok "drm devices retriggered"

hdr "Did the tag land"
if [[ $(udevadm info "/sys/class/drm/$EGPU_CARD" 2>/dev/null) == *mutter-device-preferred-primary* ]]; then
    ok "the card now carries mutter-device-preferred-primary"
else
    warn "the tag is not visible on $EGPU_CARD"
    info "The rule may still be correct - mutter reads tags when it starts."
    info "Check by hand: udevadm info /sys/class/drm/$EGPU_CARD | grep TAGS"
fi

hdr "NEXT STEP - AND THE RISK"
echo "  Nothing has changed in the running desktop. It takes effect on restart:"
echo
echo "      sudo $DIR/run.sh --restart-ui"
echo
echo "  If the desktop does NOT come back:"
echo "      1. Ctrl+Alt+F3, log in"
echo "      2. sudo rm -f $RULE_RUN $RULE_ETC"
echo "      3. sudo udevadm control --reload"
echo "      4. sudo systemctl restart gdm"
echo "  Or just reboot - simpler, and with the default (/run) the rule is gone."
echo
echo "  Applications then render on the card natively - no environment"
echo "  variables needed."
echo
echo "  Revert:  sudo $0 --off"
