#!/usr/bin/env python3
"""Write windows/build/file_version_info.txt for PyInstaller from windows/VERSION.

This becomes the exe's Windows version resource: what Explorer's Properties >
Details tab shows, and what SmartScreen / Defender report as the publisher and
product. Run before `pyinstaller`.
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
WIN = os.path.abspath(os.path.join(HERE, ".."))

version = open(os.path.join(WIN, "VERSION"), encoding="utf-8").read().strip()
parts = [int(p) for p in version.split(".")] + [0] * 4
nums = tuple(parts[:4])

text = f"""# UTF-8
VSVersionInfo(
  ffi=FixedFileInfo(
    filevers={nums},
    prodvers={nums},
    mask=0x3f,
    flags=0x0,
    OS=0x40004,
    fileType=0x1,
    subtype=0x0,
    date=(0, 0)
  ),
  kids=[
    StringFileInfo([
      StringTable(
        '040904B0',
        [StringStruct('CompanyName', 'Sound Decisions LLC'),
         StringStruct('FileDescription', 'Sample Sweep'),
         StringStruct('FileVersion', '{version}'),
         StringStruct('InternalName', 'Sample Sweep'),
         StringStruct('LegalCopyright', 'Sound Decisions LLC'),
         StringStruct('OriginalFilename', 'Sample Sweep.exe'),
         StringStruct('ProductName', 'Sample Sweep'),
         StringStruct('ProductVersion', '{version}')])
    ]),
    VarFileInfo([VarStruct('Translation', [1033, 1200])])
  ]
)
"""
os.makedirs(os.path.join(WIN, "build"), exist_ok=True)
out = os.path.join(WIN, "build", "file_version_info.txt")
with open(out, "w", encoding="utf-8") as fh:
    fh.write(text)
print(f"wrote {out} for {version}")
sys.exit(0)
