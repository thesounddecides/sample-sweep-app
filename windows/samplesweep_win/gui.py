"""Sample Sweep for Windows - the window.

A Tkinter/ttk port of the Mac app's flow (Sources/SampleSweep):
welcome -> scanning -> results -> moving -> done, plus Put Files Back.
The engine is `core`; nothing in here classifies, moves or restores.
"""

from __future__ import annotations

import os
import queue
import sys
import threading
import tkinter as tk
import tkinter.font as tkfont
from tkinter import filedialog, messagebox, ttk

from . import core

ASSETS = os.path.join(getattr(sys, "_MEIPASS", os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")), "assets")

GREEN = "#1d8a4b"
ORANGE = "#b35c00"
ORANGE_BG = "#fdf1e2"
MUTED = "#6b6f76"

CHECKED, UNCHECKED, PARTIAL = "☑", "☐", "▣"   # ☑ ☐ ▣


def _asset(name: str) -> str:
    return os.path.join(ASSETS, name)


class App(tk.Tk):
    def __init__(self, initial_root: str | None = None) -> None:
        super().__init__()
        self.withdraw()
        self.title(core.TOOL_NAME + ("  (Windows wording preview)" if core.WINDOWS_WORDING and not core.IS_WINDOWS else ""))
        self.minsize(820, 560)
        self.geometry("960x660")
        self._set_icon()
        self._fonts()
        self._style()

        self.root_path: str | None = None
        self.options = core.Options()
        self.result: core.SweepResult | None = None
        self.selected: set[str] = set()
        self.ableton_running = False
        self.last_sweep_folder: str | None = None
        self._events: queue.Queue = queue.Queue()
        self._photos: dict[str, tk.PhotoImage] = {}

        self._menubar()
        self.container = ttk.Frame(self)
        self.container.pack(fill="both", expand=True)
        self.current: tk.Widget | None = None

        self.protocol("WM_DELETE_WINDOW", self.destroy)
        self.after(80, self._poll)
        self.deiconify()
        if initial_root and os.path.isdir(initial_root):
            self.start_scan(initial_root)
        else:
            self.show_welcome()

    # ----- chrome ----------------------------------------------------------

    def _set_icon(self) -> None:
        try:
            if core.IS_WINDOWS:
                self.iconbitmap(_asset("SampleSweep.ico"))
            else:
                self.iconphoto(True, self._photo("SampleSweep-96.png"))
        except Exception:  # noqa: BLE001
            pass

    def _photo(self, name: str) -> tk.PhotoImage:
        if name not in self._photos:
            self._photos[name] = tk.PhotoImage(file=_asset(name))
        return self._photos[name]

    def _fonts(self) -> None:
        base = tkfont.nametofont("TkDefaultFont")
        family = "Segoe UI" if core.IS_WINDOWS else base.actual("family")
        size = max(base.actual("size"), 10) if core.IS_WINDOWS else base.actual("size")
        for name in ("TkDefaultFont", "TkTextFont", "TkMenuFont", "TkHeadingFont"):
            tkfont.nametofont(name).configure(family=family, size=size)
        self.f_title = tkfont.Font(family=family, size=size + 18, weight="bold")
        self.f_big = tkfont.Font(family=family, size=size + 22, weight="bold")
        self.f_h2 = tkfont.Font(family=family, size=size + 6, weight="bold")
        self.f_h3 = tkfont.Font(family=family, size=size + 2)
        self.f_bold = tkfont.Font(family=family, size=size, weight="bold")
        self.f_small = tkfont.Font(family=family, size=max(size - 1, 8))
        self.f_mono_num = tkfont.Font(family=family, size=size)

    def _style(self) -> None:
        s = ttk.Style(self)
        if core.IS_WINDOWS and "vista" in s.theme_names():
            s.theme_use("vista")
        self.bg = s.lookup("TFrame", "background") or self.cget("background")
        s.configure("Muted.TLabel", foreground=MUTED)
        s.configure("Green.TLabel", foreground=GREEN)
        s.configure("Big.TLabel", foreground=GREEN, font=self.f_big)
        s.configure("Title.TLabel", font=self.f_title)
        s.configure("H2.TLabel", font=self.f_h2)
        s.configure("H3.TLabel", font=self.f_h3, foreground=MUTED)
        s.configure("Bold.TLabel", font=self.f_bold)
        s.configure("Small.TLabel", font=self.f_small, foreground=MUTED)
        s.configure("Accent.TButton", font=self.f_bold)
        line = tkfont.Font(font="TkDefaultFont").metrics("linespace")
        s.configure("Treeview", rowheight=line + 10)
        s.configure("Treeview.Heading", font=self.f_bold)

    def _menubar(self) -> None:
        m = tk.Menu(self)
        filem = tk.Menu(m, tearoff=0)
        filem.add_command(label="Scan a Folder…", accelerator="Ctrl+O", command=self.choose_folder)
        filem.add_command(label="Put Files Back…", accelerator="Ctrl+Shift+Z", command=self.undo_sweep)
        filem.add_separator()
        filem.add_command(label="Exit", command=self.destroy)
        m.add_cascade(label="File", menu=filem)
        helpm = tk.Menu(m, tearoff=0)
        helpm.add_command(label="About Sample Sweep", command=self.about)
        helpm.add_command(label="Sound Decisions website", command=core.open_site)
        m.add_cascade(label="Help", menu=helpm)
        self.config(menu=m)
        self.bind_all("<Control-o>", lambda e: self.choose_folder())
        self.bind_all("<Control-O>", lambda e: self.choose_folder())
        self.bind_all("<Control-Shift-Z>", lambda e: self.undo_sweep())
        self.bind_all("<Control-Shift-z>", lambda e: self.undo_sweep())

    def about(self) -> None:
        messagebox.showinfo("About Sample Sweep",
                            f"Sample Sweep {core.VERSION} for Windows\n\n"
                            "Finds the samples your Ableton projects no longer use, "
                            "and moves them aside. Nothing is ever deleted.\n\n"
                            "by Sound Decisions\nthesounddecides.com", parent=self)

    def _swap(self, widget: tk.Widget) -> None:
        if self.current is not None:
            self.current.destroy()
        self.current = widget
        widget.pack(fill="both", expand=True)

    # ----- phases ------------------------------------------------------------

    def show_welcome(self) -> None:
        f = ttk.Frame(self.container, padding=40)
        inner = ttk.Frame(f)
        inner.place(relx=0.5, rely=0.5, anchor="center")
        try:
            ttk.Label(inner, image=self._photo("SampleSweep-96.png")).pack(pady=(0, 12))
        except Exception:  # noqa: BLE001
            pass
        ttk.Label(inner, text="Sample Sweep", style="Title.TLabel").pack()
        self._sd_mark(inner).pack(pady=(10, 0))
        ttk.Label(inner, text="Find unused samples in your Ableton projects",
                  style="H3.TLabel").pack(pady=(12, 0))

        bullets = ttk.Frame(inner)
        bullets.pack(pady=(30, 0), anchor="w")
        for title, detail in (
            ("Reads every Live Set in a folder you choose",
             "Works out which samples each one actually uses."),
            ("Finds the leftovers",
             "Dead takes, freeze files from tracks you unfroze, old bounces and crops."),
            ("Never deletes anything",
             "Files are moved to a folder you pick, and one click puts them back."),
        ):
            row = ttk.Frame(bullets)
            row.pack(anchor="w", pady=5, fill="x")
            ttk.Label(row, text="●", style="Green.TLabel").pack(side="left", padx=(0, 12), anchor="n")
            txt = ttk.Frame(row)
            txt.pack(side="left", anchor="w")
            ttk.Label(txt, text=title, style="Bold.TLabel").pack(anchor="w")
            ttk.Label(txt, text=detail, style="Muted.TLabel").pack(anchor="w")

        ttk.Button(inner, text="Choose Your Ableton Folder…", style="Accent.TButton",
                   command=self.choose_folder, width=32).pack(pady=(34, 0), ipady=4)
        hint = "Documents\\Ableton" if core.WINDOWS_WORDING else "~/Music/Ableton"
        ttk.Label(inner, justify="center", style="Small.TLabel",
                  text=f"Usually {hint}. Pick the biggest folder you can. Sample Sweep\n"
                       "checks the other projects so it never flags a sample two of them share.").pack(pady=(14, 0))
        self._swap(f)

    def _dark_background(self) -> bool:
        try:
            r, g, b = (v / 65535 for v in self.winfo_rgb(self.bg))
            return (0.2126 * r + 0.7152 * g + 0.0722 * b) < 0.5
        except Exception:  # noqa: BLE001
            return False

    def _sd_mark(self, parent: tk.Widget) -> tk.Widget:
        logo = "sd-logo-dark-36.png" if self._dark_background() else "sd-logo-light-36.png"
        try:
            lbl = ttk.Label(parent, image=self._photo(logo), cursor="hand2")
        except Exception:  # noqa: BLE001
            lbl = ttk.Label(parent, text="by Sound Decisions", style="Muted.TLabel", cursor="hand2")
        lbl.bind("<Button-1>", lambda e: core.open_site())
        return lbl

    def show_scanning(self, root: str) -> None:
        f = ttk.Frame(self.container, padding=40)
        inner = ttk.Frame(f)
        inner.place(relx=0.5, rely=0.5, anchor="center")
        self.progress = ttk.Progressbar(inner, length=360, mode="indeterminate")
        self.progress.pack()
        self.progress.start(12)
        self.stage_label = ttk.Label(inner, text="Finding projects…")
        self.stage_label.pack(pady=(12, 0))
        ttk.Label(inner, text=_truncate_head(root, 70), style="Small.TLabel").pack(pady=(4, 0))
        self._swap(f)

    def show_results(self) -> None:
        r = self.result
        assert r is not None
        f = ttk.Frame(self.container)

        # Header
        head = ttk.Frame(f, padding=(22, 18, 22, 8))
        head.pack(fill="x")
        left = ttk.Frame(head)
        left.pack(side="left", anchor="w")
        ttk.Label(left, text=core.human_bytes(r.stats.reclaimable_bytes), style="Big.TLabel").pack(anchor="w")
        ttk.Label(left, style="Muted.TLabel",
                  text=f"{core.pluralized(r.stats.reclaimable_files, 'unused file')} in "
                       f"{core.pluralized(sum(1 for p in r.projects if p.reclaimable_files), 'project')}, "
                       f"out of {core.pluralized(r.stats.scanned_files, 'file')} scanned").pack(anchor="w")
        if r.stats.held_back_files:
            ttk.Label(left, style="Small.TLabel",
                      text=f"{core.pluralized(r.stats.held_back_files, 'unused file')} "
                           f"({core.human_bytes(r.stats.held_back_bytes)}) held back as too risky. "
                           "Options lets you include them.").pack(anchor="w", pady=(2, 0))
        right = ttk.Frame(head)
        right.pack(side="right", anchor="n")
        self._options_menu(right).pack()

        # Ableton warning
        if self.ableton_running:
            warn = tk.Frame(f, background=ORANGE_BG, padx=22, pady=10)
            warn.pack(fill="x")
            tk.Label(warn, background=ORANGE_BG, foreground=ORANGE, wraplength=860, justify="left",
                     font="TkDefaultFont",
                     text="⚠  Ableton Live is open. Quit it before you sweep, then reopen your projects "
                          "to check them. A Set that's already open has its samples loaded in memory, "
                          "so it will look fine even if something went wrong.").pack(anchor="w")

        # Body
        body = ttk.Frame(f, padding=(22, 6, 22, 0))
        body.pack(fill="both", expand=True)
        if not any(p.reclaimable_files for p in r.projects):
            empty = ttk.Frame(body)
            empty.place(relx=0.5, rely=0.45, anchor="center")
            ttk.Label(empty, text="✔", font=self.f_big, foreground=GREEN).pack()
            ttk.Label(empty, text="Nothing to sweep", style="H2.TLabel").pack(pady=(6, 0))
            ttk.Label(empty, text="Every sample in these projects is being used.", style="Muted.TLabel").pack()
        else:
            self._build_tree(body)

        # Footer
        foot = ttk.Frame(f, padding=(22, 12, 22, 16))
        foot.pack(fill="x")
        ttk.Button(foot, text="Scan a Different Folder", command=self.choose_folder).pack(side="left")
        ttk.Button(foot, text="Put Files Back…", command=self.undo_sweep).pack(side="left", padx=(8, 0))
        self.move_button = ttk.Button(foot, text="Move Files Aside…", style="Accent.TButton",
                                      command=self.move_aside)
        self.move_button.pack(side="right", ipadx=6, ipady=2)
        self.selection_label = ttk.Label(foot, style="Muted.TLabel")
        self.selection_label.pack(side="right", padx=(0, 14))
        self._update_selection_label()
        self._swap(f)

    def _options_menu(self, parent: tk.Widget) -> tk.Widget:
        self.opt_vars = {
            "include_unmanaged": tk.BooleanVar(value=self.options.include_unmanaged),
            "include_loose_in_samples": tk.BooleanVar(value=self.options.include_loose_in_samples),
            "ignore_backups": tk.BooleanVar(value=self.options.ignore_backups),
            "deep": tk.BooleanVar(value=self.options.deep),
        }
        mb = ttk.Menubutton(parent, text="Options ▾")
        menu = tk.Menu(mb, tearoff=0)
        menu.add_checkbutton(label="Include files outside Samples (bounces, masters)",
                             variable=self.opt_vars["include_unmanaged"], command=self._options_changed)
        menu.add_checkbutton(label="Include files dropped straight into Samples",
                             variable=self.opt_vars["include_loose_in_samples"], command=self._options_changed)
        menu.add_checkbutton(label="Treat backup-only samples as unused",
                             variable=self.opt_vars["ignore_backups"], command=self._options_changed)
        menu.add_separator()
        menu.add_checkbutton(label="Search inside plugin presets (slower)",
                             variable=self.opt_vars["deep"], command=self._options_changed)
        mb["menu"] = menu
        return mb

    def _options_changed(self) -> None:
        self.options = core.Options(**{k: v.get() for k, v in self.opt_vars.items()})
        if self.root_path:
            self.start_scan(self.root_path)

    def _build_tree(self, parent: tk.Widget) -> None:
        assert self.result is not None
        wrap = ttk.Frame(parent)
        wrap.pack(fill="both", expand=True)
        cols = ("bucket", "size")
        tree = ttk.Treeview(wrap, columns=cols, show="tree headings", selectmode="extended")
        tree.heading("#0", text="Project / file", anchor="w")
        tree.heading("bucket", text="Where", anchor="w")
        tree.heading("size", text="Size", anchor="e")
        tree.column("#0", width=520, minwidth=260, stretch=True)
        tree.column("bucket", width=190, minwidth=120, stretch=False, anchor="w")
        tree.column("size", width=100, minwidth=80, stretch=False, anchor="e")
        vsb = ttk.Scrollbar(wrap, orient="vertical", command=tree.yview)
        tree.configure(yscrollcommand=vsb.set)
        tree.grid(row=0, column=0, sticky="nsew")
        vsb.grid(row=0, column=1, sticky="ns")
        wrap.rowconfigure(0, weight=1)
        wrap.columnconfigure(0, weight=1)
        tree.tag_configure("project", font=self.f_bold)
        self.tree = tree
        self.tree_index: dict[str, core.SweepFile] = {}       # item id -> file
        self.project_items: dict[str, list[str]] = {}          # project item -> child ids
        self._project_names: dict[str, str] = {}

        for p in self.result.projects:
            files = sorted(p.reclaimable_files, key=lambda f: -f.size)
            if not files:
                continue
            pid = tree.insert("", "end", text="", open=False,
                              values=(_bucket_summary(files), core.human_bytes(p.reclaimable_bytes)),
                              tags=("project",))
            ids = []
            for fobj in files:
                iid = tree.insert(pid, "end", text="", values=(fobj.bucket, core.human_bytes(fobj.size)),
                                  tags=("file",))
                self.tree_index[iid] = fobj
                ids.append(iid)
            self.project_items[pid] = ids
            self._project_names[pid] = p.display_name
            self._refresh_project_row(pid)
        for iid, fobj in self.tree_index.items():
            tree.item(iid, text=f"{CHECKED if fobj.path in self.selected else UNCHECKED}  {fobj.relative_path}")

        tree.bind("<Button-1>", self._tree_click)
        tree.bind("<space>", self._tree_space)
        tree.bind("<Button-3>", self._tree_context)
        if not core.IS_WINDOWS:
            tree.bind("<Button-2>", self._tree_context)      # macOS secondary click

    def _refresh_project_row(self, pid: str, name: str | None = None) -> None:
        if name is None:
            name = self._project_names.get(pid, "")
        ids = self.project_items[pid]
        n_on = sum(1 for i in ids if self.tree_index[i].path in self.selected)
        glyph = CHECKED if n_on == len(ids) else UNCHECKED if n_on == 0 else PARTIAL
        self.tree.item(pid, text=f"{glyph}  {name}")

    def _toggle_item(self, iid: str) -> None:
        if iid in self.project_items:
            ids = self.project_items[iid]
            all_on = all(self.tree_index[i].path in self.selected for i in ids)
            for i in ids:
                path = self.tree_index[i].path
                if all_on:
                    self.selected.discard(path)
                else:
                    self.selected.add(path)
                self.tree.item(i, text=f"{UNCHECKED if all_on else CHECKED}  {self.tree_index[i].relative_path}")
            self._refresh_project_row(iid)
        elif iid in self.tree_index:
            fobj = self.tree_index[iid]
            if fobj.path in self.selected:
                self.selected.discard(fobj.path)
            else:
                self.selected.add(fobj.path)
            self.tree.item(iid, text=f"{CHECKED if fobj.path in self.selected else UNCHECKED}  {fobj.relative_path}")
            self._refresh_project_row(self.tree.parent(iid))
        self._update_selection_label()

    def _tree_click(self, event: tk.Event) -> str | None:
        region = self.tree.identify_region(event.x, event.y)
        if region != "tree":
            return None
        element = self.tree.identify_element(event.x, event.y)
        if "indicator" in element:
            return None                     # let the disclosure triangle work
        iid = self.tree.identify_row(event.y)
        if not iid:
            return None
        self._toggle_item(iid)
        return "break"

    def _tree_space(self, event: tk.Event) -> str:
        for iid in self.tree.selection():
            self._toggle_item(iid)
        return "break"

    def _tree_context(self, event: tk.Event) -> None:
        iid = self.tree.identify_row(event.y)
        if not iid:
            return
        menu = tk.Menu(self, tearoff=0)
        if iid in self.project_items:
            folder = self._project_folder(iid)
            menu.add_command(label=f"Show in {core.FILE_MANAGER}",
                             command=lambda: core.reveal(folder))
        else:
            fobj = self.tree_index[iid]
            menu.add_command(label=f"Show in {core.FILE_MANAGER}",
                             command=lambda: core.reveal(fobj.path))
            menu.add_command(label=core.STATUS_EXPLANATION.get(fobj.status, fobj.status), state="disabled")
        menu.tk_popup(event.x_root, event.y_root)

    def _project_folder(self, pid: str) -> str:
        ids = self.project_items[pid]
        if ids:
            return os.path.dirname(self.tree_index[ids[0]].path)
        return self.root_path or ""

    def _update_selection_label(self) -> None:
        if not hasattr(self, "selection_label"):
            return
        if not self.result:
            return
        by_path = {f.path: f for p in self.result.projects for f in p.files}
        n = len(self.selected)
        b = sum(by_path[p].size for p in self.selected if p in by_path)
        self.selection_label.configure(text=f"{n} selected · {core.human_bytes(b)}" if n else "Nothing selected")
        self.move_button.state(["!disabled"] if n else ["disabled"])

    def show_moving(self, total: int) -> None:
        f = ttk.Frame(self.container, padding=40)
        inner = ttk.Frame(f)
        inner.place(relx=0.5, rely=0.5, anchor="center")
        self.progress = ttk.Progressbar(inner, length=360, mode="determinate", maximum=max(total, 1))
        self.progress.pack()
        self.stage_label = ttk.Label(inner, text=f"Moving 0 of {total}…")
        self.stage_label.pack(pady=(12, 0))
        self._swap(f)

    def show_done(self, out: core.MoveOutcome) -> None:
        f = ttk.Frame(self.container, padding=40)
        inner = ttk.Frame(f)
        inner.place(relx=0.5, rely=0.5, anchor="center")
        ttk.Label(inner, text="✔", font=self.f_big, foreground=GREEN).pack()
        ttk.Label(inner, text=f"Swept {core.human_bytes(out.bytes)}", style="H2.TLabel").pack(pady=(8, 0))
        ttk.Label(inner, text=f"{core.pluralized(out.moved, 'file')} moved. Nothing was deleted.",
                  style="Muted.TLabel").pack(pady=(2, 0))
        steps = ttk.Frame(inner)
        steps.pack(pady=(26, 0), anchor="w")
        bin_name = core.TRASH_NAME
        for n, text in enumerate((
            "Open your projects in Ableton and check they still load.",
            f"If all is well, archive that folder or drag it to {bin_name}.",
            "If something is missing, choose Put Files Back and pick that folder.",
        ), 1):
            row = ttk.Frame(steps)
            row.pack(anchor="w", pady=4)
            ttk.Label(row, text=f" {n} ", style="Bold.TLabel").pack(side="left", padx=(0, 10))
            ttk.Label(row, text=text).pack(side="left")
        if out.failures:
            ttk.Label(inner, foreground=ORANGE,
                      text=f"{core.pluralized(len(out.failures), 'file')} could not be moved and "
                           "were left in place.").pack(pady=(14, 0))
        btns = ttk.Frame(inner)
        btns.pack(pady=(30, 0))
        ttk.Button(btns, text=f"Show in {core.FILE_MANAGER}",
                   command=lambda: core.reveal(out.manifest)).pack(side="left")
        ttk.Button(btns, text="Put These Files Back",
                   command=lambda: self.perform_restore(out.manifest)).pack(side="left", padx=10)
        ttk.Button(btns, text="Scan Again", style="Accent.TButton",
                   command=self.rescan).pack(side="left")
        self._swap(f)

    # ----- actions -----------------------------------------------------------

    def choose_folder(self) -> None:
        initial = self.root_path or core.default_ableton_folder()
        path = filedialog.askdirectory(parent=self, title="Choose your Ableton folder",
                                       initialdir=initial, mustexist=True)
        if path:
            self.start_scan(os.path.normpath(path))

    def rescan(self) -> None:
        if self.root_path:
            self.start_scan(self.root_path)
        else:
            self.show_welcome()

    def start_scan(self, root: str) -> None:
        self.root_path = root
        self.show_scanning(root)
        options = self.options

        def work() -> None:
            try:
                running = core.ableton_is_running()
                res = core.scan(root, options,
                                progress=lambda stage, done, total: self._events.put(("progress", stage, done, total)))
                self._events.put(("scanned", res, running))
            except Exception as exc:  # noqa: BLE001
                self._events.put(("error", f"Couldn't scan that folder.\n\n{exc}"))

        threading.Thread(target=work, daemon=True).start()

    def move_aside(self) -> None:
        if not self.result or not self.selected:
            return
        dest = filedialog.askdirectory(parent=self, title="Where should the swept files go?",
                                       initialdir=core.default_destination_folder(), mustexist=True)
        if not dest:
            return
        by_path = {f.path: f for p in self.result.projects for f in p.files}
        files = [by_path[p] for p in self.selected if p in by_path]
        files.sort(key=lambda f: f.path)
        root = self.result.root
        self.show_moving(len(files))

        def work() -> None:
            try:
                out = core.move_files(files, root, dest,
                                      progress=lambda done, total: self._events.put(("moving", done, total)))
                self._events.put(("moved", out))
            except Exception as exc:  # noqa: BLE001
                self._events.put(("error", f"Couldn't move the files.\n\n{exc}"))

        threading.Thread(target=work, daemon=True).start()

    def undo_sweep(self) -> None:
        initial = os.path.dirname(self.last_sweep_folder) if self.last_sweep_folder else core.default_destination_folder()
        folder = filedialog.askdirectory(parent=self, title="Choose the folder Sample Sweep created",
                                         initialdir=initial, mustexist=True)
        if not folder:
            return
        manifest = core.find_manifest(folder)
        if not manifest:
            messagebox.showwarning("Not a Sample Sweep folder",
                                   f"That folder doesn't contain \"{core.MANIFEST_NAME}\".\n\n"
                                   "Pick the folder Sample Sweep created when it moved the files "
                                   "(it starts with \"Sample Sweep\" and a date).", parent=self)
            return
        self.perform_restore(manifest)

    def perform_restore(self, manifest: str) -> None:
        self.show_moving(0)
        self.stage_label.configure(text="Putting files back…")

        def work() -> None:
            try:
                out = core.restore(manifest,
                                   progress=lambda done, total: self._events.put(("moving", done, total)))
                self._events.put(("restored", out))
            except Exception as exc:  # noqa: BLE001
                self._events.put(("error", f"Couldn't put the files back.\n\n{exc}"))

        threading.Thread(target=work, daemon=True).start()

    # ----- worker -> UI ------------------------------------------------------

    def _poll(self) -> None:
        try:
            while True:
                ev = self._events.get_nowait()
                self._handle(ev)
        except queue.Empty:
            pass
        self.after(80, self._poll)

    def _handle(self, ev: tuple) -> None:
        kind = ev[0]
        if kind == "progress":
            _, stage, done, total = ev
            if not hasattr(self, "progress") or not self.progress.winfo_exists():
                return
            if total:
                if self.progress["mode"] != "determinate":
                    self.progress.stop()
                    self.progress.configure(mode="determinate")
                self.progress.configure(maximum=total, value=done)
                self.stage_label.configure(text=f"{stage}  {done} of {total}")
            else:
                self.stage_label.configure(text=f"{stage}…")
        elif kind == "scanned":
            _, res, running = ev
            self.result = res
            self.ableton_running = running
            self.selected = {f.path for p in res.projects for f in p.reclaimable_files}
            self.show_results()
        elif kind == "moving":
            _, done, total = ev
            if hasattr(self, "progress") and self.progress.winfo_exists():
                self.progress.configure(maximum=max(total, 1), value=done)
                verb = self.stage_label.cget("text").split(" ")[0]
                self.stage_label.configure(text=f"{verb} {done} of {total}…")
        elif kind == "moved":
            out = ev[1]
            self.last_sweep_folder = out.folder
            self.show_done(out)
        elif kind == "restored":
            out = ev[1]
            msg = f"{core.pluralized(out.restored, 'file')} put back where they came from."
            if out.already_in_place:
                msg += f"\n{core.pluralized(out.already_in_place, 'file')} were already in place."
            if out.missing:
                msg += f"\n{core.pluralized(out.missing, 'file')} could not be found."
            messagebox.showinfo("Put Files Back", msg, parent=self)
            self.rescan()
        elif kind == "error":
            messagebox.showerror(core.TOOL_NAME, ev[1], parent=self)
            if self.result:
                self.show_results()
            else:
                self.show_welcome()


def _bucket_summary(files: list[core.SweepFile]) -> str:
    counts: dict[str, int] = {}
    for f in files:
        counts[f.bucket] = counts.get(f.bucket, 0) + 1
    top = sorted(counts.items(), key=lambda kv: -kv[1])[:3]
    return ", ".join(f"{n} {b}" for b, n in top)


def _truncate_head(s: str, n: int) -> str:
    return s if len(s) <= n else "…" + s[-(n - 1):]


def _dpi_aware() -> None:
    if not core.IS_WINDOWS:
        return
    try:
        import ctypes
        try:
            ctypes.windll.shcore.SetProcessDpiAwareness(1)   # system DPI aware
        except Exception:  # noqa: BLE001
            ctypes.windll.user32.SetProcessDPIAware()
    except Exception:  # noqa: BLE001
        pass


def run(initial_root: str | None = None) -> int:
    _dpi_aware()
    app = App(initial_root)
    app.mainloop()
    return 0
