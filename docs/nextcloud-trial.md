# Nextcloud trial on ArchNAS

A self-contained Nextcloud instance in Docker on the AS6704T, reachable only over
the tailnet, installed and removed by scripts in this repo. It exists to find out
what self-hosted Nextcloud actually feels like from a Windows desktop before
committing to a larger build — not to be production infrastructure.

`nextcloud-preflight` is read-only and is the correct first thing to run.

## Decision record

**Not Nextcloud All-in-One.** AIO's mastercontainer requires
`/var/run/docker.sock` mounted into it, which is root-equivalent on the host.
This box's actual job is keeping the rclone cloud-mirror pipeline alive, and that
pipeline plus the platform driver would sit inside the blast radius of any
Nextcloud compromise. A hand-written Compose project costs a little more setup
and keeps the socket to ourselves.

**Four services, upstream images, pinned tags.** `nextcloud:34.0.2-apache`,
`postgres:18-alpine`, `redis:8-alpine`, and a cron sidecar re-using the Nextcloud
image with `entrypoint: /cron.sh`. PostgreSQL is pinned to the *major* tag
deliberately: a minor bump is safe, a major bump makes the existing `PGDATA`
unreadable and the stack will not start.

**Rootful Docker, and nobody in the `docker` group.** Every Docker call goes
through the same sudo re-exec the rest of this repo uses. Group membership is the
exact risk rootless Docker is sold against, and never creating it removes that
risk more cheaply than adopting subuid mappings that would write every Nextcloud
file as a UID that does not exist on this box — hostile to a machine whose point
is that plain SSH and rclone can read those files.

**Docker's storage stays where Docker puts it.** Engine 29.0+ uses the containerd
image store by default, and that data lives in `/var/lib/containerd`, *not* under
`data-root`. Setting `data-root` alone would move almost nothing while creating a
two-place configuration that rots. The installer therefore never writes
`/etc/docker/daemon.json`; it refuses when the filesystem holding `/var/lib` has
under 15 GiB free and prints the two documented manual options instead. Log
rotation is set per-service in the compose file.

**TLS via `tailscale serve`.** The container publishes only
`127.0.0.1:<port>:80`; `tailscale serve --bg --https=443` fronts it. That yields
a genuine publicly-trusted certificate for `archnas.<tailnet>.ts.net` which both
the system browser and the desktop client accept with no trust-store work, adds
no container to a 4 GB box, and survives reboot. Self-signed was rejected because
Login Flow v2 hands off to the system browser, which will not trust it.

Publishing on `0.0.0.0` was rejected for a subtler reason: Docker's published
ports are DNAT'd in the nat table and bypass INPUT-based host firewalls
entirely, so `8080:80` would expose plain-HTTP Nextcloud to every tailnet peer
*and* the LAN regardless of nftables. Binding the literal Tailscale IP was also
rejected — if `tailscaled` has not assigned the address when the container
starts, the publish fails and the container restart-loops.

**Deliberately not shipped in v1:** notify_push, previewgenerator, Collabora,
Talk HPB, Imaginary. `notify_push` needs an Apache proxy fragment that, written
before the push container exists, can stop Apache starting — and Apache failing
to start on a headless tailnet-only box is the worst outcome this project can
produce. `preview:generate-all` is the most memory-hungry operation in the stack
and will OOM a 4 GB box mid-sync. The 30-second desktop-client polling interval
is part of the honest vanilla experience.

## Memory

The AS6704T ships with 4 GB in one of two SO-DIMM slots. ASUSTOR's specification
says expandable to 16 GB (2 × 8 GB). Community reports of 32 GB could not be
verified from a primary source and are not encoded anywhere here.

The installer reads `MemTotal` at runtime and selects one of two profiles.

| | under 6 GiB | 8 GiB or more |
|---|---|---|
| app `mem_limit` | 1280m | 3g |
| `PHP_MEMORY_LIMIT` | 512M | 512M |
| Apache `MaxRequestWorkers` | 8 | 24 |
| db `mem_limit` | 512m (`shared_buffers=128MB`) | 1g |
| redis `mem_limit` | 128m | 256m |
| cron `mem_limit` | 512m | 768m |

4 GB is survivable for one user **only** with all of: per-service `mem_limit`,
the Apache worker cap, Redis persistence off with no eviction policy, and swap or
zram present. It is not survivable with Collabora, Talk HPB, Imaginary, or
preview pre-generation.

One 8 GB SO-DIMM in the free slot removes this entire risk class for less than an
evening of tuning. Recommended before starting.

## Before you start

Run in `tmux` or `screen`. `nextcloud-install --install-docker` runs
`pacman -Syu`, which is mandatory on Arch (never `pacman -S` alone, which is an
unsupported partial upgrade) but which can:

- pull a new kernel, breaking the hand-built asustor modules unless they were
  installed with `sudo make dkms` rather than `make && sudo make install`. Check
  with `dkms status` first. Note that mafredri's driver lists the AS6704T as
  *"(NOT TESTED!)"*, and that `acpi_enforce_resources=lax` on the kernel command
  line is required for full it87 functionality.
- restart `tailscaled`, killing the SSH session you are standing on.

Because of that, Docker installation is a separate opt-in requiring
`--install-docker --i-understand-kernel-risk`, and the script refuses unless
`$TMUX` or `$STY` is set.

## Commands

| Command | Mutates? | Purpose |
|---|---|---|
| `nextcloud-preflight` | no | Discovery, refusals, and a text-only baseline under `/var/lib/nextcloud-trial/` |
| `nextcloud-install` | **yes** | The only mutating script. Runs preflight first and aborts on failure |
| `nextcloud-status` | no | One-screen health: containers, cert expiry, Login Flow v2 probe, free space, cloud-nas timers, asustor modules |
| `nextcloud-occ` | yes | `occ` wrapper. `nextcloud-occ status` |
| `nextcloud-postflight` | no | Diffs current state against the newest baseline — turns "nothing was disturbed" into an assertion |
| `nextcloud-uninstall` | **yes** | Teardown. Refuses unless the ownership marker exists |

## On the Windows machine (Corsair)

Install the desktop client:

```powershell
winget install --id Nextcloud.NextcloudDesktop --exact --source winget `
  --accept-package-agreements --accept-source-agreements
```

If winget is unavailable, the MSI is published on the **`nextcloud-releases/desktop`**
repository — not `nextcloud/desktop`, whose release carries no assets:

```
https://github.com/nextcloud-releases/desktop/releases/download/v34.0.1/Nextcloud-34.0.1-x64.msi
```

Then log in to `https://archnas.<tailnet>.ts.net` and let the system browser
complete Login Flow v2.

Two Windows constraints that matter here:

- **Put the sync folder at `C:\Nextcloud`, never under a OneDrive-managed path.**
  This machine already mirrors OneDrive; two Cloud Files API providers over one
  tree produce hydration storms, and that churn then rides the rclone pipeline
  back onto the NAS.
- **Keep the path short.** Windows `MAX_PATH` is 260 and Nextcloud's filename
  limit is 255 *bytes*, which UTF-8 Vietnamese consumes at up to 3 bytes per
  character.

Files-on-demand is opt-in on Windows and must be enabled in the folder-setup
dialog. Read the toggle's wording off the dialog rather than trusting a
remembered label — the Nextcloud desktop documentation pages for it returned 404
when this was written.

## Smoke test

1. Reach `https://archnas.<tailnet>.ts.net` in a browser and log in.
2. Install the client, enable virtual files, point it at `C:\Nextcloud`.
3. Drop a file in the web UI; confirm a placeholder appears in Explorer.
4. Open the placeholder; confirm it hydrates.
5. Edit and save; confirm the change reaches the web UI.
6. **The diacritic test.** Create files named in both NFC and NFD forms —
   `Báo cáo quý.docx`, `Nguyễn Văn An.pdf` — round-trip them macOS/Windows → server
   → back, and confirm the names are byte-identical and nothing was deleted.
   There is a known open Nextcloud desktop issue in this area; treat any silent
   deletion as a stop, not a bug report.

Expect propagation between machines to take up to 30 seconds. That is the
vanilla polling interval, not a fault, and it is what `notify_push` would fix.

## Removing it

```bash
nextcloud-uninstall              # containers, volumes, serve mapping, host files
nextcloud-uninstall --purge-data # also the array data, after a typed confirmation
```

The uninstaller takes a `pg_dump` and a copy of `config.php` before it removes
anything, and aborts if either fails. It refuses entirely unless the ownership
marker it wrote at install time is present — it will not delete a tree it did not
create.

**Unavoidable residue:** the `docker`, `docker-compose` and `containerd`
packages; images in the local store unless removed; and the array data directory
itself unless `--purge-data` was passed.
