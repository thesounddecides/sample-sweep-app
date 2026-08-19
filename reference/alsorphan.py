#!/usr/bin/env python3
"""
alsorphan - find orphaned samples inside Ableton Live project folders.

Reads every .als (Live Set) under a root folder, extracts the samples each one
actually references, then compares that against the audio files physically
sitting in the project folders. Anything referenced by nothing is an orphan.

Safety model - this tool never deletes. `scan` only reports. `quarantine`
moves files into a dated folder with a manifest, and `restore` puts them back.

Requires only the Python 3 standard library.
"""

from __future__ import annotations

import argparse
import binascii
import csv
import functools
import gzip
import html
import json
import os
import re
import shutil
import sys
import time
import unicodedata
import urllib.parse
from concurrent.futures import ProcessPoolExecutor
from dataclasses import dataclass, field, asdict

VERSION = "1.0.0"

# Extensions Live can reference as a sample/clip source.
AUDIO_EXTS = {
    ".wav", ".aif", ".aiff", ".mp3", ".flac", ".m4a", ".aac", ".ogg",
    ".wv", ".caf", ".sd2", ".au", ".snd", ".rex", ".rx2",
    ".mov", ".mp4", ".avi", ".m4v",  # video clips live on audio tracks too
}
# Files that hold sample references.
REF_EXTS = {".als", ".alc", ".adg", ".adv", ".agr", ".ams", ".amxd"}

_ATTR_VALUE = re.compile(r'Value="([^"]*)"')
_BUFFER = re.compile(r"<Buffer>\s*([0-9A-Fa-f\s]+?)\s*</Buffer>")
_BLOB_NAME = re.compile(
    rb"[\x20-\x7e]{1,160}?\.(?:wav|aif|aiff|mp3|flac|WAV|AIF|AIFF|MP3|FLAC)")
_PATH_VALUE = re.compile(r'<Path Value="([^"]*)"')
_XML_ESCAPES = (
    ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
    ("&quot;", '"'), ("&apos;", "'"), ("&#13;", "\r"), ("&#10;", "\n"),
)


def nfc(s: str) -> str:
    """macOS stores filenames decomposed (NFD); Live's XML is often composed."""
    return unicodedata.normalize("NFC", s)


def unescape(s: str) -> str:
    for a, b in _XML_ESCAPES:
        s = s.replace(a, b)
    return s


def leaf(value: str) -> str:
    """Last path segment, across every separator Live has ever used.

    Covers POSIX '/', Windows '\\' and the old HFS ':' browser paths such as
    '#One Shot FX:FX Oop.aif' and 'query:...%20...'.
    """
    v = value.replace("\\", "/").replace(":", "/")
    return v.rsplit("/", 1)[-1]


def has_audio_ext(name: str) -> bool:
    return os.path.splitext(name)[1].lower() in AUDIO_EXTS


def read_ref_file(path: str) -> str:
    """Live Sets are gzipped XML; some devices/presets are plain. Handle both."""
    with open(path, "rb") as fh:
        head = fh.read(2)
        fh.seek(0)
        raw = fh.read()
    if head == b"\x1f\x8b":
        try:
            raw = gzip.decompress(raw)
        except OSError:
            pass  # truncated/partial gzip - fall through and scan what we have
    return raw.decode("utf-8", errors="replace")


def scan_plugin_blobs(text: str) -> set[str]:
    """Dig sample names out of third-party plugin state.

    Live stores VST/AU state as hex <Buffer> blobs, opaque to the FileRef
    parser. A sampler plugin pointing at a file in the project folder would be
    invisible otherwise. We hex-decode and look for anything ending in an audio
    extension, in both ASCII and UTF-16LE (Windows-built plugins).
    """
    names: set[str] = set()
    for m in _BUFFER.finditer(text):
        try:
            raw = binascii.unhexlify(re.sub(r"\s", "", m.group(1)))
        except Exception:
            continue
        blobs = [raw]
        try:
            blobs.append(raw.decode("utf-16-le", errors="ignore")
                            .encode("latin1", "ignore"))
        except Exception:
            pass
        for blob in blobs:
            for hit in _BLOB_NAME.findall(blob):
                names.add(nfc(leaf(hit.decode("latin1"))))
    return names


def extract_refs(path: str, deep: bool = False) -> tuple[str, set[str], set[str]]:
    """Return (path, absolute sample paths, referenced file basenames).

    Two extraction passes, deliberately overlapping:

      1. <Path Value="/abs/path.wav">  - Live 11/12 format, gives exact paths.
      2. any Value="...ends in audio ext" - catches the Live 9/10 format
         (which has no <Path>, only <Name>) plus browser/pack paths.

    Pass 2 is intentionally over-broad. A false "used" costs disk space; a
    false "orphan" costs someone's session. We bias hard toward false "used".
    """
    try:
        text = read_ref_file(path)
    except Exception:
        return path, set(), set()

    abs_paths: set[str] = set()
    names: set[str] = set()

    for m in _PATH_VALUE.finditer(text):
        p = nfc(unescape(m.group(1)))
        if has_audio_ext(p):
            abs_paths.add(p)
            names.add(nfc(leaf(p)))

    for m in _ATTR_VALUE.finditer(text):
        v = m.group(1)
        if "." not in v:
            continue
        v = unescape(v)
        candidates = [v]
        if "%" in v:
            try:
                candidates.append(urllib.parse.unquote(v))
            except Exception:
                pass
        for c in candidates:
            base = leaf(c)
            if has_audio_ext(base):
                names.add(nfc(base))

    if deep:
        names |= scan_plugin_blobs(text)
    return path, abs_paths, names


@dataclass
class FileRecord:
    path: str
    rel: str
    size: int
    status: str          # used | used-elsewhere | backup-only | orphan | stray-asd
    bucket: str          # Recorded / Processed-Freeze / Imported / (loose) ...
    project: str
    reclaimable: bool = False


@dataclass
class Project:
    dir: str
    sets: list[str] = field(default_factory=list)
    backups: list[str] = field(default_factory=list)
    files: list[FileRecord] = field(default_factory=list)


def find_projects(root: str) -> list[str]:
    """A project folder is any directory holding at least one .als.

    'Backup' subfolders are Live's own versioned copies, not projects.
    """
    projects = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if not d.startswith(".")]
        if os.path.basename(dirpath) == "Backup":
            continue
        if any(f.endswith(".als") for f in filenames):
            projects.append(dirpath)
    return sorted(projects)


def bucket_for(rel: str) -> str:
    """Where inside the project the file sits - drives the default keep/reclaim
    decision. Anything outside Samples/ is 'unmanaged': often a bounce, a
    master, or a stem the producer put there on purpose."""
    parts = rel.split(os.sep)
    if "Samples" not in parts:
        return "unmanaged"
    i = parts.index("Samples")
    tail = parts[i + 1:-1]  # drop the filename itself
    if not tail:
        return "Samples (loose)"
    if tail[0] == "Processed" and len(tail) > 1:
        return f"Processed/{tail[1]}"
    return tail[0]


def scan(root: str, include_loose: bool = False, ignore_backups: bool = False,
         deep: bool = False, workers: int | None = None, quiet: bool = False,
         progress=None) -> tuple[list[Project], dict]:
    """`progress`, if given, is called as progress(stage, done, total) from the
    calling thread: ("Finding projects", 0, 0), then ("Reading Live Sets", n, N)
    as sets parse, then ("Checking samples", n, N) per project. Used by the
    Windows app; the CLI leaves it None."""
    t0 = time.time()
    if progress:
        progress("Finding projects", 0, 0)
    project_dirs = find_projects(root)
    if not project_dirs:
        return [], {"root": root, "projects": 0}

    # Map every project's .als files, split into live sets vs Live's backups.
    projects: dict[str, Project] = {}
    all_ref_files: list[str] = []
    for pdir in project_dirs:
        pr = Project(dir=pdir)
        for name in sorted(os.listdir(pdir)):
            full = os.path.join(pdir, name)
            if os.path.isfile(full) and os.path.splitext(name)[1].lower() in REF_EXTS:
                pr.sets.append(full)
        bdir = os.path.join(pdir, "Backup")
        if os.path.isdir(bdir):
            for dp, _, fns in os.walk(bdir):
                for name in fns:
                    if os.path.splitext(name)[1].lower() in REF_EXTS:
                        pr.backups.append(os.path.join(dp, name))
        projects[pdir] = pr
        all_ref_files.extend(pr.sets)
        all_ref_files.extend(pr.backups)

    if not quiet:
        print(f"Reading {len(all_ref_files)} Live Sets across "
              f"{len(project_dirs)} projects...", file=sys.stderr)

    # Parse every reference file in parallel - this is the expensive part.
    parsed: dict[str, tuple[set[str], set[str]]] = {}
    if progress:
        progress("Reading Live Sets", 0, len(all_ref_files))
    with ProcessPoolExecutor(max_workers=workers) as pool:
        done = 0
        worker = functools.partial(extract_refs, deep=deep)
        for path, abs_paths, names in pool.map(worker, all_ref_files, chunksize=4):
            parsed[path] = (abs_paths, names)
            done += 1
            if not quiet and done % 100 == 0:
                print(f"  {done}/{len(all_ref_files)}", end="\r", file=sys.stderr)
            if progress and (done % 25 == 0 or done == len(all_ref_files)):
                progress("Reading Live Sets", done, len(all_ref_files))

    # Global indexes: a sample referenced by ANY set anywhere is never an orphan,
    # even if it physically lives in a different project's folder.
    global_set_paths: set[str] = set()
    global_set_names: set[str] = set()
    global_backup_paths: set[str] = set()
    global_backup_names: set[str] = set()
    for pr in projects.values():
        for a in pr.sets:
            p, n = parsed.get(a, (set(), set()))
            global_set_paths |= p
            global_set_names |= n
        if not ignore_backups:
            for a in pr.backups:
                p, n = parsed.get(a, (set(), set()))
                global_backup_paths |= p
                global_backup_names |= n

    # Assign every audio file to its nearest enclosing project folder.
    sorted_dirs = sorted(project_dirs, key=len, reverse=True)

    def owner(path: str) -> str | None:
        for d in sorted_dirs:
            if path.startswith(d + os.sep):
                return d
        return None

    if progress:
        progress("Checking samples", 0, len(project_dirs))
    for pi, pdir in enumerate(project_dirs):
        if progress and pi % 10 == 0:
            progress("Checking samples", pi, len(project_dirs))
        pr = projects[pdir]
        own_paths, own_names = set(), set()
        for a in pr.sets:
            p, n = parsed.get(a, (set(), set()))
            own_paths |= p
            own_names |= n
        own_backup_paths, own_backup_names = set(), set()
        for a in pr.backups:
            p, n = parsed.get(a, (set(), set()))
            own_backup_paths |= p
            own_backup_names |= n

        asd_pending: list[tuple[str, str, int]] = []
        seen_audio: dict[str, str] = {}

        for dp, dirnames, filenames in os.walk(pdir):
            dirnames[:] = [d for d in dirnames if not d.startswith(".")]
            if os.path.basename(dp) == "Backup":
                dirnames[:] = []
                continue
            for name in filenames:
                full = os.path.join(dp, name)
                if owner(full) != pdir:
                    continue  # belongs to a nested project
                ext = os.path.splitext(name)[1].lower()
                if ext == ".asd":
                    try:
                        asd_pending.append((full, name, os.path.getsize(full)))
                    except OSError:
                        pass
                    continue
                if ext not in AUDIO_EXTS:
                    continue
                try:
                    size = os.path.getsize(full)
                except OSError:
                    continue

                abs_norm, base = nfc(full), nfc(name)
                if abs_norm in own_paths or base in own_names:
                    status = "used"
                elif abs_norm in global_set_paths or base in global_set_names:
                    status = "used-elsewhere"
                elif (abs_norm in own_backup_paths or base in own_backup_names
                      or abs_norm in global_backup_paths or base in global_backup_names):
                    status = "backup-only"
                else:
                    status = "orphan"

                rel = os.path.relpath(full, pdir)
                bucket = bucket_for(rel)
                rec = FileRecord(full, rel, size, status, bucket, pdir)
                rec.reclaimable = (
                    status == "orphan"
                    and (bucket != "unmanaged" or include_loose)
                )
                pr.files.append(rec)
                seen_audio[base] = status

        # .asd analysis files inherit their sample's verdict. If the sample is
        # gone entirely the .asd is dead weight on its own.
        for full, name, size in asd_pending:
            parent = nfc(name[:-4])  # 'Foo.wav.asd' -> 'Foo.wav'
            status = seen_audio.get(parent)
            rel = os.path.relpath(full, pdir)
            bucket = bucket_for(rel)
            if status is None:
                rec = FileRecord(full, rel, size, "stray-asd", bucket, pdir)
                rec.reclaimable = bucket != "unmanaged" or include_loose
            else:
                rec = FileRecord(full, rel, size, status, bucket, pdir)
                rec.reclaimable = (
                    status == "orphan" and (bucket != "unmanaged" or include_loose)
                )
            pr.files.append(rec)

    stats = summarize(list(projects.values()))
    stats.update({
        "root": root, "projects": len(project_dirs),
        "live_sets": sum(len(p.sets) for p in projects.values()),
        "backup_sets": sum(len(p.backups) for p in projects.values()),
        "seconds": round(time.time() - t0, 1),
        "include_loose": include_loose, "ignore_backups": ignore_backups,
        "deep": deep,
    })
    return list(projects.values()), stats


def apply_only_filter(projects: list[Project], pattern: str) -> int:
    """Narrow what may be acted on, without narrowing what was scanned.

    Scanning wide is what keeps 'used-elsewhere' meaningful, so the filter is
    applied to the reclaimable flag afterwards rather than to the walk.
    """
    needle = pattern.lower()
    matched = 0
    for pr in projects:
        if needle in pr.dir.lower():
            matched += 1
        else:
            for f in pr.files:
                f.reclaimable = False
    return matched


def summarize(projects: list[Project]) -> dict:
    by_status: dict[str, list[int]] = {}
    by_bucket: dict[str, list[int]] = {}
    recl_n = recl_b = 0
    for pr in projects:
        for f in pr.files:
            s = by_status.setdefault(f.status, [0, 0])
            s[0] += 1
            s[1] += f.size
            if f.reclaimable:
                recl_n += 1
                recl_b += f.size
                b = by_bucket.setdefault(f.bucket, [0, 0])
                b[0] += 1
                b[1] += f.size
    return {
        "by_status": {k: {"files": v[0], "bytes": v[1]} for k, v in by_status.items()},
        "reclaimable_by_bucket": {k: {"files": v[0], "bytes": v[1]}
                                  for k, v in by_bucket.items()},
        "reclaimable_files": recl_n, "reclaimable_bytes": recl_b,
    }


def human(n: float) -> str:
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(n) < 1024:
            return f"{n:.1f}{unit}" if unit != "B" else f"{int(n)}B"
        n /= 1024
    return f"{n:.1f}PB"


STATUS_HELP = {
    "used": "referenced by this project's Live Set",
    "used-elsewhere": "referenced by a different project's Set",
    "backup-only": "only referenced by files in Backup/",
    "orphan": "referenced by nothing",
    "stray-asd": "analysis file whose sample is gone",
}


def print_report(projects: list[Project], stats: dict, top: int = 20) -> None:
    print()
    print(f"  Root      {stats['root']}")
    print(f"  Scanned   {stats['projects']} projects, {stats['live_sets']} Live Sets, "
          f"{stats['backup_sets']} backups  ({stats['seconds']}s)")
    print()
    print("  STATUS           FILES        SIZE   MEANING")
    order = ["used", "used-elsewhere", "backup-only", "orphan", "stray-asd"]
    for st in order:
        d = stats["by_status"].get(st)
        if not d:
            continue
        print(f"  {st:<15} {d['files']:>6} {human(d['bytes']):>11}   {STATUS_HELP[st]}")
    print()
    print(f"  RECLAIMABLE      {stats['reclaimable_files']:>6} "
          f"{human(stats['reclaimable_bytes']):>11}")
    if stats["reclaimable_by_bucket"]:
        for b, d in sorted(stats["reclaimable_by_bucket"].items(),
                           key=lambda kv: -kv[1]["bytes"]):
            print(f"      {b:<24} {d['files']:>6} {human(d['bytes']):>11}")
    print()

    rows = []
    for pr in projects:
        n = sum(1 for f in pr.files if f.reclaimable)
        b = sum(f.size for f in pr.files if f.reclaimable)
        if n:
            rows.append((b, n, pr.dir))
    rows.sort(reverse=True)
    if rows:
        print(f"  TOP {min(top, len(rows))} PROJECTS BY RECLAIMABLE SPACE")
        root = stats["root"]
        for b, n, d in rows[:top]:
            name = os.path.relpath(d, root)
            print(f"      {human(b):>9}  {n:>4} files   {name}")
        print()

    if not stats["include_loose"]:
        loose = sum(f.size for pr in projects for f in pr.files
                    if f.status == "orphan" and f.bucket == "unmanaged")
        ln = sum(1 for pr in projects for f in pr.files
                 if f.status == "orphan" and f.bucket == "unmanaged")
        if ln:
            print(f"  Held back: {ln} unreferenced files ({human(loose)}) sit outside "
                  f"Samples/ -")
            print(f"  often bounces, masters or stems. Use --include-loose to count them.")
            print()


def write_csv(projects: list[Project], path: str) -> None:
    with open(path, "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["status", "reclaimable", "bytes", "bucket", "project", "relative_path", "full_path"])
        for pr in projects:
            for f in pr.files:
                w.writerow([f.status, int(f.reclaimable), f.size, f.bucket,
                            pr.dir, f.rel, f.path])


def write_json(projects: list[Project], stats: dict, path: str) -> None:
    payload = {
        "tool": "alsorphan", "version": VERSION, "stats": stats,
        "projects": [
            {"dir": pr.dir, "sets": pr.sets, "backups": pr.backups,
             "files": [asdict(f) for f in pr.files]}
            for pr in projects
        ],
    }
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=1)


def write_html(projects: list[Project], stats: dict, path: str) -> None:
    e = html.escape
    rows = []
    for pr in projects:
        n = sum(1 for f in pr.files if f.reclaimable)
        b = sum(f.size for f in pr.files if f.reclaimable)
        if n:
            rows.append((b, n, pr))
    rows.sort(key=lambda r: -r[0])

    parts = [
        "<!doctype html><meta charset='utf-8'><title>Orphaned samples</title>",
        "<style>",
        "body{font:14px/1.5 -apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;",
        "margin:0;padding:2rem;background:#101114;color:#e8e8ea}",
        "h1{font-size:1.4rem;margin:0 0 .25rem}",
        ".sub{color:#8b8d96;margin-bottom:1.5rem}",
        ".big{font-size:2.6rem;font-weight:600;color:#7dd3a0}",
        "details{border:1px solid #26272e;border-radius:8px;margin:.4rem 0;background:#16171b}",
        "summary{padding:.6rem .8rem;cursor:pointer;display:flex;gap:1rem;align-items:baseline}",
        "summary strong{flex:1}",
        ".sz{color:#7dd3a0;font-variant-numeric:tabular-nums}",
        "table{width:100%;border-collapse:collapse;font-size:13px}",
        "td{padding:.25rem .8rem;border-top:1px solid #26272e;color:#b9bac2}",
        "td.n{text-align:right;font-variant-numeric:tabular-nums;color:#8b8d96;white-space:nowrap}",
        "</style>",
        f"<h1>Orphaned samples</h1><div class='sub'>{e(stats['root'])} &middot; "
        f"{stats['projects']} projects &middot; {stats['live_sets']} Live Sets</div>",
        f"<div class='big'>{human(stats['reclaimable_bytes'])}</div>"
        f"<div class='sub'>reclaimable across {stats['reclaimable_files']} files</div>",
    ]
    for b, n, pr in rows:
        name = os.path.relpath(pr.dir, stats["root"])
        parts.append(f"<details><summary><strong>{e(name)}</strong>"
                     f"<span class='sz'>{human(b)}</span>"
                     f"<span style='color:#8b8d96'>{n} files</span></summary><table>")
        for f in sorted((f for f in pr.files if f.reclaimable), key=lambda f: -f.size):
            parts.append(f"<tr><td>{e(f.rel)}</td><td class='n'>{human(f.size)}</td></tr>")
        parts.append("</table></details>")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(parts))


def do_quarantine(projects: list[Project], stats: dict, dest: str, apply: bool) -> None:
    targets = [f for pr in projects for f in pr.files if f.reclaimable]
    if not targets:
        print("Nothing to quarantine.")
        return
    total = sum(f.size for f in targets)
    stamp = time.strftime("%Y-%m-%d %H%M%S")
    qdir = os.path.join(dest, f"Orphan Quarantine {stamp}")

    if not apply:
        print(f"\n  DRY RUN - nothing moved.")
        print(f"  Would move {len(targets)} files ({human(total)}) to:")
        print(f"      {qdir}")
        print(f"\n  Re-run with --apply to move them.\n")
        return

    root = stats["root"]
    moved = []
    os.makedirs(qdir, exist_ok=True)
    for f in targets:
        rel = os.path.relpath(f.path, root)
        target = os.path.join(qdir, rel)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        try:
            shutil.move(f.path, target)
            moved.append({"from": f.path, "to": target, "bytes": f.size})
        except Exception as exc:
            print(f"  skipped {f.path}: {exc}", file=sys.stderr)
    manifest = os.path.join(qdir, "_manifest.json")
    with open(manifest, "w", encoding="utf-8") as fh:
        json.dump({"tool": "alsorphan", "version": VERSION, "root": root,
                   "created": stamp, "moved": moved}, fh, indent=1)
    print(f"\n  Moved {len(moved)} files ({human(sum(m['bytes'] for m in moved))})")
    print(f"      {qdir}")
    print(f"\n  Nothing was deleted. Open your projects, confirm all is well,")
    print(f"  then delete that folder yourself - or undo with:")
    print(f"      alsorphan restore \"{manifest}\"\n")


def do_restore(manifest_path: str) -> None:
    with open(manifest_path, encoding="utf-8") as fh:
        data = json.load(fh)
    back = 0
    for m in data["moved"]:
        if not os.path.exists(m["to"]):
            continue
        os.makedirs(os.path.dirname(m["from"]), exist_ok=True)
        shutil.move(m["to"], m["from"])
        back += 1
    print(f"Restored {back} of {len(data['moved'])} files to their original locations.")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(
        prog="alsorphan",
        description="Find sample files sitting in Ableton project folders that "
                    "no Live Set actually uses.")
    sub = ap.add_subparsers(dest="cmd", required=True)

    def common(p):
        p.add_argument("root", help="folder containing your Ableton projects")
        p.add_argument("--include-loose", action="store_true",
                       help="also count unreferenced audio outside Samples/ "
                            "(bounces, masters - off by default)")
        p.add_argument("--ignore-backups", action="store_true",
                       help="treat samples referenced only by Backup/ sets as orphans")
        p.add_argument("--only", metavar="PATTERN", default=None,
                       help="restrict the reclaimable set to projects whose "
                            "path contains PATTERN (case-insensitive). Scanning "
                            "still covers the whole root, so cross-project "
                            "references are still respected.")
        p.add_argument("--deep", action="store_true",
                       help="also search third-party plugin state for sample "
                            "names (slower, safer if you use sampler VSTs)")
        p.add_argument("-j", "--workers", type=int, default=None)
        p.add_argument("-q", "--quiet", action="store_true")

    s = sub.add_parser("scan", help="report only, change nothing")
    common(s)
    s.add_argument("--csv", metavar="FILE")
    s.add_argument("--json", metavar="FILE")
    s.add_argument("--html", metavar="FILE")
    s.add_argument("--top", type=int, default=20)

    q = sub.add_parser("quarantine", help="move orphans aside (reversible)")
    common(q)
    q.add_argument("--dest", default=None,
                   help="where to put the quarantine folder (default: root)")
    q.add_argument("--apply", action="store_true",
                   help="actually move files; without this it is a dry run")

    r = sub.add_parser("restore", help="undo a quarantine from its manifest")
    r.add_argument("manifest", help="path to _manifest.json")

    args = ap.parse_args(argv)

    if args.cmd == "restore":
        do_restore(args.manifest)
        return 0

    root = os.path.realpath(os.path.expanduser(args.root))
    if not os.path.isdir(root):
        print(f"Not a folder: {root}", file=sys.stderr)
        return 2

    projects, stats = scan(root, include_loose=args.include_loose,
                           ignore_backups=args.ignore_backups, deep=args.deep,
                           workers=args.workers, quiet=args.quiet)
    if not projects:
        print(f"No Ableton projects (.als files) found under {root}")
        return 1

    if args.only:
        matched = apply_only_filter(projects, args.only)
        if not matched:
            print(f"--only {args.only!r} matched no project under {root}",
                  file=sys.stderr)
            return 1
        stats.update(summarize(projects))
        stats["only"] = args.only
        stats["only_matched"] = matched
        if not args.quiet:
            print(f"\n  Filter: --only {args.only!r} -> {matched} project(s). "
                  f"Everything else was scanned but is off limits.")

    if args.cmd == "scan":
        if not args.quiet:
            print_report(projects, stats, top=args.top)
        if args.csv:
            write_csv(projects, args.csv)
            print(f"  CSV   {args.csv}")
        if args.json:
            write_json(projects, stats, args.json)
            print(f"  JSON  {args.json}")
        if args.html:
            write_html(projects, stats, args.html)
            print(f"  HTML  {args.html}")
        return 0

    print_report(projects, stats, top=args.top if hasattr(args, "top") else 10)
    do_quarantine(projects, stats, args.dest or root, args.apply)
    return 0


if __name__ == "__main__":
    sys.exit(main())
