#!/usr/bin/env bash
# 10-teardown.sh - let go of the card so the cable can be pulled while the
# machine keeps running.
#
# UNTESTED. Nothing in this file has been run on this machine. On this platform
# losing the card the wrong way is an instant reset with no log, so read the
# ordering below before using it.
#
# WHY THIS IS NOT ONE COMMAND
#
# The compositor holds the card open. Measured with primary = Radeon, i.e. the
# cheapest case:
#
#     nvidia_drm refcnt = 14
#     gnome-shell fds   = 4x dri/card2 (Radeon), 1x dri/card3 (RTX), 2x renderD130
#
# mutter opens every DRM device it finds, so it holds the eGPU even when it is
# not compositing on it. While that fd is open nvidia_drm cannot be unloaded,
# and pulling the cable is a surprise removal of a device whose driver does not
# even know it is external: RmCheckForExternalGpu() does not recognise TB5
# bridges.
#
# The only supported way to make mutter let go is the mutter-device-ignore udev
# tag, and udev tags are read when mutter STARTS. There is no live mechanism.
# Hence two phases with a session restart between them:
#
#     --release   drop the GPU-selection layers, tag the card as ignored,
#                 restart the session. After this mutter no longer holds it.
#                 THE CABLE IS NOT SAFE TO PULL YET - the driver is still
#                 loaded and still bound to the device.
#
#     --unload    unload the nvidia stack, which unbinds the driver, and check
#                 that nothing is left holding the card. AFTER THIS the cable
#                 can come out.
#
# WHAT --unload DOES NOT DO - three different meanings of "driver"
#
#     installed   the nvidia-driver-610 packages on disk   NEVER touched
#     loaded      the modules in the kernel                 removed
#     bound       driver attached to the PCI device         released
#
# So this is "unload from memory", not "uninstall". The next run.sh loads it
# all again.
#
# BARs AND THE ROOT-PORT WINDOW ARE NOT UNDONE HERE
#
# BAR assignment is a property of the device in the kernel's PCI tree, not of
# whichever driver is bound, so it survives --unload untouched (Region 1 stays
# 256M @ 0x4010000000). What removes it is PULLING THE CABLE: the device leaves
# the PCI tree and takes its resources with it. No script does that.
#
# egpu_rp_window is deliberately LEFT LOADED. Its own exit path says why:
#
#     pci_warn(rp, "egpu_rp_window: rmmod does NOT restore the old window.\n");
#     pci_warn(rp, "egpu_rp_window: returning to the firmware state = reboot.\n");
#
# Removing it restores nothing and only throws away the record of what state
# the root port is in. The moved window lives until reboot either way.
#
# ⚠ PLUGGING THE CARD BACK IN, SAME BOOT - READ THIS FIRST
#
# 04-window.sh refuses to run when its module is already loaded:
#
#     [[ -d /sys/module/egpu_rp_window ]] && { echo "  ERROR: module already loaded - reboot"; exit 1; }
#
# So after a replug there are two outcomes: either the kernel assigns BARs by
# itself inside the window that is still in place - and run.sh skips the
# window setup and works - or it does not, and run.sh stops asking for a
# reboot. Which one
# you get is UNTESTED. Plan on needing a reboot before using the card again.
#
# WHAT THIS ACTUALLY BUYS YOU
#
# Not your GUI windows - --release restarts the session, so those are lost
# either way. What survives is everything OUTSIDE the graphical session: tmux,
# builds, downloads. If you have nothing like that running, powering the
# machine off is simpler, faster overall and actually tested.
#
# USAGE
#
#   sudo ./scripts/10-teardown.sh --release    # phase 1, restarts the session
#   sudo ./scripts/10-teardown.sh --unload     # phase 2, after logging back in
#   sudo ./scripts/10-teardown.sh --off        # undo --release without unloading:
#                                      # the card comes back at the next
#                                      # session restart
#   ./scripts/10-teardown.sh --status          # who still holds the card
#
# Also reachable as: sudo ./run.sh --release | --unload

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$DIR/$(basename "${BASH_SOURCE[0]}")"
# shellcheck source=lib/egpu-lib.sh
source "$DIR/../lib/egpu-lib.sh"          # reporters, egpu_nv_card, EGPU_NV_MODULES

IGNORE_RULE=/run/udev/rules.d/63-egpu-ignore.rules   # /run: dies on reboot

MODE=status
for a in "$@"; do case $a in
    --release) MODE=release ;;
    --unload)  MODE=unload ;;
    --off)     MODE=off ;;
    --status)  MODE=status ;;
    -h|--help) egpu_usage "$0"; exit 0 ;;
    *) echo "Unknown argument: $a" >&2; exit 1 ;;
esac; done


# Who has the card's DRM nodes open. This is the question that decides whether
# unloading can work at all, so it is worth answering by name and not just as a
# refcount. Needs root to see other processes' fds.
#
# NO PIPE INTO grep -q HERE, DELIBERATELY. With "set -o pipefail" a "ls | grep
# -q" pipeline returns 141: grep exits at the first match, ls gets EPIPE, and
# pipefail promotes that to the pipeline's status - so a MATCH reads as a
# failure. It bites exactly the processes that matter, because the ones holding
# the card tend to have many fds and lose the race reliably: gnome-shell was
# silently missing from this list until this was rewritten. The same trap is
# documented at the preflight in 04-window.sh and at section 4 of
# 08-check-outputs.sh - three times in one package. readlink on each fd has no
# pipeline at all.
holders() {
    local card=$1 p n fd t rnode="" found
    [[ -n $card ]] || return 0
    # The render node belonging to the same PCI device as the card.
    for n in /sys/class/drm/renderD*; do
        [[ -e $n/device ]] || continue
        [[ $(readlink -f "$n/device") == $(readlink -f "/sys/class/drm/$card/device") ]] \
            && rnode=$(basename "$n")
    done
    for p in /proc/[0-9]*; do
        [[ -r $p/comm ]] || continue
        found=0
        for fd in "$p"/fd/*; do
            t=$(readlink "$fd" 2>/dev/null) || continue
            case $t in
                "/dev/dri/$card")             found=1; break ;;
                "/dev/dri/${rnode:-__none__}") found=1; break ;;
            esac
        done
        (( found )) && printf '      %-8s %s\n' "${p#/proc/}" "$(cat "$p/comm" 2>/dev/null)"
    done
}

show_state() {
    hdr "Modules"
    local m
    for m in "${EGPU_NV_MODULES[@]}" egpu_rp_window; do
        if [[ -d /sys/module/$m ]]; then
            printf "      %-16s loaded   refcnt=%s\n" "$m" "$(cat /sys/module/$m/refcnt 2>/dev/null)"
        else
            printf "      %-16s not loaded\n" "$m"
        fi
    done

    hdr "The card"
    if egpu_nv_card; then
        ok "$EGPU_CARD  $EGPU_CARD_BDF"
        lspci -k -s "${EGPU_CARD_BDF#*:}" 2>/dev/null | sed 's/^/      /'
    else
        info "no DRM card owned by the nvidia driver"
        info "(driver unloaded, or the card is gone)"
    fi

    hdr "The ignore tag"
    if [[ -f $IGNORE_RULE ]]; then
        ok "installed: $IGNORE_RULE  (this boot only)"
        info "mutter leaves the card alone in sessions started from now on"
    else
        info "not installed - mutter will open the card"
    fi

    hdr "Who is holding the card"
    if [[ -n $EGPU_CARD ]]; then
        local h; h=$(holders "$EGPU_CARD")
        if [[ -n $h ]]; then
            echo "$h"
            [[ $EUID -eq 0 ]] || info "(run with sudo to see processes other than your own)"
        else
            ok "nothing holds it"
        fi
    else
        info "(no card to check)"
    fi
}

if [[ $MODE == status ]]; then show_state; exit 0; fi

egpu_require_root "--$MODE"

# ---------- OFF: undo --release, keep the driver ----------
if [[ $MODE == off ]]; then
    hdr "Removing the ignore tag"
    if [[ -f $IGNORE_RULE ]]; then
        rm -f "$IGNORE_RULE" && ok "removed $IGNORE_RULE"
        udevadm control --reload 2>/dev/null && ok "udev rules reloaded"
        # Same reason as in 09-primary-gpu.sh --off: a reload only affects future
        # events, so without a trigger the tag stays on the live device and the
        # next session still ignores the card.
        udevadm trigger --subsystem-match=drm 2>/dev/null && ok "drm devices retriggered"
    else
        info "was not installed"
    fi
    echo
    info "mutter picks the card up again at the next session restart:"
    info "    sudo $EGPU_ROOT/run.sh --restart-ui"
    exit 0
fi

# ---------- UNLOAD: phase 2 ----------
if [[ $MODE == unload ]]; then
    hdr "Phase 2 - unloading the driver"
    egpu_nv_card || warn "no nvidia-owned DRM card - the driver may already be gone"

    # Preflight. Unloading with the compositor still holding the card cannot
    # work, and saying so up front is more useful than a modprobe error.
    if [[ -n $EGPU_CARD ]]; then
        held=$(holders "$EGPU_CARD")
        if [[ -n $held ]]; then
            bad "something still holds the card:"
            echo "$held"
            echo
            info "Run phase 1 first, which makes mutter let go:"
            info "    sudo $SELF --release"
            info "If you already did, the ignore tag only takes effect in a"
            info "session started AFTER it was installed - restart the session."
            exit 1
        fi
        ok "nothing holds the card"
    fi

    systemctl stop nvidia-persistenced 2>/dev/null && ok "stopped nvidia-persistenced" || true
    for m in "${EGPU_NV_MODULES[@]}"; do
        [[ -d /sys/module/$m ]] || { info "$m already gone"; continue; }
        if modprobe -r "$m" 2>/dev/null; then
            ok "$m unloaded"
        else
            bad "$m NOT unloaded (refcnt=$(cat /sys/module/$m/refcnt 2>/dev/null))"
            info "Something reopened the card. Check: sudo $SELF --status"
            exit 1
        fi
    done

    hdr "Verification"
    left=$(compgen -G "/sys/module/nvidia*" 2>/dev/null | sed 's|.*/||' | tr '\n' ' ')
    if [[ -n $left ]]; then
        bad "still loaded: $left"; exit 1
    fi
    ok "no nvidia modules loaded"
    # Command substitution, not a pipe: see the note on holders() above.
    if [[ -n $EGPU_CARD_BDF && $(lspci -k -s "${EGPU_CARD_BDF#*:}" 2>/dev/null) == *"Kernel driver in use"* ]]; then
        warn "a driver is still bound to $EGPU_CARD_BDF"
        lspci -k -s "${EGPU_CARD_BDF#*:}" 2>/dev/null | sed 's/^/      /'
    else
        ok "no driver bound to the card"
    fi

    hdr "THE CABLE CAN COME OUT NOW"
    echo "  What is still in place, on purpose:"
    echo "    - the nvidia-driver-610 packages: untouched. This was an unload,"
    echo "      not an uninstall. The next run.sh loads them again."
    echo "    - egpu_rp_window: still loaded. Removing it restores nothing"
    echo "      (its own exit path says so) and the moved root-port window"
    echo "      lives until reboot regardless."
    echo "    - the card's BARs: still assigned. They go away when the device"
    echo "      leaves the PCI tree, i.e. when you pull the cable."
    echo
    echo "  Before you plan on using the card again this boot: 04-window.sh"
    echo "  refuses to run while egpu_rp_window is loaded, so a replug may"
    echo "  need a reboot. UNTESTED - see the header of this script."
    exit 0
fi

# ---------- RELEASE: phase 1 ----------
hdr "Phase 1 - making the compositor let go"
if ! egpu_nv_card; then
    bad "no DRM card owned by the nvidia driver"
    info "Nothing to release. If the driver is already unloaded you are done;"
    info "if the card is gone, use: sudo $EGPU_ROOT/run.sh --reset"
    exit 1
fi
ok "$EGPU_CARD  $EGPU_CARD_BDF  vendor=$EGPU_CARD_VENDOR device=$EGPU_CARD_DEVICE"
[[ -n $EGPU_CARD_VENDOR && -n $EGPU_CARD_DEVICE ]] || { bad "could not read PCI IDs"; exit 1; }

hdr "Dropping the primary-GPU override"
# Pointless once the card is going away, and leaving it in place would point a
# fresh session at a device that is about to vanish.
if [[ -x $EGPU_SCRIPTS/09-primary-gpu.sh ]]; then
    "$EGPU_SCRIPTS/09-primary-gpu.sh" --off | sed 's/^/  /' || warn "could not clear the primary-GPU override"
else
    warn "missing $EGPU_SCRIPTS/09-primary-gpu.sh"
fi

hdr "Tagging the card as ignored"
mkdir -p "$(dirname "$IGNORE_RULE")" || { bad "cannot create $(dirname "$IGNORE_RULE")"; exit 1; }
cat > "$IGNORE_RULE" <<EOF
# Make mutter ignore the external GPU entirely, so it stops holding its DRM
# node and the driver can be unloaded. Written by $SELF
#
# In /run deliberately: this is a teardown state, not a configuration. /run is
# tmpfs, so a reboot removes it and the card is usable again without any undo.
#
# Matching is on PCI vendor:device, not /dev/dri/cardN - card numbering moves
# on this machine (card0 is a USB display, the eGPU is hot-plugged).
SUBSYSTEM=="drm", ENV{DEVTYPE}=="drm_minor", ENV{DEVNAME}=="/dev/dri/card[0-9]", SUBSYSTEMS=="pci", ATTRS{vendor}=="$EGPU_CARD_VENDOR", ATTRS{device}=="$EGPU_CARD_DEVICE", TAG+="mutter-device-ignore"
EOF
ok "wrote $IGNORE_RULE"
udevadm control --reload 2>/dev/null && ok "udev rules reloaded"
udevadm trigger --subsystem-match=drm 2>/dev/null && ok "drm devices retriggered"
if [[ $(udevadm info "/sys/class/drm/$EGPU_CARD" 2>/dev/null) == *mutter-device-ignore* ]]; then
    ok "the card now carries mutter-device-ignore"
else
    warn "the tag is not visible on $EGPU_CARD"
    info "mutter reads tags when it starts, so this may still be fine."
fi

hdr "RESTARTING THE SESSION"
warn "every open window will be lost - that is unavoidable here"
info "udev tags are read when mutter starts; there is no live way to make it"
info "release a device. Anything outside the graphical session survives."
if [[ -n $EGPU_CARD ]]; then
    for x in /sys/class/drm/$EGPU_CARD-*; do
        [[ -e $x/status ]] || continue
        [[ $(cat "$x/status") == connected ]] || continue
        warn "the monitor on ${x##*/$EGPU_CARD-} will go dark - mutter is about to ignore this card"
    done
fi
DM=$(systemctl show display-manager.service -p Id --value 2>/dev/null); DM=${DM:-gdm.service}
printf "      %-12s %s\n" "unit" "$DM"
warn "restarting in 5 s - press Ctrl+C to cancel"
sleep 5
# MUST be detached: restarting the display manager kills the session this
# script runs in. A transient unit outlives it. Same approach as run.sh.
if systemd-run --collect --unit=egpu-teardown-restart \
        systemctl restart "$DM" >/dev/null 2>&1; then
    ok "restart handed off to systemd"
    echo
    echo "  AFTER YOU LOG BACK IN, phase 2:"
    echo "      sudo $SELF --unload"
    echo "  Only then is the cable safe to pull."
    echo
    echo "  Changed your mind? sudo $SELF --off  then restart the session again."
    exit 0
fi
bad "could not hand off the restart"
info "do it by hand: sudo systemctl restart $DM"
exit 1
