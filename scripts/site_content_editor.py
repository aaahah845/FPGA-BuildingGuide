"""Chinese desktop form for the existing V6 content exporter. No FPGA changes."""
from pathlib import Path
import argparse
import ctypes
import json
import struct
import sys
import tkinter as tk
from tkinter import ttk, filedialog, messagebox
from PIL import Image, ImageTk

import dynamic_text_fonts as fonts
import export_site_cfg as exporter
import site_editor_model as model

if sys.platform == 'win32':
    # Keep Tk coordinates and screen capture coordinates in physical pixels.
    # This must happen before the first Tk window is created.
    ctypes.windll.user32.SetProcessDPIAware()

RESOURCES = Path(getattr(sys, '_MEIPASS', Path(__file__).resolve().parents[1]))
for module in (fonts, exporter, model):
    module.ROOT = RESOURCES


def default_config():
    """Use the editable project config when present, otherwise bundled sample."""
    if not getattr(sys, 'frozen', False):
        return RESOURCES / 'config/runtime_site.json'
    for parent in Path(sys.executable).resolve().parents:
        candidate = parent / 'config/runtime_site.json'
        if candidate.is_file() and (parent / 'src/td_project').is_dir():
            return candidate
    return RESOURCES / 'config/runtime_site.json'


class ContentEditor:
    def __init__(self, root, config_path=None):
        self.root = root
        self.document = None
        self.floor_index = 0
        self.room_index = 0
        self.loading = False
        self.pending = None
        self.preview_images = []
        self.current_issues = []
        baseline, manifest = fonts.load_baseline()
        self.large_baseline = struct.unpack_from('<4096I', baseline)
        self.notes_baseline = struct.unpack_from('<1536H', baseline, 16384)
        self.fixed_large = {manifest['large_chars'][i]: i for i in fonts.LARGE_RESERVED}
        self.fixed_notes = {manifest['notes_chars'][i]: i for i in fonts.NOTES_RESERVED}
        self.title_var = tk.StringVar()
        self.floor_var = tk.StringVar()
        self.room_var = tk.StringVar()
        self.activity_var = tk.BooleanVar()
        self.path_var = tk.StringVar()
        self.status_var = tk.StringVar(value='正在打开内容…')
        self.capacity_var = tk.StringVar()
        self.title_count = tk.StringVar()
        self.floor_count = tk.StringVar()
        self.room_count = tk.StringVar()
        self.description_count = tk.StringVar()
        self.activity_count = tk.StringVar()
        root.title('导视终端内容编辑器')
        # Respect display scaling, but fit the available laptop screen height.
        density = min(root.winfo_fpixels('1i') / 96, (root.winfo_screenheight()-100) / 780)
        density = max(0.9, density)
        root.tk.call('tk', 'scaling', density * 96 / 72)
        self.display_scale = density
        width = min(round(1120*density), root.winfo_screenwidth()-60)
        height = min(round(780*density), root.winfo_screenheight()-100)
        root.geometry(f'{width}x{height}+30+30')
        root.minsize(min(width, round(1000*density)), min(height, round(720*density)))
        root.configure(bg='#f3f6fa')
        self._style()
        self._build()
        for variable in (self.title_var, self.floor_var, self.room_var, self.activity_var):
            variable.trace_add('write', self._changed)
        for widget in (self.description, self.activity):
            widget.bind('<<Modified>>', self._text_changed)
        root.protocol('WM_DELETE_WINDOW', self.close)
        root.bind('<Control-s>', lambda event: self.save())
        root.bind('<Control-o>', lambda event: self.open_dialog())
        self.load_path(config_path or default_config(), initial=True)

    def _style(self):
        style = ttk.Style(self.root)
        style.theme_use('clam')
        style.configure('.', font=('Microsoft YaHei UI', 10), background='#f3f6fa', foreground='#203746')
        style.configure('TFrame', background='#f3f6fa')
        style.configure('Card.TFrame', background='#ffffff')
        style.configure('Card.TLabel', background='#ffffff')
        style.configure('Muted.TLabel', foreground='#627382')
        style.configure('Header.TLabel', font=('Microsoft YaHei UI', 18, 'bold'))
        style.configure('Section.TLabel', font=('Microsoft YaHei UI', 11, 'bold'), background='#ffffff')
        style.configure('TButton', padding=(12, 7), background='#e4edf4', borderwidth=0)
        style.map('TButton', background=[('active', '#d6e7f2')])
        style.configure('Accent.TButton', background='#226a91', foreground='#ffffff')
        style.map('Accent.TButton', background=[('active', '#195777')])
        style.configure('TEntry', padding=5, fieldbackground='#ffffff')
        style.configure('Treeview', rowheight=round(27*self.display_scale), background='#ffffff', fieldbackground='#ffffff', borderwidth=0)
        style.map('Treeview', background=[('selected', '#dcecf5')], foreground=[('selected', '#124c6e')])
        style.configure('Card.TCheckbutton', background='#ffffff')

    def _build(self):
        outer = ttk.Frame(self.root, padding=18)
        outer.pack(fill='both', expand=True)
        ttk.Label(outer, text='导视终端 · 内容编辑', style='Header.TLabel').pack(anchor='w')
        ttk.Label(outer, text='填写名称和说明，保存草稿后导出配置。无需编辑代码或手动制作字模。',
                  style='Muted.TLabel').pack(anchor='w', pady=(5, 12))
        toolbar = ttk.Frame(outer)
        toolbar.pack(fill='x', pady=(0, 8))
        ttk.Button(toolbar, text='打开内容…', command=self.open_dialog).pack(side='left', padx=(0, 7))
        ttk.Button(toolbar, text='保存草稿', command=self.save).pack(side='left', padx=(0, 7))
        ttk.Button(toolbar, text='另存为…', command=lambda: self.save(save_as=True)).pack(side='left')
        ttk.Button(toolbar, text='导出到文件…', style='Accent.TButton', command=self.export_dialog).pack(side='right')
        ttk.Button(toolbar, text='检查内容', command=self.check_dialog).pack(side='right', padx=7)
        ttk.Label(outer, textvariable=self.path_var, style='Muted.TLabel').pack(anchor='w', pady=(0, 10))
        body = ttk.Frame(outer)
        body.pack(fill='both', expand=True)
        body.columnconfigure(1, weight=1)
        body.rowconfigure(0, weight=1)

        left = ttk.Frame(body, style='Card.TFrame', padding=12)
        left.grid(row=0, column=0, sticky='ns', padx=(0, 12))
        ttk.Label(left, text='选择楼层 / 房间', style='Section.TLabel').pack(anchor='w', pady=(0, 8))
        tree_frame = ttk.Frame(left, style='Card.TFrame')
        tree_frame.pack(fill='both', expand=True)
        self.tree = ttk.Treeview(tree_frame, show='tree', selectmode='browse', height=17)
        self.tree.column('#0', width=round(196*self.display_scale), minwidth=170)
        self.tree.pack(side='left', fill='both', expand=True)
        scroll = ttk.Scrollbar(tree_frame, orient='vertical', command=self.tree.yview)
        scroll.pack(side='right', fill='y')
        self.tree.configure(yscrollcommand=scroll.set)
        self.tree.bind('<<TreeviewSelect>>', self._select)

        middle = ttk.Frame(body, style='Card.TFrame', padding=14)
        middle.grid(row=0, column=1, sticky='nsew')
        middle.columnconfigure(0, weight=1)
        names = ttk.Frame(middle, style='Card.TFrame')
        names.grid(row=0, column=0, sticky='ew')
        names.columnconfigure(0, weight=1)
        names.columnconfigure(1, weight=1)
        self.title_entry = self._entry(names, '终端标题', self.title_var, self.title_count, 0)
        self.floor_entry = self._entry(names, '当前楼层名称', self.floor_var, self.floor_count, 1)
        room_header = ttk.Frame(middle, style='Card.TFrame')
        room_header.grid(row=1, column=0, sticky='ew', pady=(16, 4))
        ttk.Label(room_header, text='房间名称', style='Section.TLabel').pack(side='left')
        ttk.Label(room_header, textvariable=self.room_count, style='Card.TLabel').pack(side='right')
        self.room_entry = ttk.Entry(middle, textvariable=self.room_var)
        self.room_entry.grid(row=2, column=0, sticky='ew')
        desc_header = ttk.Frame(middle, style='Card.TFrame')
        desc_header.grid(row=3, column=0, sticky='ew', pady=(15, 4))
        ttk.Label(desc_header, text='房间简介', style='Section.TLabel').pack(side='left')
        ttk.Label(desc_header, textvariable=self.description_count, style='Card.TLabel').pack(side='right')
        self.description = self._text(middle)
        self.description.grid(row=4, column=0, sticky='nsew')
        activity_header = ttk.Frame(middle, style='Card.TFrame')
        activity_header.grid(row=5, column=0, sticky='ew', pady=(15, 4))
        self.activity_check = ttk.Checkbutton(activity_header, text='今日有活动', variable=self.activity_var,
                                               style='Card.TCheckbutton')
        self.activity_check.pack(side='left')
        ttk.Label(activity_header, textvariable=self.activity_count, style='Card.TLabel').pack(side='right')
        self.activity = self._text(middle)
        self.activity.grid(row=6, column=0, sticky='nsew')
        middle.rowconfigure(4, weight=1)
        middle.rowconfigure(6, weight=1)
        ttk.Label(middle, text='每段最多 4 行，每行 12 字，长行会自动折行。\n取消“今日有活动”会保留已填写的活动内容。',
                  style='Card.TLabel', foreground='#627382').grid(row=7, column=0, sticky='w', pady=(10, 0))

        right = ttk.Frame(body, style='Card.TFrame', padding=12)
        right.grid(row=0, column=2, sticky='ns', padx=(12, 0))
        ttk.Label(right, text='屏幕文字预览', style='Section.TLabel').pack(anchor='w')
        ttk.Label(right, text='按实际字模与折行规则预览', style='Card.TLabel', foreground='#627382').pack(anchor='w', pady=(3, 10))
        self.name_preview = ttk.Label(right, style='Card.TLabel')
        self.name_preview.pack(anchor='w', pady=(0, 12))
        ttk.Label(right, text='房间简介', style='Section.TLabel').pack(anchor='w')
        self.desc_preview = ttk.Label(right, style='Card.TLabel')
        self.desc_preview.pack(anchor='w', pady=(6, 16))
        ttk.Label(right, text='今日活动', style='Section.TLabel').pack(anchor='w')
        self.activity_preview = ttk.Label(right, style='Card.TLabel')
        self.activity_preview.pack(anchor='w', pady=(6, 12))
        ttk.Label(right, text='超出部分不会出现在预览中，\n导出时会提示修正。', style='Card.TLabel',
                  foreground='#627382').pack(anchor='w')
        ttk.Label(right, text='修改名称不会改动\n照片中原有的文字。', style='Card.TLabel',
                  foreground='#627382').pack(anchor='w', pady=(18, 0))

        footer = ttk.Frame(outer)
        footer.pack(fill='x', pady=(12, 0))
        ttk.Label(footer, textvariable=self.capacity_var).pack(anchor='w')
        self.status_label = ttk.Label(footer, textvariable=self.status_var, wraplength=1050,
                                      style='Muted.TLabel')
        self.status_label.pack(anchor='w', pady=(5, 0))

    def _entry(self, parent, label, variable, count, column):
        frame = ttk.Frame(parent, style='Card.TFrame')
        frame.grid(row=0, column=column, sticky='ew', padx=(0, 12) if column == 0 else (0, 0))
        ttk.Label(frame, text=label, style='Section.TLabel').pack(anchor='w')
        entry = ttk.Entry(frame, textvariable=variable, width=17)
        entry.pack(fill='x', pady=(6, 2))
        ttk.Label(frame, textvariable=count, style='Card.TLabel', foreground='#627382').pack(anchor='w')
        return entry

    def _text(self, parent):
        return tk.Text(parent, height=4, width=30, wrap='char', undo=True,
                       font=('Microsoft YaHei UI', 11), bg='#f8fafc', fg='#203746',
                       relief='flat', highlightthickness=1, highlightbackground='#dae3eb',
                       highlightcolor='#226a91', padx=8, pady=7)

    def _text_changed(self, event):
        if event.widget.edit_modified():
            event.widget.edit_modified(False)
            self._changed()

    def _changed(self, *args):
        if self.loading or self.document is None:
            return
        if self.pending:
            self.root.after_cancel(self.pending)
        self.pending = self.root.after(180, self.refresh)

    def _commit(self):
        if self.loading or self.document is None:
            return
        self.document.update_title(self.title_var.get())
        self.document.update_floor(self.floor_index, self.floor_var.get())
        if self.room_index is not None:
            self.document.update_room(self.floor_index, self.room_index,
                name=self.room_var.get(), description=self.description.get('1.0', 'end-1c'),
                activity=self.activity.get('1.0', 'end-1c'), today_activity=self.activity_var.get())

    def _set_text(self, widget, text, enabled=True):
        widget.configure(state='normal')
        widget.delete('1.0', 'end')
        widget.insert('1.0', text)
        widget.edit_reset()
        widget.edit_modified(False)
        widget.configure(state='normal' if enabled else 'disabled')

    def _show_selection(self):
        self.loading = True
        floor = self.document.data['floors'][self.floor_index]
        self.floor_var.set(floor['name'])
        has_room = self.room_index is not None
        room = floor['rooms'][self.room_index] if has_room else {}
        self.room_var.set(room.get('name', ''))
        self.activity_var.set(room.get('today_activity', False))
        self.room_entry.configure(state='normal' if has_room else 'disabled')
        self.activity_check.configure(state='normal' if has_room else 'disabled')
        self._set_text(self.description, room.get('description', ''), has_room)
        self._set_text(self.activity, room.get('activity', ''), has_room)
        self.loading = False
        self.refresh()

    def _select(self, event=None):
        if self.loading or not self.tree.selection():
            return
        item = self.tree.selection()[0]
        self._commit()
        parts = item.split(':')
        self.floor_index = int(parts[0])
        self.room_index = int(parts[1]) if len(parts) == 2 else None
        self._show_selection()

    def refresh(self):
        if self.pending:
            self.root.after_cancel(self.pending)
        self.pending = None
        self._commit()
        data = self.document.data
        for fi, floor in enumerate(data['floors']):
            self.tree.item(str(fi), text=f'{fi+1}层 · {floor["name"]}')
            for ri, room in enumerate(floor['rooms']):
                self.tree.item(f'{fi}:{ri}', text=f'{ri+1:02d}  {room["name"]}')
        self.title_count.set(f'{len(self.title_var.get())} / 8 字')
        self.floor_count.set(f'{len(self.floor_var.get())} / 8 字')
        self.room_count.set(f'{len(self.room_var.get())} / 8 字' if self.room_index is not None else '请选择房间')
        desc = self.description.get('1.0', 'end-1c')
        activity = self.activity.get('1.0', 'end-1c')
        self.description_count.set(f'{len(model.wrap_notes(desc))} / 4 行')
        self.activity_count.set(f'{len(model.wrap_notes(activity))} / 4 行')
        try:
            info = model.content_status(data)
            self.current_issues = info['issues']
            self.capacity_var.set(f'整套内容用字：名称 {info["names_used"]} / 121　｜　简介与活动 {info["notes_used"]} / 85　（相同字符只计一次）')
        except Exception as error:
            self.current_issues = [str(error)]
            self.capacity_var.set('内容检查未完成')
        if self.current_issues:
            self.status_var.set(f'需要修正 {len(self.current_issues)} 处：{self.current_issues[0]}')
            self.status_label.configure(foreground='#aa3d30')
        else:
            self.status_var.set('内容检查通过。可保存草稿，或导出供开发板使用的配置文件。')
            self.status_label.configure(foreground='#287158')
        self.root.title(('● ' if self.document.dirty else '') + '导视终端内容编辑器')
        self._preview()

    def _preview_image(self, lines, size, columns):
        image = Image.new('RGB', (columns * size + 12, len(lines) * (size+4) + 12), '#f4f7fa')
        pix = image.load()
        path = fonts.DEFAULT_LARGE_FONT if size == 24 else fonts.DEFAULT_NOTES_FONT
        for y, line in enumerate(lines):
            for x, char in enumerate(line[:columns]):
                try:
                    if size == 24 and char in self.fixed_large:
                        rows = fonts.unpack_large_rows(self.large_baseline[:2048], self.large_baseline[2048:], self.fixed_large[char])
                    elif size == 16 and char in self.fixed_notes:
                        index = self.fixed_notes[char]*16
                        rows = self.notes_baseline[index:index+16]
                    else:
                        rows = fonts.render_rows(char, size, str(path))
                    color = (30, 59, 78)
                except Exception:
                    rows = tuple(((1 << size)-1) if row in (0, size-1) else (1 << (size-1)) | 1 for row in range(size))
                    color = (180, 60, 48)
                for row, bits in enumerate(rows):
                    for col in range(size):
                        if bits & (1 << (size-1-col)):
                            pix[6+x*size+col, 6+y*(size+4)+row] = color
        if self.display_scale != 1:
            image = image.resize((round(image.width*self.display_scale), round(image.height*self.display_scale)), Image.Resampling.NEAREST)
        return ImageTk.PhotoImage(image, master=self.root)

    def _preview(self):
        title = self.room_var.get() if self.room_index is not None else self.floor_var.get()
        desc = model.wrap_notes(self.description.get('1.0', 'end-1c'))[:4]
        activity = model.wrap_notes(self.activity.get('1.0', 'end-1c'))[:4]
        desc += ['']*(4-len(desc))
        activity += ['']*(4-len(activity))
        self.preview_images = [self._preview_image([title], 24, 8),
            self._preview_image(desc, 16, 12), self._preview_image(activity, 16, 12)]
        for label, image in zip((self.name_preview, self.desc_preview, self.activity_preview), self.preview_images):
            label.configure(image=image)

    def load_path(self, path, initial=False):
        try:
            doc = model.ContentDocument.load(Path(path))
        except Exception as error:
            messagebox.showerror('无法打开内容', f'请检查文件是否为内容草稿。\n\n{error}', parent=self.root)
            if initial:
                self.root.after_idle(self.root.destroy)
            return False
        # Files embedded in a portable application are templates, never save targets.
        if getattr(sys, 'frozen', False) and Path(path).resolve().is_relative_to(RESOURCES.resolve()):
            doc.path = None
        self.loading = True
        self.document = doc
        self.floor_index = 0
        self.room_index = 0
        self.title_var.set(doc.data.get('title', '企业会议导视'))
        self.tree.delete(*self.tree.get_children())
        for fi, floor in enumerate(doc.data['floors']):
            self.tree.insert('', 'end', iid=str(fi), text=floor['name'], open=(fi == 0))
            for ri, room in enumerate(floor['rooms']):
                self.tree.insert(str(fi), 'end', iid=f'{fi}:{ri}', text=room['name'])
        self.tree.selection_set('0:0')
        self.tree.focus('0:0')
        self.path_var.set(f'当前草稿：{doc.path}' if doc.path else '当前内容：内置示例，请另存为自己的草稿')
        self.loading = False
        self._show_selection()
        return True

    def _may_discard(self):
        self._commit()
        if self.document is None or not self.document.dirty:
            return True
        answer = messagebox.askyesnocancel('保存修改', '内容尚未保存，是否先保存草稿？', parent=self.root)
        return self.save() if answer is True else answer is False

    def open_dialog(self):
        if not self._may_discard():
            return
        path = filedialog.askopenfilename(title='打开内容草稿', filetypes=[('内容草稿', '*.json')], parent=self.root)
        if path:
            self.load_path(path)

    def save(self, save_as=False):
        self._commit()
        path = self.document.path
        if save_as or path is None:
            chosen = filedialog.asksaveasfilename(title='保存内容草稿', defaultextension='.json',
                initialfile=path.name if path else '导视终端内容.json',
                filetypes=[('内容草稿', '*.json')], parent=self.root)
            if not chosen:
                return False
            path = Path(chosen)
        try:
            self.document.save(path)
        except Exception as error:
            messagebox.showerror('保存失败', f'内容仍保留在编辑器内，请另选可写的位置。\n\n{error}', parent=self.root)
            return False
        self.path_var.set(f'当前草稿：{self.document.path}')
        self.refresh()
        self.status_var.set(f'草稿已保存：{Path(path).name}')
        return True

    def check_dialog(self):
        self.refresh()
        if self.current_issues:
            self._show_issues()
        else:
            messagebox.showinfo('内容检查通过', '名称、折行、用字容量及字体检查通过，可以导出配置。', parent=self.root)

    def _show_issues(self):
        messagebox.showerror('请先修正内容', '\n'.join(self.current_issues[:12]) +
            (f'\n……还有 {len(self.current_issues)-12} 处，请逐项修改。' if len(self.current_issues) > 12 else ''), parent=self.root)

    def export_dialog(self):
        self.refresh()
        if self.current_issues:
            self._show_issues()
            return
        path = filedialog.asksaveasfilename(title='导出开发板配置文件', initialfile='SITE.CFG',
            defaultextension='.CFG', filetypes=[('开发板配置', '*.CFG')], parent=self.root)
        if not path:
            return
        try:
            self.document.export_cfg(Path(path))
        except Exception as error:
            messagebox.showerror('导出失败', f'请根据提示修正内容，或另选可写的位置。\n\n{error}', parent=self.root)
            return
        messagebox.showinfo('导出成功', f'已生成：\n{path}\n\n将文件以 SITE.CFG 为名放入 SD 卡根目录，保留原图片和音频文件，重新启动开发板。\n\n首次使用需下载动态文字版位流。'+
            ('\n\n本次修改尚未保存为草稿，请点击“保存草稿”便于下次编辑。' if self.document.dirty else ''), parent=self.root)
        self.status_var.set('配置已导出。将 SITE.CFG 复制到卡根目录后重新启动开发板。')

    def close(self):
        if self._may_discard():
            if self.pending:
                self.root.after_cancel(self.pending)
            self.root.destroy()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path)
    parser.add_argument('--self-test', type=Path, help='run editor checks in an isolated directory and exit')
    args = parser.parse_args()
    if args.self_test:
        from site_editor_smoke import run_self_test
        raise SystemExit(run_self_test(args.self_test, ContentEditor, RESOURCES))
    root = tk.Tk()
    ContentEditor(root, args.config)
    root.mainloop()


if __name__ == '__main__':
    main()
