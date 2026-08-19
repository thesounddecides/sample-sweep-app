"""Sample Sweep for Windows - the engine facade.

The classification engine is `reference/alsorphan.py`, the Python reference
implementation the Mac app's Swift engine is diffed against (see README,
"Validating the engine"). This module does not re-implement any of it. It

  * imports the oracle and runs its `scan()`,
  * re-applies the Mac app's reclaimability rule on top (the oracle's CLI
    never grew the "loose in Samples/" hold-back that SweepCore has),
  * writes the same sweep folder the Mac app writes - `Sample Sweep <stamp>/`,
    `Put These Files Back.json`, `READ ME.txt` - so a folder swept on one OS
    can be put back by the other,
  * restores with the same rename-resilient lookup as `Quarantine.locate`,
  * and holds the few OS-specific helpers the GUI needs.

Nothing here deletes. Move + manifest + undo only.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import time
import webbrowser
from dataclasses import dataclass, field

# --- import the oracle ----------------------------------------------------

_HERE = os.path.dirname(os.path.abspath(__file__))
_REPO = os.path.abspath(os.path.join(_HERE, "..", ".."))
if not getattr(sys, "frozen", False):
    _ref = os.path.join(_REPO, "reference")
    if _ref not in sys.path:
        sys.path.insert(0, _ref)

import alsorphan as engine  # noqa: E402  (the reference engine, stdlib-only)


# --- version --------------------------------------------------------------

def _read_version() -> str:
    """`windows/VERSION` is the single source for the Windows build. PyInstaller
    bundles it next to the executable; in a checkout it is two levels up."""
    candidates = []
    if getattr(sys, "frozen", False):
        candidates.append(os.path.join(getattr(sys, "_MEIPASS", os.path.dirname(sys.executable)), "VERSION"))
        candidates.append(os.path.join(os.path.dirname(sys.executable), "VERSION"))
    candidates.append(os.path.join(_HERE, "..", "VERSION"))
    for c in candidates:
        try:
            with open(c, encoding="utf-8") as fh:
                v = fh.read().strip()
                if v:
                    return v
        except OSError:
            continue
    return "0.0.0"


VERSION = _read_version()
TOOL_NAME = "Sample Sweep"
SITE_URL = "https://thesounddecides.com"
IS_WINDOWS = sys.platform.startswith("win")
# Copy only (Explorer/Finder, Recycle Bin/Trash, Documents\Ableton hint). True on
# Windows; on a Mac, `--preview-windows` turns it on so the Windows wording can be
# proofread without a Windows machine. Behaviour (reveal, process check, paths)
# always follows IS_WINDOWS.
WINDOWS_WORDING = IS_WINDOWS or os.environ.get("SAMPLESWEEP_PREVIEW_WINDOWS") == "1"
FILE_MANAGER = "Explorer" if WINDOWS_WORDING else "Finder"
TRASH_NAME = "the Recycle Bin" if WINDOWS_WORDING else "the Trash"


# --- options + results (mirror SweepCore/Models.swift) ---------------------

@dataclass
class Options:
    """Same four switches as `SweepOptions` in the Mac app, same defaults."""
    include_unmanaged: bool = False        # audio outside Samples/ (bounces, masters)
    include_loose_in_samples: bool = False  # audio dropped straight into Samples/
    ignore_backups: bool = False           # backup-only samples count as unused
    deep: bool = False                     # search plugin state too (slower)


STATUS_EXPLANATION = {
    "used": "In use by this project",
    "used-elsewhere": "Used by a different project",
    "backup-only": "Only used by a backup of this set",
    "orphan": "Nothing refers to it",
    "stray-asd": "Analysis file, its sample is gone",
}


def bucket_kind(bucket: str) -> str:
    """The oracle labels buckets by folder; the Mac app has three kinds."""
    if bucket == "unmanaged":
        return "unmanaged"
    if bucket == "Samples (loose)":
        return "loose"
    return "managed"


def bucket_label(bucket: str) -> str:
    return "Outside Samples" if bucket == "unmanaged" else bucket


def is_reclaimable(status: str, bucket: str, options: Options) -> bool:
    """Verbatim port of `Scanner.isReclaimable` in SweepCore."""
    if status not in ("orphan", "stray-asd"):
        return False
    kind = bucket_kind(bucket)
    if kind == "managed":
        return True
    if kind == "loose":
        return options.include_loose_in_samples
    return options.include_unmanaged


@dataclass
class SweepFile:
    path: str
    relative_path: str
    size: int
    status: str
    bucket: str          # display label
    reclaimable: bool


@dataclass
class SweepProject:
    directory: str
    display_name: str
    sets: list[str]
    backups: list[str]
    files: list[SweepFile] = field(default_factory=list)

    @property
    def reclaimable_files(self) -> list[SweepFile]:
        return [f for f in self.files if f.reclaimable]

    @property
    def reclaimable_bytes(self) -> int:
        return sum(f.size for f in self.files if f.reclaimable)


@dataclass
class SweepStats:
    project_count: int = 0
    live_set_count: int = 0
    backup_count: int = 0
    scanned_files: int = 0
    reclaimable_files: int = 0
    reclaimable_bytes: int = 0
    held_back_files: int = 0
    held_back_bytes: int = 0
    seconds: float = 0.0


@dataclass
class SweepResult:
    root: str
    projects: list[SweepProject]
    stats: SweepStats


def _rel_under(path: str, root: str) -> str | None:
    """`path` relative to `root`, or None if it is not inside it. Tolerates
    mixed separators (manifests written by the Mac app or the old CLI)."""
    try:
        rel = os.path.relpath(path, root)
    except ValueError:          # different drive on Windows
        return None
    if rel == os.curdir or rel == os.pardir or rel.startswith(os.pardir + os.sep):
        return None
    return rel


def scan(root: str, options: Options | None = None, progress=None) -> SweepResult:
    """Run the oracle, then apply the Mac app's keep/reclaim rule.

    `progress(stage, done, total)` is forwarded from the engine; it is called on
    the thread that called `scan`, so marshal to the UI thread yourself.
    """
    options = options or Options()
    t0 = time.time()
    root = os.path.normpath(os.path.abspath(root))
    projects_raw, _ = engine.scan(
        root,
        include_loose=True,              # irrelevant: reclaimable is recomputed below
        ignore_backups=options.ignore_backups,
        deep=options.deep,
        quiet=True,
        progress=progress,
    )

    projects: list[SweepProject] = []
    stats = SweepStats()
    for pr in projects_raw:
        files: list[SweepFile] = []
        for f in pr.files:
            recl = is_reclaimable(f.status, f.bucket, options)
            files.append(SweepFile(f.path, f.rel, f.size, f.status, bucket_label(f.bucket), recl))
            stats.scanned_files += 1
            if recl:
                stats.reclaimable_files += 1
                stats.reclaimable_bytes += f.size
            elif f.status in ("orphan", "stray-asd"):
                stats.held_back_files += 1
                stats.held_back_bytes += f.size
        projects.append(SweepProject(
            directory=pr.dir,
            display_name=_rel_under(pr.dir, root) or pr.dir,
            sets=list(pr.sets), backups=list(pr.backups), files=files,
        ))
        stats.live_set_count += len(pr.sets)
        stats.backup_count += len(pr.backups)

    stats.project_count = len(projects)
    stats.seconds = round(time.time() - t0, 1)
    projects.sort(key=lambda p: -p.reclaimable_bytes)
    return SweepResult(root=root, projects=projects, stats=stats)


# --- move aside + put back (mirror SweepCore/Quarantine.swift) -------------

MANIFEST_NAME = "Put These Files Back.json"
LEGACY_MANIFEST_NAMES = ["Sample Sweep Manifest.json", "_manifest.json"]
README_NAME = "READ ME.txt"


@dataclass
class MoveOutcome:
    folder: str
    manifest: str
    moved: int
    bytes: int
    failures: list[tuple[str, str]]


@dataclass
class RestoreOutcome:
    restored: int
    already_in_place: int
    missing: int
    total: int


def find_manifest(folder: str) -> str | None:
    """The restore file inside a swept folder, so the user can point at the
    folder itself. Older names, including the CLI's, are still accepted."""
    for name in [MANIFEST_NAME] + LEGACY_MANIFEST_NAMES:
        c = os.path.join(folder, name)
        if os.path.isfile(c):
            return c
    try:
        entries = sorted(os.listdir(folder))
    except OSError:
        return None
    for name in entries:
        if not name.lower().endswith(".json"):
            continue
        c = os.path.join(folder, name)
        try:
            with open(c, encoding="utf-8") as fh:
                data = json.load(fh)
            if isinstance(data, dict) and data.get("moved"):
                return c
        except (OSError, ValueError):
            continue
    return None


def move_files(files: list[SweepFile], root: str, destination: str,
               progress=None) -> MoveOutcome:
    """Move `files` into `destination/Sample Sweep <stamp>/`, mirroring their
    paths under `root`, and write the manifest + note. Never deletes."""
    stamp = time.strftime("%Y-%m-%d %H%M%S")
    folder = os.path.join(destination, f"{TOOL_NAME} {stamp}")
    os.makedirs(folder, exist_ok=True)

    moved: list[dict] = []
    failures: list[tuple[str, str]] = []
    total = len(files)
    for i, f in enumerate(files):
        rel = _rel_under(f.path, root) or os.path.basename(f.path)
        target = os.path.join(folder, rel)
        try:
            os.makedirs(os.path.dirname(target), exist_ok=True)
            if os.path.exists(target):
                raise FileExistsError(f"already exists: {target}")
            shutil.move(f.path, target)
            moved.append({"bytes": f.size, "from": f.path, "to": target})
        except Exception as exc:  # noqa: BLE001 - report, never abort the sweep
            failures.append((f.path, str(exc)))
        if progress:
            progress(i + 1, total)

    total_bytes = sum(m["bytes"] for m in moved)
    manifest = {
        "created": stamp,
        "folder": folder,
        "moved": moved,
        "root": root,
        "tool": TOOL_NAME,
        "version": VERSION,
    }
    manifest_path = os.path.join(folder, MANIFEST_NAME)
    with open(manifest_path, "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, indent=2, sort_keys=True, ensure_ascii=False)
        fh.write("\n")

    trash = TRASH_NAME
    note = f"""{TOOL_NAME}, {stamp}

These {len(moved)} files ({human_bytes(total_bytes)}) were moved out of your
Ableton projects because no Live Set was using them.

Nothing has been deleted. The folder structure mirrors your projects, so
you can see exactly where each file came from.

What to do now:
  1. Open the projects you care about in Ableton and check they load.
  2. If everything is fine, drag this folder to {trash}, or archive it.
  3. If something is missing, open Sample Sweep, choose "Put Files Back"
     from the File menu, and pick THIS FOLDER. Everything returns to
     where it came from.

You can rename this folder or move it anywhere you like. Put Files Back
still works, as long as "{MANIFEST_NAME}" stays inside it.
"""
    try:
        with open(os.path.join(folder, README_NAME), "w", encoding="utf-8") as fh:
            fh.write(note)
    except OSError:
        pass

    return MoveOutcome(folder=folder, manifest=manifest_path, moved=len(moved),
                       bytes=total_bytes, failures=failures)


def _locate(entry: dict, manifest: dict, folder: str) -> str | None:
    """Where the swept copy lives now. The recorded absolute `to` is only a
    hint: people rename or move the folder, and that must not break Undo."""
    to = entry.get("to", "")
    if to and os.path.exists(to):
        return to
    root = manifest.get("root", "")
    rel = _rel_under(entry.get("from", ""), root) if root else None
    if rel is None:
        return None
    candidate = os.path.join(folder, rel)
    return candidate if os.path.exists(candidate) else None


def restore(manifest_path: str, progress=None) -> RestoreOutcome:
    with open(manifest_path, encoding="utf-8") as fh:
        manifest = json.load(fh)
    folder = os.path.dirname(os.path.abspath(manifest_path))
    moved = manifest.get("moved", [])
    restored = already = missing = 0
    for i, entry in enumerate(moved):
        src_from = entry.get("from", "")
        if src_from and os.path.exists(src_from):
            already += 1
        else:
            source = _locate(entry, manifest, folder)
            if source is None:
                missing += 1
            else:
                try:
                    os.makedirs(os.path.dirname(src_from), exist_ok=True)
                    shutil.move(source, src_from)
                    restored += 1
                except Exception:  # noqa: BLE001
                    missing += 1
        if progress:
            progress(i + 1, len(moved))
    return RestoreOutcome(restored=restored, already_in_place=already,
                          missing=missing, total=len(moved))


# --- small helpers ---------------------------------------------------------

def human_bytes(n: int) -> str:
    """Same rendering as `humanBytes` in the Mac app: "1.4 GB", "512 B"."""
    units = ["B", "KB", "MB", "GB", "TB"]
    value, i = float(n), 0
    while abs(value) >= 1024 and i < len(units) - 1:
        value /= 1024
        i += 1
    return f"{n} B" if i == 0 else f"{value:.1f} {units[i]}"


def pluralized(n: int, noun: str) -> str:
    return f"{n} {noun}" if n == 1 else f"{n} {noun}s"


def default_ableton_folder() -> str:
    """Where the folder picker opens. Live's default project location is
    Documents\\Ableton on Windows and ~/Music/Ableton on the Mac."""
    home = os.path.expanduser("~")
    if IS_WINDOWS:
        for c in (os.path.join(home, "Documents", "Ableton"),
                  os.path.join(home, "Documents")):
            if os.path.isdir(c):
                return c
        return home
    for c in (os.path.join(home, "Music", "Ableton"), os.path.join(home, "Music")):
        if os.path.isdir(c):
            return c
    return home


def default_destination_folder() -> str:
    home = os.path.expanduser("~")
    d = os.path.join(home, "Desktop")
    return d if os.path.isdir(d) else home


def _no_window_flags() -> int:
    return getattr(subprocess, "CREATE_NO_WINDOW", 0) if IS_WINDOWS else 0


def ableton_is_running() -> bool:
    """True if any Ableton Live process is running. Best effort: on any error
    we answer False rather than block the scan."""
    try:
        if IS_WINDOWS:
            out = subprocess.run(["tasklist", "/FO", "CSV", "/NH"], capture_output=True,
                                 text=True, timeout=8, creationflags=_no_window_flags()).stdout
        else:
            out = subprocess.run(["ps", "-axo", "comm="], capture_output=True,
                                 text=True, timeout=8).stdout
    except Exception:  # noqa: BLE001
        return False
    return "ableton" in out.lower()


def reveal(path: str) -> None:
    """Show `path` selected in Explorer (or Finder)."""
    try:
        if IS_WINDOWS:
            subprocess.Popen(["explorer", f"/select,{os.path.normpath(path)}"])
        elif sys.platform == "darwin":
            subprocess.Popen(["open", "-R", path])
        else:
            subprocess.Popen(["xdg-open", os.path.dirname(path)])
    except Exception:  # noqa: BLE001
        pass


def open_site() -> None:
    webbrowser.open(SITE_URL)


# --- self-test -------------------------------------------------------------

def selftest(keep: bool = False) -> dict:
    """Build a tiny synthetic Ableton library in a temp folder, scan it with the
    app's defaults, move, rename the folder, restore, and assert every step.
    Exercises the frozen engine end to end (including the process pool), so CI
    can run `"Sample Sweep.exe" --selftest` on the packaged build.
    """
    import gzip
    import tempfile

    def als(path: str, names: list[str]) -> None:
        refs = "".join(
            f'<SampleRef><FileRef><Name Value="{n}" /><Path Value="" /></FileRef></SampleRef>'
            for n in names)
        xml = f'<?xml version="1.0" encoding="UTF-8"?><Ableton><LiveSet>{refs}</LiveSet></Ableton>'
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as fh:
            fh.write(gzip.compress(xml.encode("utf-8")))

    def wav(path: str, size: int = 4096) -> None:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as fh:
            fh.write(b"RIFF" + bytes(size - 4))

    tmp = tempfile.mkdtemp(prefix="samplesweep-selftest-")
    root = os.path.join(tmp, "Ableton")
    a = os.path.join(root, "A Project")
    b = os.path.join(root, "B Project")
    als(os.path.join(a, "A.als"), ["keep.wav"])
    als(os.path.join(a, "Backup", "A [2026-01-01 120000].als"), ["keep.wav", "frz.wav"])
    als(os.path.join(b, "B.als"), ["shared.wav"])
    als(os.path.join(b, "Backup", "B [2026-01-01 120000].als"), ["crossfrz.wav"])
    wav(os.path.join(a, "Samples", "Recorded", "keep.wav"))          # used
    wav(os.path.join(a, "Samples", "Recorded", "dead.wav"), 8192)    # orphan  -> reclaimable
    wav(os.path.join(a, "Samples", "Recorded", "dead.wav.asd"), 512)  # inherits orphan
    wav(os.path.join(a, "Samples", "Recorded", "gone.wav.asd"), 256)  # stray-asd -> reclaimable
    wav(os.path.join(a, "Samples", "Imported", "shared.wav"))         # used-elsewhere (B)
    wav(os.path.join(a, "Samples", "Processed", "Freeze", "frz.wav"))  # backup-only (own Backup/)
    wav(os.path.join(a, "Samples", "Processed", "Freeze", "crossfrz.wav"))  # backup-only (B's Backup/)
    wav(os.path.join(a, "Samples", "loose.wav"))                     # loose -> held back
    wav(os.path.join(a, "bounce.wav"))                               # unmanaged -> held back

    result = scan(root, Options())
    by_name = {os.path.basename(f.path): f for p in result.projects for f in p.files}
    expect = {
        "keep.wav": ("used", False), "dead.wav": ("orphan", True),
        "dead.wav.asd": ("orphan", True), "gone.wav.asd": ("stray-asd", True),
        "shared.wav": ("used-elsewhere", False), "frz.wav": ("backup-only", False),
        "crossfrz.wav": ("backup-only", False),
        "loose.wav": ("orphan", False), "bounce.wav": ("orphan", False),
    }
    for name, (status, recl) in expect.items():
        f = by_name.get(name)
        assert f is not None, f"missing {name}"
        assert f.status == status, f"{name}: status {f.status} != {status}"
        assert f.reclaimable == recl, f"{name}: reclaimable {f.reclaimable} != {recl}"
    assert result.stats.reclaimable_files == 3, result.stats
    assert result.stats.held_back_files == 2, result.stats

    # Option switches flip exactly the held-back files.
    r2 = scan(root, Options(include_unmanaged=True, include_loose_in_samples=True))
    assert r2.stats.reclaimable_files == 5, r2.stats
    # "Treat backup-only as unused" drops the cross-project backup index only;
    # a project's own Backup/ still protects its files. Same as SweepCore.
    r3 = scan(root, Options(ignore_backups=True))
    assert {os.path.basename(f.path) for p in r3.projects for f in p.reclaimable_files} \
        == {"dead.wav", "dead.wav.asd", "gone.wav.asd", "crossfrz.wav"}, r3.stats

    # Move aside, rename the folder, put back.
    targets = [f for p in result.projects for f in p.reclaimable_files]
    dest = os.path.join(tmp, "Desktop")
    os.makedirs(dest)
    out = move_files(targets, result.root, dest)
    assert out.moved == 3 and not out.failures, out
    assert os.path.isfile(out.manifest) and os.path.isfile(os.path.join(out.folder, README_NAME))
    assert not os.path.exists(by_name["dead.wav"].path)
    renamed = os.path.join(tmp, "Somewhere Else", "renamed sweep")
    os.makedirs(os.path.dirname(renamed))
    shutil.move(out.folder, renamed)
    m = find_manifest(renamed)
    assert m and os.path.basename(m) == MANIFEST_NAME, m
    back = restore(m)
    assert back.restored == 3 and back.missing == 0, back
    assert os.path.isfile(by_name["dead.wav"].path)
    again = restore(m)
    assert again.already_in_place == 3, again

    summary = {"root": root, "files": result.stats.scanned_files,
               "reclaimable": result.stats.reclaimable_files,
               "moved": out.moved, "restored": back.restored, "version": VERSION}
    if not keep:
        shutil.rmtree(tmp, ignore_errors=True)
    return summary
