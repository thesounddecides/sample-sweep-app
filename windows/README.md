# Sample Sweep for Windows

The Mac app is SwiftUI, which does not exist on Windows. The engine, though,
exists twice in this repo: once in Swift (`Sources/SweepCore`) and once in
Python (`reference/alsorphan.py`, the oracle the Swift engine is diffed
against). The Python one is standard-library only, already path-separator
clean, and already implements move + manifest + restore. So the Windows app
is that engine plus a small native-looking window, frozen into an `.exe` and
wrapped in an installer. One engine, two shells, no third copy of the
classification logic.

```
windows/
  SampleSweep.py            entry point (python windows/SampleSweep.py runs it on any OS with Tk)
  samplesweep_win/core.py   engine facade: imports the oracle, applies the Mac app's
                            keep/reclaim rule, writes the Mac app's sweep folder + manifest,
                            rename-resilient restore, Ableton-running check, self-test fixture
  samplesweep_win/gui.py    the window (Tkinter/ttk): welcome -> scan -> results -> move -> done
  SampleSweep.spec          PyInstaller: one-folder, windowed, no UPX, version resource
  installer.iss             Inno Setup 6: per-user install, Start Menu + optional desktop icon
  VERSION                   single version source for the Windows build (must equal the Mac's)
  assets/                   .ico + PNGs generated from Tools/SampleSweep.icns and the SD lockup
  tools/make_version_info.py   VERSION -> Windows version resource for the exe
  tools/parity_check.py        diff this engine against sweepcheck, file by file
.github/workflows/windows-build.yml   builds + self-tests + packages on a Windows runner
```

## How a build happens

No Windows machine is needed. The workflow runs on a GitHub-hosted Windows
runner and produces a downloadable artifact.

1. Push a change under `windows/` or `reference/` to `main`, **or** open
   Actions → *Windows build* → *Run workflow*.
2. ~5 minutes later the run has an artifact named
   `SampleSweep-Setup-<version>-windows-unsigned` (or `-signed`, see below)
   containing `SampleSweep-Setup-<version>.exe`, its `.sha256`, and
   `selftest.json`.
3. Download the artifact zip (needs a GitHub login with access to this
   private repo), unzip, and hand the `.exe` to the tester. For anything
   beyond one tester, upload it to R2 alongside the dmg:
   `npx wrangler r2 object put composure-dl/SampleSweep-Setup-<version>.exe --file ...`
   (same bucket and convention as `release.sh` prints for the dmg).

Windows runner minutes bill at 2× on the free plan; a build is roughly 10
billed minutes. Runs only trigger on changes to the Windows side, or by hand.

What the workflow checks before it will hand you an installer:

- **Version guard.** `windows/VERSION` must equal `CFBundleShortVersionString`
  in `build-app.sh`, or the build fails. One product, one version. Bump both.
- **Engine self-test, unfrozen.** `python windows/SampleSweep.py --selftest`
  builds a synthetic Ableton library, scans it with the app's defaults, checks
  every file's verdict, flips each option, moves the reclaimable files, renames
  the sweep folder, restores, restores again. Any mismatch fails the build.
- **Engine self-test, frozen.** The same test is run through the packaged
  `Sample Sweep.exe --selftest`. This is the one that matters: PyInstaller
  builds re-execute the exe for every worker in the scan pool, and that path
  (`multiprocessing.freeze_support()` first thing in `SampleSweep.py`) is the
  classic way a frozen Python app explodes into infinite copies of itself. The
  macOS equivalent was built and run here before the workflow was written, and
  it passes.

### Parity with the Mac app

The Windows build must give exactly the Mac app's verdicts, so there is a
harness for that, same spirit as the README's "Validating the engine":

```bash
swift build -c release --product sweepcheck
python3 windows/tools/parity_check.py ~/Music/Ableton
```

It runs `sweepcheck --app-defaults` (the Swift engine, app defaults) and
`core.scan` (this engine, app defaults) over the same root and diffs status,
reclaimable and size per path. Last run 2026-08-19 on the real library: 5,297
files, zero mismatches, identical reclaimable bytes. Run it again after any
change to either engine.

Note for anyone editing the oracle: `alsorphan.scan()` grew one optional
`progress` callback for the GUI's progress bar. No behaviour change when it is
not passed; the CLI never passes it.

### Running or building by hand

- From source, any OS with Tk: `python3 windows/SampleSweep.py [folder]`.
- **Proofread the Windows copy on a Mac:** `python3 windows/SampleSweep.py --preview-windows [folder]`
  swaps in the Windows wording (Explorer, Recycle Bin, `Documents\Ableton`) while
  behaviour stays native to the Mac. The title bar says "(Windows wording preview)".
  `core.WINDOWS_WORDING` / `FILE_MANAGER` / `TRASH_NAME` are the only place that
  copy is decided; anything OS-specific in the UI must go through them.
- A throwaway test library to click around in without touching real projects:
  `python3 -c "import sys; sys.path.insert(0,'windows'); from samplesweep_win import core; print(core.selftest(keep=True)['root'])"`
  prints a temp folder with two projects, three reclaimable files, one held back
  loose file and one held back bounce. Scan it, move, rename, put back.
- **To run the actual Windows installer on a Mac** you need Windows: the quickest
  faithful route is a Windows 11 ARM VM (Parallels trial installs one in ~15 min;
  UTM is free but slower to set up). The installer is x64 and runs under Windows'
  built-in x64 emulation on ARM, which is why `installer.iss` allows
  `x64compatible`. Wine/CrossOver can *start* the exe but is not a faithful test
  of SmartScreen, Defender or the per-user install, so don't validate with it.
- On a Windows machine: `pip install "pyinstaller>=6.10,<7"`, then
  `python windows\tools\make_version_info.py`,
  `pyinstaller windows\SampleSweep.spec --noconfirm --distpath windows\build\dist --workpath windows\build\work`,
  then `ISCC.exe /DMyAppVersion=<version> windows\installer.iss` (Inno Setup 6).
  Output lands in `windows\build\`, which is gitignored.

## Handing it to the tester

What the tester will see with an **unsigned** build — this is expected, not
a bug, and is exactly what the signing work below removes:

- The browser may warn on download ("isn't commonly downloaded").
- Running the installer shows SmartScreen's blue "Windows protected your PC"
  panel. **More info → Run anyway.** Publisher reads "Unknown publisher".
- Windows Defender may pause a few seconds on first launch to scan the
  folder. PyInstaller apps occasionally trip antivirus heuristics; the
  one-folder, no-UPX build here is the configuration least likely to, but if
  a third-party AV quarantines it, that is useful feedback in itself.
- The installer needs no admin rights. It installs to
  `%LOCALAPPDATA%\Programs\Sample Sweep`, adds a Start Menu entry and an
  optional desktop icon, and shows up in *Apps → Installed apps* with an
  uninstaller.

What to ask them to test (mirrors the Mac what-to-test list):

1. Install, launch from the Start Menu. Welcome screen, Sound Decisions mark
   opens the site.
2. *Choose Your Ableton Folder…* — the picker should open at
   `Documents\Ableton`. Pick their whole Ableton folder.
3. Progress runs through "Finding projects / Reading Live Sets / Checking
   samples". Note how long a full scan takes and how many files.
4. Results: the big number, the held-back line, Options (each toggle
   rescans), expand a project, tick/untick files, right-click → Show in
   Explorer on a file and on a project.
5. If Ableton is open, the orange banner shows. Quit Ableton, rescan, it goes.
6. *Move Files Aside…* to a folder on the Desktop. Check the created
   `Sample Sweep <date>` folder: mirrored structure, `Put These Files Back.json`,
   `READ ME.txt`. Open the projects in Live and confirm they load.
7. Rename that folder, move it somewhere else, then File → *Put Files Back…*
   and pick it. Everything must return; rescan shows the same files again.
8. Uninstall from *Installed apps*; nothing left behind in `%LOCALAPPDATA%\Programs`.

Ask for: Windows version, whether Defender or another AV said anything and
what, scan time and file count, screenshots of anything that looked off, and
the `READ ME.txt` / manifest from their sweep folder if something did not
restore.

## Signing — next steps (Windows' equivalent of notarization)

Decision of record (Notion → 🚦 Distribution & Code-Signing Readiness, §4):
**Azure Artifact Signing** (Microsoft renamed Trusted Signing in 2025),
organisation identity, not an EV token. EV stopped buying SmartScreen
reputation in 2024; OV-level trust from Artifact Signing is the right spend
at ~$10/month.

Everything below is already wired into the workflow. It switches from
`-unsigned` to `-signed` artifacts by itself the moment the secrets exist.

1. **Azure.** A pay-as-you-go subscription under Sound Decisions LLC (the
   service refuses free/trial/sponsored subscriptions, and the billing account
   type must be Organization to match the identity validation).
2. **Create the signing account.** Azure portal → *Artifact Signing* (search
   "Trusted Signing" if the old name still shows) → create account, Basic SKU,
   region `EastUS` or `WestUS2`. Note the account name and the region's
   endpoint, e.g. `https://eus.codesigning.azure.net`.
3. **Identity validation.** Inside the account → *Identity validation* →
   *Organization*, legal name "Sound Decisions LLC", Colorado, EIN, the
   website. They verify the business and a contact; hours to a few days.
   This is the step that makes the publisher read "Sound Decisions LLC".
4. **Certificate profile.** *Certificate profiles* → new → *Public Trust*,
   linked to the validated identity. Note the profile name.
5. **A service principal for CI.** Microsoft Entra → App registrations → new
   app "samplesweep-ci" → create a client secret (note its expiry, calendar
   it like the Apple cert). On the signing account → *Access control (IAM)*
   → assign the app the role **Trusted Signing Certificate Profile Signer**.
6. **Repo secrets** (Settings → Secrets and variables → Actions):
   `AZURE_TENANT_ID`, `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`,
   `SIGNING_ENDPOINT`, `SIGNING_ACCOUNT`, `SIGNING_PROFILE`.
7. **Re-run the workflow.** The app exe is signed before packaging, the
   installer after. Verify on any Windows box: right-click the setup exe →
   Properties → *Digital Signatures* shows Sound Decisions LLC, timestamped;
   or `signtool verify /pa /v SampleSweep-Setup-<v>.exe`.

Still to do once signing is on, in order:

- **Sign the uninstaller too.** Inno builds it at compile time, so it needs
  Inno's own `SignTool` hook rather than the post-step. Install the Artifact
  Signing `signtool` dlib on the runner and pass
  `ISCC /S"ast=signtool.exe sign /v /fd SHA256 /tr http://timestamp.acs.microsoft.com /td SHA256 /dlib <path>\Azure.CodeSigning.Dlib.dll /dmdf <metadata.json> $f" /DSignTool=ast`
  — `installer.iss` already reads the `SignTool` define and turns on
  `SignedUninstaller`.
- **SmartScreen reputation is earned, not bought.** A freshly signed
  publisher still shows the warning until enough downloads accrue; the panel
  just says "Sound Decisions LLC" instead of "Unknown publisher" and clears
  far sooner. Normal. Do not switch identities later: that resets it.
- **Publish.** Add a `downloadUrlWindows` to the newest entry in
  `sounddecides-web/src/data/sample-sweep-releases.json`, upload the exe to
  R2, and let `/sample-sweep` offer the right file per platform (the page
  currently assumes the dmg). Same ordering rule as the Mac: upload first, the
  site deploy is the announce moment.

## Known differences from the Mac app

- Checkboxes in the results list are glyphs (☐ ☑ ▣) in a ttk tree, not native
  controls; click the glyph or the name to toggle, click the triangle to expand.
- "Show in Finder" is a right-click item here rather than a per-row button.
- Defaults, verdicts, folder layout, manifest and note are identical, so a
  folder swept on Windows can be put back on a Mac and vice versa. The Mac
  app already accepts the old CLI manifest name; this one does too.
- The Windows app has a File menu (Scan a Folder… Ctrl+O, Put Files Back…
  Ctrl+Shift+Z) and a Help menu (About, website).
