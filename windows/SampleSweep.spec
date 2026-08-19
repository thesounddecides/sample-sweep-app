# -*- mode: python ; coding: utf-8 -*-
"""PyInstaller spec for Sample Sweep (Windows).

    pyinstaller windows/SampleSweep.spec --noconfirm \
        --distpath windows/build/dist --workpath windows/build/work

One-folder build, not one-file: it starts faster, and the worker processes the
scan pool spawns don't each unpack a temp copy. Antivirus heuristics are also
far less twitchy about one-folder builds. The installer hides the folder anyway.
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(SPEC))          # windows/
REPO = os.path.abspath(os.path.join(HERE, ".."))
IS_WIN = sys.platform.startswith("win")

datas = [
    (os.path.join(HERE, "assets", "SampleSweep.ico"), "assets"),
    (os.path.join(HERE, "assets", "SampleSweep-96.png"), "assets"),
    (os.path.join(HERE, "assets", "sd-logo-light-36.png"), "assets"),
    (os.path.join(HERE, "assets", "sd-logo-dark-36.png"), "assets"),
    (os.path.join(HERE, "VERSION"), "."),
]

version_file = os.path.join(HERE, "build", "file_version_info.txt")
if not os.path.exists(version_file):
    version_file = None

a = Analysis(
    [os.path.join(HERE, "SampleSweep.py")],
    pathex=[HERE, os.path.join(REPO, "reference")],    # samplesweep_win + alsorphan
    binaries=[],
    datas=datas,
    hiddenimports=["alsorphan", "samplesweep_win.core", "samplesweep_win.gui"],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=["unittest", "pydoc", "doctest", "xmlrpc", "test", "lib2to3",
              "setuptools", "pip", "email", "http", "ssl", "_ssl", "sqlite3", "_sqlite3",
              "curses", "asyncio", "logging.config", "distutils", "tkinter.test"],
    noarchive=False,
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name="Sample Sweep",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,                       # UPX-packed exes are a classic AV false-positive trigger
    console=False,                   # GUI subsystem: no console window
    disable_windowed_traceback=False,
    icon=os.path.join(HERE, "assets", "SampleSweep.ico") if IS_WIN else None,
    version=version_file,            # Windows version resource (publisher, product, version)
)
coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=False,
    name="Sample Sweep",
)
