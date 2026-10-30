from __future__ import annotations

import threading

from PySide6.QtCore import QSize, Qt, QThreadPool, QUrl, Signal
from PySide6.QtGui import QDesktopServices, QIcon, QPixmap
from PySide6.QtWidgets import (
    QComboBox,
    QDialog,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QListWidget,
    QListWidgetItem,
    QProgressBar,
    QPushButton,
    QSplitter,
    QVBoxLayout,
    QWidget,
)

from .catalog import BASES, SOURCES, Catalog, CatalogPage, Wallpaper
from .ui_tasks import Task


class CatalogDialog(QDialog):
    selected = Signal(str)

    def __init__(self, paths, preview_factory, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Wallpaper Catalog · AuraFlow")
        self.resize(1120, 760)
        self.catalog = Catalog(paths)
        self.pool = QThreadPool(self)
        self.pool.setMaxThreadCount(3)
        self.tasks = set()
        self.page_number, self.has_more = 1, False
        self.generation = 0
        self.closed = False
        self.transferring = False
        self.cancel = threading.Event()
        self.downloads = {}
        outer = QVBoxLayout(self)
        toolbar = QHBoxLayout()
        self.source = QComboBox()
        for key, label in SOURCES.items():
            self.source.addItem(label, key)
        self.source.addItem("Downloaded wallpapers", "downloaded")
        self.query = QLineEdit()
        self.query.setPlaceholderText("Search wallpapers…")
        search = QPushButton("Search")
        search.clicked.connect(self.search)
        self.query.returnPressed.connect(self.search)
        self.source.currentIndexChanged.connect(self.search)
        toolbar.addWidget(self.source)
        toolbar.addWidget(self.query, 1)
        toolbar.addWidget(search)
        outer.addLayout(toolbar)
        split = QSplitter()
        self.list = QListWidget()
        self.list.setViewMode(QListWidget.ViewMode.IconMode)
        self.list.setResizeMode(QListWidget.ResizeMode.Adjust)
        self.list.setMovement(QListWidget.Movement.Static)
        self.list.setIconSize(QSize(210, 118))
        self.list.setGridSize(QSize(235, 170))
        self.list.setWordWrap(True)
        self.list.currentItemChanged.connect(self._selection_changed)
        split.addWidget(self.list)
        detail = QWidget()
        layout = QVBoxLayout(detail)
        self.preview = preview_factory()
        layout.addWidget(self.preview, 1)
        self.title = QLabel("Choose a wallpaper")
        self.title.setWordWrap(True)
        layout.addWidget(self.title)
        self.preview_button = QPushButton("Preview")
        self.preview_button.clicked.connect(lambda: self.transfer(True))
        self.download_button = QPushButton("Download and select")
        self.download_button.setObjectName("primary")
        self.download_button.clicked.connect(lambda: self.transfer(False))
        self.source_button = QPushButton("Open source page")
        self.source_button.clicked.connect(self.open_source)
        for button in (self.preview_button, self.download_button, self.source_button):
            layout.addWidget(button)
        split.addWidget(detail)
        split.setSizes([700, 420])
        outer.addWidget(split, 1)
        footer = QHBoxLayout()
        self.previous = QPushButton("← Previous")
        self.next = QPushButton("Next →")
        self.previous.clicked.connect(lambda: self.turn_page(-1))
        self.next.clicked.connect(lambda: self.turn_page(1))
        self.page_label = QLabel("Page 1")
        footer.addWidget(self.previous)
        footer.addWidget(self.page_label)
        footer.addWidget(self.next)
        footer.addStretch()
        outer.addLayout(footer)
        progress_row = QHBoxLayout()
        self.progress = QProgressBar()
        self.progress.setRange(0, 100)
        self.progress.setValue(0)
        self.cancel_button = QPushButton("Cancel download")
        self.cancel_button.clicked.connect(lambda: self.cancel.set())
        self.cancel_button.setEnabled(False)
        progress_row.addWidget(self.progress, 1)
        progress_row.addWidget(self.cancel_button)
        outer.addLayout(progress_row)
        self.message = QLabel("Browse a source or reopen a downloaded wallpaper.")
        self.message.setWordWrap(True)
        outer.addWidget(self.message)
        self._buttons()

    def showEvent(self, event):
        super().showEvent(event)
        self.closed = False
        if not self.list.count():
            self.search()

    def search(self):
        if self.transferring:
            return
        self.page_number = 1
        self.load_page()

    def turn_page(self, delta):
        self.page_number += delta
        self.load_page()

    def load_page(self):
        self.generation += 1
        generation = self.generation
        self.downloads = {item.id: path for item, path in self.catalog.downloaded()}
        source, query = self.source.currentData(), self.query.text().strip()
        if source == "downloaded":
            items = [
                item
                for item, _ in self.catalog.downloaded()
                if query.casefold() in item.title.casefold()
            ]
            self._page_loaded(CatalogPage(items, False), generation)
            return
        cached = self.catalog.cached_page(source, query, self.page_number)
        if cached:
            self._page_loaded(cached, generation)
        self.message.setText("Loading catalog…")
        self.previous.setEnabled(False)
        self.next.setEnabled(False)
        page = self.page_number
        self._task(
            lambda: self.catalog.page(source, query, page),
            lambda result: self._page_loaded(result, generation),
            generation=generation,
            priority=5,
        )

    def _page_loaded(self, page, generation):
        if generation != self.generation or self.closed:
            return
        self.list.clear()
        self.has_more = page.has_more
        for wallpaper in page.items:
            item = QListWidgetItem(wallpaper.title)
            item.setData(Qt.ItemDataRole.UserRole, wallpaper)
            item.setToolTip(f"{wallpaper.title}\n{SOURCES[wallpaper.source]}\n{wallpaper.page_url}")
            self.list.addItem(item)
            if wallpaper.poster_url:
                self._task(
                    lambda w=wallpaper, g=generation: (
                        (w.id, self.catalog.poster(w))
                        if g == self.generation and not self.closed
                        else None
                    ),
                    lambda value, g=generation: self._poster_loaded(value, g),
                    quiet=True,
                )
        self.message.setText(
            f"{len(page.items)} wallpapers" + (" · offline cache" if page.cached else "")
        )
        self.page_label.setText(f"Page {self.page_number}")
        self._buttons()

    def _poster_loaded(self, value, generation):
        if not value or generation != self.generation or self.closed:
            return
        identity, data = value
        pixmap = QPixmap()
        if not pixmap.loadFromData(data):
            return
        pixmap = pixmap.scaled(
            210, 118, Qt.AspectRatioMode.KeepAspectRatio, Qt.TransformationMode.SmoothTransformation
        )
        for index in range(self.list.count()):
            item = self.list.item(index)
            if item.data(Qt.ItemDataRole.UserRole).id == identity:
                item.setIcon(QIcon(pixmap))
                break

    def wallpaper(self) -> Wallpaper | None:
        item = self.list.currentItem()
        return item.data(Qt.ItemDataRole.UserRole) if item else None

    def _selection_changed(self, *_):
        item = self.wallpaper()
        self.title.setText(
            f"{item.title}\n{SOURCES[item.source]}" if item else "Choose a wallpaper"
        )
        self._buttons()

    def _buttons(self):
        item = self.wallpaper()
        self.preview_button.setEnabled(bool(item) and not self.transferring)
        self.download_button.setEnabled(bool(item) and not self.transferring)
        self.source_button.setEnabled(bool(item) or self.source.currentData() in BASES)
        self.download_button.setText(
            "Select downloaded wallpaper"
            if item and item.id in self.downloads
            else "Download and select"
        )
        online = self.source.currentData() != "downloaded"
        self.previous.setEnabled(online and self.page_number > 1 and not self.transferring)
        self.next.setEnabled(online and self.has_more and not self.transferring)
        self.source.setEnabled(not self.transferring)
        self.query.setEnabled(not self.transferring)
        self.list.setEnabled(not self.transferring)

    def transfer(self, preview):
        item = self.wallpaper()
        if not item or self.transferring:
            return
        if item.id in self.downloads:
            path = self.downloads[item.id]
            if preview:
                self.preview.open(path)
            else:
                self.selected.emit(str(path))
            return
        self.transferring = True
        self.cancel = threading.Event()
        cancel = self.cancel
        self.cancel_button.setEnabled(True)
        self.message.setText("Resolving preview…" if preview else "Resolving original download…")
        self.progress.setRange(0, 0)
        self._buttons()
        task = Task(
            lambda: self.catalog.download(
                item,
                cancel=cancel,
                preview=preview,
                progress=lambda received, total: task.signals.progress.emit((received, total)),
            )
        )
        task.signals.progress.connect(self._progress)
        task.signals.succeeded.connect(lambda path: self._downloaded(item, path, preview))
        task.signals.failed.connect(self._failure)
        task.signals.finished.connect(self._transfer_finished)
        self._launch(task, priority=10)

    def _progress(self, value):
        received, total = value
        if total:
            self.progress.setRange(0, 100)
            self.progress.setValue(min(100, round(received * 100 / total)))
        self.message.setText(
            f"Downloaded {received / 1024 / 1024:.1f} MB"
            + (f" / {total / 1024 / 1024:.1f} MB" if total else "")
        )

    def _downloaded(self, item, path, preview):
        if self.closed:
            return
        self.preview.open(path)
        self.progress.setRange(0, 100)
        self.progress.setValue(100)
        if not preview:
            self.downloads[item.id] = path
            self.selected.emit(str(path))
        self.message.setText(
            "Preview ready"
            if preview
            else "Downloaded and selected. Press Start in AuraFlow to apply."
        )

    def _transfer_finished(self):
        self.transferring = False
        self.cancel_button.setEnabled(False)
        self._buttons()

    def open_source(self):
        item = self.wallpaper()
        if item:
            QDesktopServices.openUrl(QUrl(item.page_url))
        elif self.source.currentData() in BASES:
            QDesktopServices.openUrl(QUrl(BASES[self.source.currentData()]))

    def _task(self, function, callback, quiet=False, generation=None, priority=0):
        task = Task(function)
        task.signals.succeeded.connect(callback)
        if not quiet:
            task.signals.failed.connect(
                lambda message: (
                    self._failure(message)
                    if generation is None or generation == self.generation
                    else None
                )
            )
        self._launch(task, priority)

    def _launch(self, task, priority=0):
        self.tasks.add(task)
        task.signals.finished.connect(lambda: self.tasks.discard(task))
        self.pool.start(task, priority)

    def _failure(self, message):
        if not self.closed:
            self.message.setText(message)
            self.progress.setRange(0, 100)
            self._buttons()

    def closeEvent(self, event):
        self.closed = True
        self.generation += 1
        self.cancel.set()
        self.preview.player.stop()
        super().closeEvent(event)
