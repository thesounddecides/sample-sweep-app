"""Sample Sweep for Windows - entry point.

    python windows/SampleSweep.py [folder]      run the app (any OS with Tk)
    python windows/SampleSweep.py --preview-windows [folder]
                                                same, with the Windows wording
                                                (Explorer, Recycle Bin, Documents/Ableton)
                                                so the copy can be proofread on a Mac
    python windows/SampleSweep.py --selftest [out.json]
    python windows/SampleSweep.py --version

Built into "Sample Sweep.exe" by windows/SampleSweep.spec. Keep this file tiny:
under PyInstaller the frozen exe re-executes itself for every worker process in
the scan pool, so anything at module level runs once per worker.
"""

import multiprocessing
import os
import sys


def _quiet_stdio() -> None:
    """A windowed (no-console) exe has no stdout/stderr; make print() a no-op
    rather than an AttributeError."""
    for name in ("stdout", "stderr"):
        if getattr(sys, name) is None:
            setattr(sys, name, open(os.devnull, "w", encoding="utf-8"))


def main() -> int:
    multiprocessing.freeze_support()          # MUST be first: worker re-entry
    _quiet_stdio()
    if not getattr(sys, "frozen", False):
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

    args = sys.argv[1:]
    if "--preview-windows" in args:
        args.remove("--preview-windows")
        os.environ["SAMPLESWEEP_PREVIEW_WINDOWS"] = "1"

    from samplesweep_win import core
    if args and args[0] == "--version":
        print(f"Sample Sweep {core.VERSION}")
        return 0
    if args and args[0] == "--selftest":
        import json
        import traceback
        out_path = args[1] if len(args) > 1 else None
        try:
            summary = core.selftest()
            payload = {"ok": True, **summary}
            code = 0
        except Exception:  # noqa: BLE001
            payload = {"ok": False, "error": traceback.format_exc()}
            code = 1
        text = json.dumps(payload, indent=2)
        print(text)
        if out_path:
            with open(out_path, "w", encoding="utf-8") as fh:
                fh.write(text)
        return code

    from samplesweep_win.gui import run
    initial = args[0] if args and os.path.isdir(args[0]) else os.environ.get("SAMPLESWEEP_ROOT")
    return run(initial)


if __name__ == "__main__":
    sys.exit(main())
