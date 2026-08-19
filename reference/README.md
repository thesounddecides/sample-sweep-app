# alsorphan

Find sample files sitting in your Ableton Live project folders that **no Live Set
actually uses**, and get the disk space back.

Every producer accumulates these. You record fifteen guitar takes and keep two.
You freeze a track, then unfreeze it — Live leaves the freeze audio behind
forever. You consolidate, crop, reverse, bounce. None of it is ever cleaned up,
and it is effectively impossible to audit by hand once you have a few hundred
projects.

On the collection this was built against: **7.4 GB reclaimable across 397
projects**, found in 22 seconds.

```
  STATUS           FILES        SIZE   MEANING
  used              5094      16.8GB   referenced by this project's Live Set
  used-elsewhere      12     522.5MB   referenced by a different project's Set
  backup-only        188       1.5GB   only referenced by files in Backup/
  orphan            5689      17.5GB   referenced by nothing
  stray-asd           36      97.3MB   analysis file whose sample is gone

  RECLAIMABLE       5287       7.4GB
      Recorded                  4608       3.0GB
      Processed/Freeze           215       2.9GB
      Processed/Bounce           187     706.7MB
      Processed/Consolidate      144     330.3MB
```

## Install

Python 3.9+ and nothing else. macOS ships with it.

```bash
git clone https://github.com/YOURNAME/alsorphan && cd alsorphan
chmod +x alsorphan.py
```

## Use

Report only. Changes nothing, ever:

```bash
python3 alsorphan.py scan ~/Music/Ableton
```

With a browsable HTML report and a spreadsheet:

```bash
python3 alsorphan.py scan ~/Music/Ableton --html report.html --csv report.csv
```

When you are ready to reclaim the space — this **moves**, never deletes:

```bash
python3 alsorphan.py quarantine ~/Music/Ableton          # dry run
python3 alsorphan.py quarantine ~/Music/Ableton --apply  # actually move
```

Everything lands in a dated `Orphan Quarantine …` folder with a manifest.
Open your projects. Check nothing is missing. Then either drag that folder to
the trash yourself, or undo the whole thing:

```bash
python3 alsorphan.py restore "…/Orphan Quarantine 2026-08-18 124756/_manifest.json"
```

## How it decides

It reads every `.als` under the root — Live Sets are gzipped XML — and pulls out
every sample each one references, using two overlapping passes:

1. `<Path Value="/absolute/path.wav">`, the Live 11/12 format.
2. Any attribute value ending in an audio extension. This catches the Live 9/10
   format (which has no `<Path>`, only `<Name>` plus a directory chain), the
   old HFS-style `#Pack:Folder:Sample.aif` browser paths, and percent-encoded
   library references.

Pass 2 is deliberately over-broad, and matching falls back to filename when the
stored absolute path is stale — which it very often is, because a project that
moved machines still carries paths like
`C:/Users/you/OneDrive/Documents/Ableton/…`.

**The bias is deliberate.** A false "used" costs you disk space. A false
"orphan" costs you a session. Everything here errs toward keeping the file.

### What it will not touch

- **Anything outside `Samples/`.** A `.wav` sitting in the project root is
  usually a bounce, a master or a stem you put there on purpose. These are
  reported separately and held back unless you pass `--include-loose`.
- **Samples only referenced by a `Backup/` set.** Live's own version history
  still points at them, so restoring an old backup would break. Reported as
  `backup-only` and kept, unless you pass `--ignore-backups`.
- **Samples referenced by a *different* project.** Cross-project references are
  real and common. Every set under the scan root is indexed globally, so a
  sample living in project A but used by project B is marked `used-elsewhere`
  and kept. Scan the widest root you can for this reason.
- **Frozen tracks.** A frozen track references its freeze audio by name, so
  those files come out `used`. Only leftovers from tracks you *unfroze* are
  flagged — which is where most of the space usually is.

### `--deep`

Third-party plugins store their state as opaque hex blobs in the `.als`. If you
load samples into a sampler VST (Kontakt and friends) that points at files in
your project folder, those references are invisible to the normal parse.
`--deep` hex-decodes plugin state and searches it for sample names, in both
ASCII and UTF-16LE. Roughly 50% slower. It found nothing on the reference
collection, but if your workflow leans on sampler plugins, use it.

## Options

| flag | effect |
|---|---|
| `--include-loose` | also count unreferenced audio outside `Samples/` (bounces, masters) |
| `--ignore-backups` | treat samples only referenced by `Backup/` sets as orphans |
| `--deep` | search third-party plugin state for sample names |
| `--html FILE` | write a browsable report |
| `--csv FILE` / `--json FILE` | machine-readable output, one row per file |
| `--top N` | how many projects to list in the summary |
| `-j N` | worker processes |

## Known limits

- Samples referenced by a set *outside* the scan root are not seen. Scan wide.
- Live Packs (`.alp`) and other DAWs' project files are not parsed.
- `.asd` analysis files follow their sample's verdict; ones whose audio is gone
  entirely are flagged `stray-asd`.
- The tool never deletes. That is not a limitation, it is the design.

## Licence

MIT.
