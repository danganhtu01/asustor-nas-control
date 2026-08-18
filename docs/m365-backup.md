# Microsoft 365 mirror on the NAS

Pulls every OneDrive and every SharePoint document library in the tenant down to
the array, nightly, with no human ever signing in. The copy lives on hardware we
control, in-country, and survives the Microsoft account being suspended, expired
or deleted.

`m365-backup-preflight` is read-only and is the correct first thing to run.

## How it authenticates, and why that way

A single Entra **app registration** holding **Application** permissions
(`Files.Read.All`, `Sites.Read.All`, `User.Read.All`) mints a token by client
credentials. That token belongs to no user at all.

The alternative — a **delegated** token — is intersected with the signed-in
person's own access, so it can only ever see what that human could already see.
Nobody in the company is supposed to be able to read every colleague's OneDrive,
so no delegated token can do this job. Microsoft's own scanning guidance says the
same thing:

> *"Most scanning applications will want to operate with Application permissions,
> this indicates your application is running independently of any particular user."*

The other route people find — making an admin a site collection administrator on
each OneDrive — is deliberately **not** used here. It grants full control
including delete, it is standing until someone remembers to remove it, and once
granted the reads look like ordinary admin activity in the audit log. App-only is
narrower in permission and clearer in provenance: read-only, and every read
records as `app@sharepoint`.

**Read-only by design.** The registration must not hold `Files.ReadWrite.All`.
Restore is a deliberate, separate act — see *Restoring* below.

## Decision record

**rclone v1.69.0 is a hard floor.** App-only OneDrive auth
(`client_credentials`) landed in that release on 2025-01-12. Distro packages are
far older — Ubuntu ships v1.60 — and cannot authenticate without a browser, which
is exactly what an unattended job must never need. Every script refuses below
1.69 rather than failing obscurely later.

**Strictly serial, one drive at a time.** SharePoint meters resource units *per
application per tenant*, not per connection. Twenty parallel rclone processes do
not multiply throughput; they multiply the request rate against one shared bucket
and convert the run into a wall of 429s. Running one process at a time is what
makes `--tpslimit` a real tenant-wide ceiling. For a tenant under 1,000 licences
the budget is **1,250 RU/min** and **1,200,000 RU/day**; the default of 8 req/s
sits at roughly 77% of the documented ceiling.

**One app registration for the whole tenant.** Not one per department. Microsoft
names this exact anti-pattern:

> *"Don't create separate AppIDs where the applications essentially perform the
> same operations, such as backup... ended up exhausting the tenant's resource and
> causing multiple applications to be throttled in the tenant."*

**The destination must be a mountpoint.** On this box the array can be absent at
boot or unmounted by a firmware update, and the mountpoint then looks like an
ordinary empty directory on the OS disk. Syncing a tenant into it would fill the
root filesystem and take the NAS down. `m365-backup-sync` refuses to start unless
`M365_DEST_ROOT` is a mounted filesystem. Override only deliberately, with
`M365_ALLOW_NON_MOUNTPOINT=1`.

**The secret never lands in a durable rclone.conf.** Each run writes a config into
a 0700 temp directory and deletes it on exit. Nothing is passed in argv, where
`ps` would expose it to every user on the box.

**`--backup-dir`, always on by default.** rclone copies only the *current*
version of each file and cannot see OneDrive's version history at all. Replaced
and deleted files are moved into `archive/<run-stamp>/` instead of vanishing.
That archive is the only version history this mirror has.

## Commands

| Command | Mutates? | Purpose |
|---|---|---|
| `m365-backup-preflight` | no | config, permissions, rclone version, mountpoint, free space, and a live probe of all three Graph permissions |
| `m365-backup-inventory` | no | rebuilds the drive manifest from the tenant |
| `m365-backup-sync` | **yes** | the only mutating script; runs preflight first |
| `m365-backup-status` | no | one screen: timer, mount, sizes, last run, errors, token |

## Setup

```bash
sudo ./scripts/install.sh
sudo nano /etc/m365-backup/m365-backup.conf     # tenant, client id, dest root

printf %s 'THE-SECRET-VALUE' | sudo tee /etc/m365-backup/client_secret >/dev/null
sudo chmod 400 /etc/m365-backup/client_secret
```

The secret must have **no trailing newline** — use `printf %s`, never `echo`.
Preflight checks this, because the failure it causes otherwise is opaque.

Then, in order, each step read-only until the last:

```bash
m365-backup-preflight
m365-backup-inventory
m365-backup-sync --dry-run
m365-backup-sync
```

Schedule it once the first manual run has completed cleanly:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now m365-backup.timer
systemctl list-timers m365-backup.timer
```

> **Re-run `install.sh` after changing the destination.** `ProtectSystem=strict`
> makes the filesystem read-only apart from `ReadWritePaths=`, and the installer
> generates that from the config into
> `/etc/systemd/system/m365-backup.service.d/destination.conf`. Skip it and the
> run fails with a permission error that looks nothing like a path problem.

## Paths are composed, never hardcoded

Nothing in this repository contains a literal mirror path. The destination is
built from layers, each independently overridable in the config file or from the
environment for a one-off run:

```
M365_DEST_ROOT  =  NAS_MOUNT_BASE / NAS_M365_VOLUME / M365_SUBDIR
       default        /srv              NAS_03           m365
```

**The default targets NAS_03 on purpose.** That volume is where the existing
cloud-mirror sweep writes, so anything landing there is carried into the nightly
NAS_03 → NAS_02 snapshot with no extra wiring. The Microsoft 365 mirror joins the
backup sweep already in place rather than needing one of its own.

`M365_VOLUME_ROOT` (default `$NAS_MOUNT_BASE/$NAS_M365_VOLUME`) is the part that
must genuinely be a mountpoint. The subdirectory beneath it is ours to create, so
its existence proves nothing — the guard deliberately checks the volume.

## Moving the mountpoints

`nas-mount-migrate` relocates the data volumes between mount bases, keeping the
volume labels as directory names, and rewrites `/etc/fstab` to match.

```bash
nas-mount-migrate --from /run/media/$USER --to /srv --dry-run
nas-mount-migrate --from /run/media/$USER --to /srv
```

It refuses unless no sync job is running, every source is mounted, and every
target is free; it validates the rewritten fstab before installing it; and it
unwinds — restoring fstab **and remounting the volumes** — on any failure,
including a failed verification.

Two things it taught us, both worth keeping in mind generally:

- **`mount` returns 0 without mounting when the entry carries `nofail`.** That is
  exactly what `nofail` means. The only trustworthy check is to ask the kernel
  afterwards with `mountpoint`.
- **`findmnt --verify` exits non-zero on a perfectly healthy fstab**, for reasons
  that predate any given change. The migration compares error counts before and
  after instead, so it aborts on regressions rather than on pre-existing noise.

After it runs, update anything still referencing the old base and only then
restart the sync loops:

```bash
grep -rn '/run/media' ~ /etc/systemd 2>/dev/null
```

## Layout on disk

```
$M365_DEST_ROOT/current/onedrive/<upn>/...
$M365_DEST_ROOT/current/sharepoint/<site>/<library>/...
$M365_DEST_ROOT/archive/<run-stamp>/...     replaced and deleted files
$M365_DEST_ROOT/_logs/<run-stamp>/          one log per drive
```

## What this does not capture

A mirror that people misunderstand is worse than no mirror, so state these plainly:

| Not captured | Consequence |
|---|---|
| OneDrive version history | only the current version of each file; `archive/` is the substitute |
| Recycle bin, both stages | anything deleted before the first run is already gone |
| Sharing permissions | off by default; `--permissions` costs **5 RU** per item instead of 1–2, so weekly at most |
| OneNote notebooks | rclone hides them; they are not ordinary files |
| SharePoint Lists | document libraries only |
| Teams chat messages | those live in Exchange. Channel *files* are covered |
| Retention labels and holds | not transferable |

**Leavers.** A deleted user's OneDrive is retained for a configurable period —
default **30 days**, settable from 30 to **3650** in SharePoint admin center →
Settings → Retention, plus 93 further days in a deleted state. Raise it; the
default is the only thing that makes departures urgent.

**AV-blocked files.** OneDrive returns 403 for files it has flagged.
`--onedrive-av-override` is on so one suspect file cannot abort a whole run.

## Restoring

The registration is read-only, and should stay that way.

- **A few files:** copy them out of `current/` or `archive/` and upload through
  the web UI. No extra permission needed.
- **Bulk:** temporarily add `Files.ReadWrite.All` to the same registration under a
  change ticket, run rclone in reverse, then **remove it again**. Do not create a
  second AppID.

**A backup that has never been restored is not a backup.** Once a quarter, pick a
folder at random, restore it to a scratch site, and compare.
