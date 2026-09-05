# External GPU bring-up over Thunderbolt / USB4

A small, **portable** set of scripts that brings an external GPU up behind a
Thunderbolt or USB4 tunnel on Linux.

Developed on a MacBook Pro 15,1 (T2, 2018) with an AOOSTAR AG03 enclosure and
an RTX 4080, but nothing is tied to that machine, that enclosure, that
Thunderbolt port, or this directory. Addresses are discovered, not written
down.


---

## Start

```bash
cd <package-directory>

sudo ./scripts/01-check.sh          # what is in place, what is missing
sudo ./scripts/01-check.sh --fix    # write the missing modprobe.d file
sudo ./run.sh              # bring the card up, make it primary, restart session
```

Note that the bare `run.sh` is the *most* consequential form, not the safest:
with no arguments it applies `--restart-ui` and `--primary-gpu`. It prints that
and waits 5 s. For a plain bring-up that touches neither:

```bash
sudo ./run.sh --plain
```

Any flag suppresses the two defaults, but `--plain` is the one that asks for
nothing else.

To let go of the card again without rebooting:

```bash
sudo ./run.sh --release    # compositor lets go, session restarts
                           # THE CABLE IS NOT SAFE TO PULL YET
sudo ./run.sh --unload     # after logging back in - now it is
```

On a new machine, or after reinstalling, **always start with `01-check.sh`**.
Missing files under `/etc` do not show up as a script error — they show up as
a machine **reset**. That is why `run.sh` runs the check as a gate and
aborts before touching hardware.

If the card is not found, or several are:

```bash
./scripts/02-devices.sh     # candidates and the topology behind each
./scripts/02-devices.sh --all   # every display controller, internal ones included
sudo GPU=0000:07:00.0 ./run.sh
```

The whole allocation lives in memory. It is lost on reboot and when the
enclosure loses power: power-cycle the enclosure, then `sudo ./run.sh`.

---

## Layout

```
run.sh              the entry point - the only thing in the root you run
scripts/            the numbered steps, in execution order
lib/egpu-lib.sh     topology discovery and shared plumbing. Sourced, not run
module/             source of the window module plus its Makefile
logs/               run logs, one file per bring-up. Newest 10 kept
build/              module build output, regenerated
```

Only `run.sh` sits in the root, because it is the only script you invoke in a
normal bring-up. Everything under `scripts/` is either something `run.sh` calls
for you or a diagnostic you reach for when it goes wrong.

Paths are derived, not assumed: `lib/egpu-lib.sh` works out the package root
from its own location and exports `EGPU_ROOT` / `EGPU_SCRIPTS` / `EGPU_LOGS` /
`EGPU_MODULE`. A script only has to find the library. The package still works
from any path and under any directory name.

## Files, in execution order

| file | role |
|---|---|
| `run.sh` | **entry point.** Check gate → window and BARs → link cap → GSP → driver stack → report. With NO arguments it also applies `--restart-ui` and `--primary-gpu`, so the bare command restarts your session and makes the card the compositor's primary GPU — it says so and waits 5 s first. Any flag suppresses both. Teardown lives here too: `--reset`, `--off`, `--release`, `--unload` - all four are handled before topology discovery, so they work with the card already gone |
| `scripts/01-check.sh` | prerequisites: tools, kernel, headers, driver, **effective** modprobe configuration, udev, cmdline, hardware, package integrity. `--fix` writes the canonical modprobe.d file, `--quiet` returns only an exit code |
| `scripts/02-devices.sh` | list external GPU candidates and their topology. Read-only, no root needed |
| `scripts/03-build-module.sh` | root-port window and BARs: rebuild the window module for the running kernel → `04` → `05`. `run.sh` calls it with `--configure-only`, so nothing is loaded; `--no-load` stops even earlier |
| `scripts/04-window.sh` | move the prefetchable window above 4 GB, remove and rescan the tunnel subtree |
| `scripts/05-load-driver.sh` | write the `modprobe.d`/udev blocks, prove they are effective, confirm BAR1, pin runtime PM — then load `nvidia` and check `nvidia-smi`. `--configure-only` does everything except the load, which is what `run.sh` wants: the cap has to come first |
| `scripts/06-bar-fallback.sh` | **fallback** — `05` calls it only if BAR1 came out unassigned |
| `scripts/07-link-cap-gsp.sh` | the cautious way in, for a risky experiment. Detaches into a transient systemd unit and drops to `multi-user.target`, so no compositor is holding the card and a hang cannot take a session with unsaved work — then calls `run.sh --plain`. It does **not** implement the bring-up; there is one implementation of that. `--off` hands off to `run.sh --off` |
| `scripts/08-check-outputs.sh` | card outputs and whether GSP really started. Read-only |
| `scripts/09-primary-gpu.sh` | **opt-in, verified working.** Make the card the compositor's *primary* GPU via a udev tag, so the monitor on it needs no tunnel round trip. Measured: external **137.9 → 230 fps**, internal **181.1 → ~150** — the cost moves, it does not vanish. Applications then land on the card with no offload variables at all. `--on` is this-boot-only, `--on --persist` survives reboot, `--off` clears both. `run.sh` runs it as *its own* step 10, only with `--primary-gpu` — that number is run.sh's internal step, not this file's position |
| `scripts/10-teardown.sh` | **untested.** Let go of the card so the cable can be pulled with the machine running. `--release` (drop GPU selection, tag the card `mutter-device-ignore`, restart the session — the cable is *not* safe yet), then `--unload` (unload the stack, verify nothing holds it — now it is). `--off` undoes `--release`, `--status` shows who holds the card. Reachable as `run.sh --release` / `--unload` |
| `lib/egpu-lib.sh` | shared topology discovery **and shared plumbing** — reporters, logging with a guaranteed flush, the GSP kill switch, the KMS load sequence, the mutter udev-rule writer, link-cap and ReBAR register access. Sourced, not run |
| `module/` | source of the window module plus its Makefile. Rebuilt on every run |
| `logs/` | run logs, the last 10 per kind (`EGPU_LOG_KEEP` changes it, `0` keeps everything) |

`run.sh` is what you invoke; the rest live in `scripts/`. The numbers are the
position in the pipeline:
`01`–`06` execute in order, `07`–`08` are variants and diagnostics, `09`–`10`
decide what *uses* the card once it is up — who composites, and how to let go
of it again. The numbers are zero-padded so the shell sorts them in execution
order; `ls` and the table above agree.

---

## Three ordering constraints

The structure of `run.sh` follows from these, and they must not be mixed up:

1. **the cap comes AFTER step 5** — `remove`+`rescan` destroys and recreates
   the device, so a cap applied earlier is lost
2. **the cap comes BEFORE `nvidia.ko` binds** — otherwise the driver retrains
   the link to Gen4 inside the GSP handshake window and the card falls off the
   bus (instant reset, no kernel output)
3. **GSP only together with the cap** — never GSP without it

That is why `run.sh` inserts `NVreg_EnableGpuFirmware=0` as a safety net for
the duration of the window setup and removes it only once the cap is in place.
Nothing in that phase loads the driver deliberately — `05-load-driver` is called
with `--configure-only` — but `04-window` issues a PCI `remove`+`rescan`, and a
rescan generates add events. An autoload that slipped past the blocks must not
come up with GSP on.

It is also why the driver is loaded exactly **once**, in step 7. It used to be
loaded during the window setup and unloaded again in step 4 to make room for the
cap: a whole cycle for nothing, and a bind with no cap in place.

---

## What not to remove

The blocks in `/etc/modprobe.d` (`blacklist nvidia*`, `install nvidia
/bin/false`) look like leftovers but they enforce constraint 2. Without them
udev, or any by-name loader, can bind the driver before the cap.

`blacklist` and `install` are not interchangeable: `blacklist` only closes the
modalias path, `install /bin/false` also closes loading by name and as a
dependency. Both are needed.

Modules **must** be loaded one at a time (`nvidia` → `nvidia_uvm` →
`nvidia_modeset` → `nvidia_drm modeset=1`), because `--ignore-install` does not
apply to dependencies — a single `modprobe nvidia_drm` would hit `/bin/false`.

One trap worth watching: **no file in `modprobe.d` may set `options nvidia_drm
modeset=0` alphabetically AFTER the one that sets `modeset=1`** — the kernel
takes the last repeated parameter. `01-check.sh` therefore tests the effect of
the concatenation, not file names.

---

## Portability

- Scripts are self-locating. Each one finds `lib/egpu-lib.sh` relative to
  itself, and the library derives the package root from its own location — so
  the package works from any path and under any directory name, with the
  numbered scripts one level down in `scripts/`.
- No absolute path into a home directory and no user name anywhere. Logs are
  chowned to `$SUDO_USER`.
- **Nothing about the topology is hardcoded.** `lib/egpu-lib.sh` derives the
  card, the bridge above it, the CPU root port, the device to remove and the
  rescan bus from sysfs, and passes the root port to the kernel module. It
  works regardless of Thunderbolt port, controller, or bus numbering, and it
  recognises NVIDIA, AMD and Intel display controllers.
- Machine-specific values go through the environment: `GPU`, `BRIDGE`,
  `WIN_BASE`, `WIN_MB`, `REBAR_SIZE`, `CAP_SPEED`.
- **`WIN_BASE` is checked against the live memory map, then searched for.** It
  used to be a written-down `0x4010000000` — a free hole in *this* machine's
  address map, which is a property of one firmware rather than of the card or of
  Thunderbolt. `egpu_find_free_window` now reads `/proc/iomem` and picks a free,
  1 MiB-aligned hole above 4 GB inside one of the host bridge's own apertures —
  the only place `pci_claim_resource()` can attach the window.

  That constant is still *tried first*, and deliberately so: it is the only base
  with a bring-up behind it here, and the failure mode on this platform is an
  instant reset with no kernel output, so "verified in practice" outranks "also
  unoccupied". The search decides only when it does not fit. `04-window.sh`
  reports which of the two you got (`preferred`, `discovered`, `override`, or
  `blind` when the map could not be read — the last one warns).
- **`REBAR_SIZE` has no default — the BAR1 size is read from the card.** It used
  to be a written-down `8` (256 MB), which is simply what this particular Ada
  card powers up with, so the ReBAR write was a no-op dressed as a decision.
  The size now comes from the card's ReBAR control register, and `REBAR_SIZE`
  is a pure override — which is the only way it was ever really used:
  `06-bar-fallback` *shrinks* BAR1 when the window cannot fit it.
- The Resizable BAR capability offset is discovered by walking the extended
  capability list, not hardcoded.
- One run produces one log. `run.sh` opens it and every script in the chain
  adopts it, because a nested `tee` stacks on the outer one rather than
  replacing it.
- **Logs rotate: the newest 10 of each kind are kept**, pruned as a new one is
  opened. Per kind rather than per directory, so a burst of standalone
  `script-*.log` runs cannot evict the `run-*.log` history. Ordered by name,
  which is chronological because the stamp is zero-padded, and unlike mtime
  cannot be perturbed afterwards. `EGPU_LOG_KEEP=0` disables it.
- No reference monitor or captured EDID is needed; any display works.

What the package cannot carry for you: kernel parameters. They need a
bootloader edit and a reboot, so `01-check.sh` only reports them.

udev rules it *does* carry, and that is worth knowing: `05-load-driver.sh`
writes `/etc/udev/rules.d/71-nvidia.rules` on every run, shadowing the
distribution's copy in `/lib` in order to drop the `RUN+=modprobe` lines that
would load the driver before the cap. The content is Ubuntu-specific
(`ub-device-create`, `nvidia-persistenced`). Anything that was there before is
kept once as `71-nvidia.rules.orig`; `01-check.sh` §5 checks the effect either
way.

---

## When the monitor stays black

A connector can be `connected` with a valid EDID and still show nothing.
Reading EDID and driving a display are different things: driving it is the
compositor's job, and the compositor has to know the output exists.

`run.sh` reports this explicitly as `connected but not driven`. Remedies, in
order of cost:

1. **unplug and replug the monitor cable.** This generates a connector hotplug
   event. If the monitor was already attached when the driver loaded, the
   compositor may have enumerated connectors before the driver finished
   detecting them, and it will not re-probe on its own.
2. **restart the session** - `sudo ./run.sh --restart-ui`, which hands the
   restart to a transient systemd unit so it survives the session it kills.
   Costs every open window.

   `--restart-ui` is a modifier, not a separate action:

   | state | what it does |
   |---|---|
   | card already up | restarts the session only, skips the bring-up |
   | card not up yet | brings the card up first, then restarts the session |

   The first case has to skip the bring-up: while a session is running the
   compositor holds `/dev/dri/card0` open, so `nvidia_drm` cannot be unloaded
   and the pipeline would abort before reaching the restart. The second case
   has to bring the card up first, because restarting a session that still has
   no GPU to find achieves nothing.

On this machine mutter 50.1 on Wayland does pick up a hot-plugged GPU; its log
says `Added device '/dev/dri/card0' (nvidia-drm) using atomic mode setting`.
So a session restart is the fallback, not the first move.

## Vulkan / games via Proton

Once the card is up, Vulkan enumerates it alongside every other GPU in the
machine (integrated GPU, any other discrete GPU). Enumeration order is not
guaranteed to stay stable across reboots or driver updates, and most games do
not let you pick a GPU — they take whichever the loader hands them first. If
that happens to be the wrong one, presentation fails outright: a swapchain
cannot be created on a surface driven by a different GPU, which shows up as a
crash (in Unreal Engine 4/5 titles, typically `CreateSwapChainResult failed`).

To force a game onto the eGPU regardless of enumeration order, add this as a
Steam launch option (or export it before running any other Vulkan app):

```
VK_DRIVER_FILES=/usr/share/vulkan/icd.d/nvidia_icd.json %command%
```

This restricts the Vulkan loader to the NVIDIA ICD alone, so the eGPU is the
only device the game ever sees. Adjust the path if your distribution installs
the ICD file elsewhere (`vulkaninfo --summary` prints the ICD path it used).

Do **not** set this globally in the session environment: with the card
unplugged, every Vulkan application would then have no GPU to enumerate at
all. Keep it scoped to the launch option of the games that need it.

If that alone does not fix presentation, some DXVK-based Proton versions also
honour `DXVK_FILTER_DEVICE_NAME="NVIDIA GeForce RTX 4080"` (adjust to your
card's name) as a lighter-weight alternative that still lets other ICDs load.

## Confirmed 2026-08-21

- `nvidia-smi` works, RTX 4080, 16376 MiB
- GSP running — `GSP Firmware Version: 610.43.02`
- **display output from the card's own HDMI port**, 3840x2160, 256-byte EDID
- P8, 22 W at idle; fans at 0 % / 47 °C is zero-RPM mode, not a fault
- DisplayPort not working
