# Sample Sweep

A small Mac app that finds the samples your Ableton projects no longer use, and
gives you the disk space back.

Every producer accumulates these. You record fifteen takes and keep two. You
freeze a track, then unfreeze it, and Live leaves the freeze audio behind
forever. You consolidate, crop, reverse, bounce. None of it is ever cleaned up,
and once you have a few hundred projects it is impossible to audit by hand.

On the collection this was built against — 397 projects, 554 Live Sets, 40 GB —
it found **7.4 GB of dead weight in 10 seconds**.

## How it works

Point it at your Ableton folder. It reads every Live Set it finds (they are
gzipped XML), works out which samples each one actually refers to, and compares
that against the audio files physically sitting in the project folders.

Anything nothing refers to is proposed for sweeping. You review the list, uncheck
anything you want to keep, and it **moves** the rest to a folder you choose,
along with a `Put These Files Back.json` record and a plain-English note.
Nothing is ever deleted. Open your projects, confirm they load, then archive or
trash that folder yourself — or choose **Put Files Back**, point at the folder,
and every file returns to where it came from.

You can rename that folder, or move it anywhere, and Undo still works: the
restore resolves each file relative to the folder itself rather than trusting
the absolute path recorded at sweep time. Folders written by older versions,
and by the Python reference tool, are still recognised.

## Safety

The whole design biases toward keeping files. A false "in use" costs you disk
space; a false "unused" costs you a session.

- **Frozen tracks are safe.** A frozen track refers to its freeze audio by name,
  so it reads as in use. Only leftovers from tracks you *unfroze* are flagged.
- **Cross-project references are respected.** Scanning your whole Ableton folder
  at once means a sample living in one project but used by another is spotted and
  kept. This is why the app asks for the widest folder you can give it.
- **Backups count.** Samples referenced only by files in Live's `Backup/` folder
  are kept by default, so restoring an old version still works.
- **Bounces and masters are left alone.** Audio outside `Samples/`, or dropped
  straight into `Samples/` by hand, is held back by default — Live never writes
  there, so a human put it there on purpose. Both are one checkbox away if you
  want them included.
- **Stale paths don't fool it.** Projects that have moved machines carry dead
  absolute paths (`C:/Users/you/...`), and Live 9 and 10 Sets have no absolute
  path at all — so matching falls back to filenames, and handles the
  decomposed-unicode mismatch between macOS filenames and Live's XML.
- **It warns you if Ableton is open.** An already-open Set keeps its samples in
  memory and will look fine whether or not the sweep was safe.

## Build

Swift 6, no dependencies beyond the system zlib. Full Xcode is not required —
Command Line Tools is enough.

```bash
./release.sh                                   # build, sign, notarize, dmg — the whole chain
./verify-release.sh build/SampleSweep-<v>.dmg  # clean-room check before publishing
```

## Repository layout

| path | what it is |
|---|---|
| `Sources/SweepCore` | the engine: gzip, reference scanning, classification, moving |
| `Sources/SampleSweep` | the SwiftUI app |
| `Sources/sweepcheck` | a CLI that dumps one line per file, used to validate the engine |
| `Tools/` | icon, dmg background and OG card generators; dmg assets; the Sound Decisions lockup |
| `reference/` | the Python reference engine the Swift one is diffed against |
| `config.sh` + `*.sh` | build → sign → notarize → dmg → verify, in order (`release.sh` runs the chain) |

## Validating the engine

The engine was developed against a reference implementation in Python
(`../ableton-unused sample-scan/alsunused sample.py`) and is checked against it file by file:

```bash
python3 ../ableton-unused sample-scan/alsunused sample.py scan ~/Music/Ableton -q --csv py.csv
.build/release/sweepcheck ~/Music/Ableton > sw.tsv
```

Last run: 10,835 files, zero status mismatches, zero reclaimable mismatches,
identical byte totals. Keep it that way — if you change classification logic,
change both and re-diff.

## Known limits

- Samples referenced by a Set outside the folder you scanned are not seen.
- Live Packs (`.alp`) and other DAWs' project files are not parsed.
- Third-party sampler plugins hide their sample paths inside opaque state blobs.
  The "Search inside plugin presets" option decodes those and looks for filenames;
  it is off by default because it is slower and found nothing on the reference
  collection, but turn it on if you lean on Kontakt and friends.

## Licence

MIT.
