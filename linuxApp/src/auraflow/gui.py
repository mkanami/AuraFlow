from __future__ import annotations

import sys
from collections.abc import Callable
from pathlib import Path

from PySide6.QtCore import (
    QObject,
    QRunnable,
    QSignalBlocker,
    QSize,
    Qt,
    QThreadPool,
    QTimer,
    QUrl,
    Signal,
)
from PySide6.QtGui import QAction, QCloseEvent, QIcon, QMovie, QPixmap
from PySide6.QtMultimedia import QAudioOutput, QMediaPlayer
from PySide6.QtMultimediaWidgets import QVideoWidget
from PySide6.QtWidgets import (
    QApplication,
    QCheckBox,
    QComboBox,
    QDoubleSpinBox,
    QFileDialog,
    QFrame,
    QHBoxLayout,
    QLabel,
    QListWidget,
    QListWidgetItem,
    QMainWindow,
    QMenu,
    QMessageBox,
    QPushButton,
    QSizePolicy,
    QSplitter,
    QStackedWidget,
    QSystemTrayIcon,
    QVBoxLayout,
    QWidget,
)

from . import AuraFlowError, __version__
from .backends import diagnostics
from .desktop import DesktopIntegration
from .paths import AppPaths
from .service import Client
from .settings import MEDIA_EXTENSIONS, SettingsStore

ICON = Path(__file__).parent / "assets/icon.png"


class TaskSignals(QObject):
    succeeded = Signal(object)
    failed = Signal(str)
    finished = Signal()


class Task(QRunnable):
    def __init__(self, function: Callable):
        super().__init__()
        self.function = function
        self.signals = TaskSignals()

    def run(self):
        try:
            self.signals.succeeded.emit(self.function())
        except Exception as exc:
            self.signals.failed.emit(str(exc))
        finally:
            self.signals.finished.emit()


class Preview(QStackedWidget):
    def __init__(self):
        super().__init__()
        self.setMinimumSize(320, 220)
        self.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Expanding)
        self.scale_mode = Qt.AspectRatioMode.KeepAspectRatioByExpanding
        self.playback_speed = 1.0
        self.original = QPixmap()
        self.movie: QMovie | None = None
        self.kind = "empty"
        self.empty = QLabel("Choose a video, GIF, or image\nto preview your next wallpaper")
        self.empty.setWordWrap(True)
        self.empty.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.image = QLabel()
        self.image.setMinimumSize(1, 1)
        self.image.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Ignored)
        self.image.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.video = QVideoWidget()
        for widget in (self.empty, self.image, self.video):
            self.addWidget(widget)
        self.player = QMediaPlayer(self)
        self.audio = QAudioOutput(self)
        self.audio.setMuted(True)
        self.player.setAudioOutput(self.audio)
        self.player.setVideoOutput(self.video)
        self.player.setLoops(QMediaPlayer.Loops.Infinite)
        self.player.errorOccurred.connect(self._error)

    def open(self, path: Path):
        self.player.stop()
        self.player.setSource(QUrl())
        if self.movie:
            self.movie.stop()
            self.image.setMovie(None)
            self.movie = None
        self.original = QPixmap()
        if path.suffix.lower() == ".gif":
            self.kind = "gif"
            self.movie = QMovie(str(path))
            movie = self.movie
            movie.setSpeed(round(self.playback_speed * 100))
            movie.frameChanged.connect(lambda _: self._draw_image(movie.currentPixmap()))
            self.setCurrentWidget(self.image)
            self.movie.start()
        elif path.suffix.lower() in {".png", ".jpg", ".jpeg", ".webp", ".bmp", ".avif"}:
            self.kind = "image"
            self.original = QPixmap(str(path))
            self.setCurrentWidget(self.image)
            if self.original.isNull():
                self._error(None, "This image format is unavailable in the preview.")
            else:
                self._draw_image(self.original)
        else:
            self.kind = "video"
            self.setCurrentWidget(self.video)
            self.player.setSource(QUrl.fromLocalFile(str(path)))
            if self.isVisible():
                self.player.play()

    def set_scale(self, scale: str):
        self.scale_mode = {
            "fill": Qt.AspectRatioMode.KeepAspectRatioByExpanding,
            "fit": Qt.AspectRatioMode.KeepAspectRatio,
            "stretch": Qt.AspectRatioMode.IgnoreAspectRatio,
        }[scale]
        self.video.setAspectRatioMode(self.scale_mode)
        if not self.original.isNull():
            self._draw_image(self.original)

    def set_speed(self, speed: float):
        self.playback_speed = speed
        self.player.setPlaybackRate(speed)
        if self.movie:
            self.movie.setSpeed(round(speed * 100))

    def _draw_image(self, pixmap: QPixmap):
        if not pixmap.isNull():
            self.image.setPixmap(
                pixmap.scaled(
                    self.image.size(),
                    self.scale_mode,
                    Qt.TransformationMode.SmoothTransformation,
                )
            )

    def resizeEvent(self, event):
        super().resizeEvent(event)
        if not self.original.isNull():
            self._draw_image(self.original)

    def hideEvent(self, event):
        self.player.pause()
        if self.movie:
            self.movie.setPaused(True)
        super().hideEvent(event)

    def showEvent(self, event):
        super().showEvent(event)
        if self.kind == "video" and self.currentWidget() is self.video:
            self.player.play()
        if self.movie:
            self.movie.setPaused(False)

    def _error(self, _error, message):
        if self.kind == "video" and not self.player.source().isEmpty():
            self.player.stop()
        self.empty.setText(f"Preview unavailable\n{message}\n\nDesktop playback uses mpv.")
        self.setCurrentWidget(self.empty)


class MainWindow(QMainWindow):
    def __init__(self, paths: AppPaths):
        super().__init__()
        self.paths = paths
        self.store = SettingsStore(paths)
        self.desktop = DesktopIntegration(paths)
        self.client = Client(paths)
        self.pool = QThreadPool(self)
        self.pool.setMaxThreadCount(1)
        self.busy = False
        self.polling = False
        self.poll_task: Task | None = None
        self.quitting = False
        self.current_task: Task | None = None
        self.playback: dict = {"running": False, "paused": False}
        self.selected: Path | None = None
        self.setWindowTitle("AuraFlow")
        self.setWindowIcon(QIcon(str(ICON)))
        self.resize(1080, 730)
        self.setMinimumSize(800, 600)
        self.setAcceptDrops(True)
        self._build_ui()
        self._build_tray()
        self._load_library()
        self.timer = QTimer(self)
        self.timer.timeout.connect(self._poll)
        self.timer.start(1500)
        self._poll()

    def _build_ui(self):
        settings = self.store.load()
        container = QWidget()
        outer = QVBoxLayout(container)
        outer.setContentsMargins(28, 22, 28, 20)
        outer.setSpacing(18)
        heading = QHBoxLayout()
        icon = QLabel()
        icon.setPixmap(
            QPixmap(str(ICON)).scaled(
                QSize(48, 48),
                Qt.AspectRatioMode.KeepAspectRatio,
                Qt.TransformationMode.SmoothTransformation,
            )
        )
        heading.addWidget(icon)
        title = QLabel("AuraFlow")
        title.setObjectName("title")
        heading.addWidget(title)
        heading.addStretch()
        version = QLabel(f"LINUX  ·  {__version__}")
        version.setObjectName("muted")
        heading.addWidget(version)
        outer.addLayout(heading)

        splitter = QSplitter()
        library_panel = QWidget()
        library_layout = QVBoxLayout(library_panel)
        library_layout.setContentsMargins(0, 0, 12, 0)
        library_layout.addWidget(QLabel("YOUR WALLPAPERS"))
        self.library = QListWidget()
        self.library.setMinimumWidth(200)
        self.library.itemClicked.connect(self._select_item)
        library_layout.addWidget(self.library)
        self.open_button = QPushButton("＋  Add wallpaper…")
        self.open_button.clicked.connect(self._open_file)
        library_layout.addWidget(self.open_button)
        hint = QLabel("Local videos, GIFs, and images.\nYou can also drop a file here.")
        hint.setObjectName("muted")
        hint.setWordWrap(True)
        library_layout.addWidget(hint)
        splitter.addWidget(library_panel)

        main = QWidget()
        layout = QVBoxLayout(main)
        layout.setContentsMargins(8, 0, 0, 0)
        self.preview_title = QLabel("PREVIEW")
        layout.addWidget(self.preview_title)
        self.preview = Preview()
        self.preview.set_scale(settings.scale)
        self.preview.set_speed(settings.speed)
        layout.addWidget(self.preview, 1)
        self.filename = QLabel("No wallpaper selected")
        self.filename.setObjectName("filename")
        self.filename.setWordWrap(True)
        layout.addWidget(self.filename)

        actions = QHBoxLayout()
        self.start_button = QPushButton("Start wallpaper")
        self.start_button.setObjectName("primary")
        self.start_button.clicked.connect(self._start)
        self.pause_button = QPushButton("Pause")
        self.pause_button.clicked.connect(self._pause)
        self.remove_button = QPushButton("Remove")
        self.remove_button.clicked.connect(lambda: self._command("remove"))
        for button in (self.start_button, self.pause_button, self.remove_button):
            actions.addWidget(button)
        layout.addLayout(actions)

        preferences = QFrame()
        preferences.setObjectName("preferences")
        prefs = QVBoxLayout(preferences)
        row = QHBoxLayout()
        row.addWidget(QLabel("Scale"))
        self.scale = QComboBox()
        for label, value in (("Fill", "fill"), ("Fit", "fit"), ("Stretch", "stretch")):
            self.scale.addItem(label, value)
        self.scale.setCurrentIndex(self.scale.findData(settings.scale))
        self.scale.currentIndexChanged.connect(self._scale_changed)
        row.addWidget(self.scale)
        row.addSpacing(12)
        row.addWidget(QLabel("Speed"))
        self.speed = QDoubleSpinBox()
        self.speed.setRange(0.1, 4)
        self.speed.setSingleStep(0.1)
        self.speed.setDecimals(2)
        self.speed.setSuffix(" ×")
        self.speed.setValue(settings.speed)
        self.speed.editingFinished.connect(self._speed_changed)
        row.addWidget(self.speed)
        row.addStretch()
        prefs.addLayout(row)
        backend_row = QHBoxLayout()
        backend_row.addWidget(QLabel("Desktop backend"))
        self.backend = QComboBox()
        for label, value in (
            ("Automatic", "auto"),
            ("X11 · mpv", "x11"),
            ("Wayland · mpvpaper", "wayland"),
        ):
            self.backend.addItem(label, value)
        self.backend.setCurrentIndex(self.backend.findData(settings.backend))
        self.backend.currentIndexChanged.connect(self._backend_changed)
        self.backend.setToolTip("Used the next time you press Start.")
        backend_row.addWidget(self.backend)
        prefs.addLayout(backend_row)
        self.autostart = QCheckBox("Launch AuraFlow at login")
        self.autostart.setChecked(self.desktop.autostart_enabled())
        self.autostart.toggled.connect(self._autostart_changed)
        prefs.addWidget(self.autostart)
        lock_note = QLabel("Lock Screen playback is not available in this Linux version.")
        lock_note.setObjectName("muted")
        lock_note.setWordWrap(True)
        prefs.addWidget(lock_note)
        layout.addWidget(preferences)
        splitter.addWidget(main)
        splitter.setStretchFactor(1, 1)
        splitter.setSizes([240, 760])
        outer.addWidget(splitter, 1)
        self.status_label = QLabel("Ready")
        self.status_label.setWordWrap(True)
        outer.addWidget(self.status_label)
        self.compatibility = QLabel()
        self.compatibility.setObjectName("muted")
        self.compatibility.setWordWrap(True)
        self._update_compatibility()
        outer.addWidget(self.compatibility)
        self.setCentralWidget(container)
        menu = self.menuBar().addMenu("File")
        open_action = menu.addAction("Add wallpaper…")
        open_action.setShortcut("Ctrl+O")
        open_action.triggered.connect(self._open_file)
        menu.addSeparator()
        quit_action = menu.addAction("Quit AuraFlow")
        quit_action.setShortcut("Ctrl+Q")
        quit_action.triggered.connect(self._quit)

    def _build_tray(self):
        self.tray = QSystemTrayIcon(QIcon(str(ICON)), self)
        menu = QMenu(self)
        show = menu.addAction("Open AuraFlow")
        show.triggered.connect(self._show)
        self.tray_pause = QAction("Pause", self)
        self.tray_pause.triggered.connect(self._pause)
        menu.addAction(self.tray_pause)
        remove = menu.addAction("Remove wallpaper")
        remove.triggered.connect(lambda: self._command("remove"))
        menu.addSeparator()
        quit_action = menu.addAction("Quit AuraFlow")
        quit_action.triggered.connect(self._quit)
        self.tray.setContextMenu(menu)
        self.tray.setToolTip("AuraFlow")
        self.tray.activated.connect(
            lambda reason: (
                self._show() if reason == QSystemTrayIcon.ActivationReason.Trigger else None
            )
        )
        if QSystemTrayIcon.isSystemTrayAvailable():
            self.tray.show()

    def _load_library(self):
        settings = self.store.load()
        self.library.clear()
        for media in settings.recent:
            path = Path(media)
            item = QListWidgetItem(path.name)
            item.setToolTip(str(path))
            item.setData(Qt.ItemDataRole.UserRole, media)
            self.library.addItem(item)
            if settings.selected == media:
                self.library.setCurrentItem(item)
        if settings.selected and Path(settings.selected).is_file():
            self._preview_file(Path(settings.selected))
        self._update_buttons()

    def _open_file(self):
        patterns = " ".join("*" + extension for extension in sorted(MEDIA_EXTENSIONS))
        filename, _ = QFileDialog.getOpenFileName(
            self, "Choose wallpaper", "", f"Media ({patterns})"
        )
        if filename:
            self._select_file(filename)

    def _select_item(self, item):
        self._select_file(item.data(Qt.ItemDataRole.UserRole))

    def _select_file(self, value):
        try:
            self.store.select(value)
            self._load_library()
        except (AuraFlowError, OSError) as exc:
            self._error(str(exc))

    def _preview_file(self, path: Path):
        self.selected = path
        self.filename.setText(path.name)
        self.filename.setToolTip(str(path))
        self.preview.open(path)

    def _start(self):
        if self.selected:
            self._command("start", media=str(self.selected))

    def _pause(self):
        self._command("resume" if self.playback.get("paused") else "pause")

    def _command(self, action, **values):
        self._async(lambda: self.client.request(action, **values), self._apply_status)

    def _poll(self):
        if self.busy or self.polling:
            return
        self.polling = True
        task = Task(lambda: self.client.request("status"))
        self.poll_task = task
        task.signals.succeeded.connect(self._apply_poll_status)
        task.signals.failed.connect(self._quiet_error)
        task.signals.finished.connect(self._poll_finished)
        self.pool.start(task)

    def _apply_poll_status(self, status):
        if not self.busy:
            self._apply_status(status)

    def _poll_finished(self):
        self.polling = False
        self.poll_task = None

    def _async(self, function, callback, *, quiet=False):
        if self.busy:
            return
        self.busy = True
        self._update_buttons()
        task = Task(function)
        self.current_task = task
        task.signals.succeeded.connect(callback)
        task.signals.failed.connect(self._quiet_error if quiet else self._error)
        task.signals.finished.connect(self._finished)
        self.pool.start(task)

    def _finished(self):
        self.busy = False
        self.current_task = None
        self._update_buttons()

    def _apply_status(self, status):
        self.playback = status
        self.pause_button.setText("Resume" if status.get("paused") else "Pause")
        self.tray_pause.setText(self.pause_button.text())
        if status.get("running"):
            state = "Paused" if status.get("paused") else "Playing"
            name = Path(status["media"]).name
            self.status_label.setText(f"{state} · {name} · {status['backend']}")
        else:
            self.status_label.setText(
                status.get("error") or "Ready · Your system wallpaper is visible"
            )
        if not self.speed.hasFocus():
            with QSignalBlocker(self.speed):
                self.speed.setValue(status["speed"])
        with QSignalBlocker(self.scale):
            self.scale.setCurrentIndex(self.scale.findData(status["scale"]))
        self.preview.set_scale(status["scale"])
        self.preview.set_speed(status["speed"])
        self._update_buttons()

    def _update_buttons(self):
        self.start_button.setEnabled(self.selected is not None and not self.busy)
        self.pause_button.setEnabled(bool(self.playback.get("running")) and not self.busy)
        self.remove_button.setEnabled(not self.busy)
        self.scale.setEnabled(not self.busy)
        self.speed.setEnabled(not self.busy)
        self.backend.setEnabled(not self.busy)
        self.library.setEnabled(not self.busy)
        self.open_button.setEnabled(not self.busy)
        if hasattr(self, "tray_pause"):
            self.tray_pause.setEnabled(bool(self.playback.get("running")) and not self.busy)

    def _scale_changed(self):
        self._command("scale", value=self.scale.currentData())

    def _speed_changed(self):
        if self.speed.value() != self.store.load().speed:
            self._command("speed", value=self.speed.value())

    def _backend_changed(self):
        try:
            self.store.update(backend=self.backend.currentData())
            self._update_compatibility()
        except (AuraFlowError, OSError) as exc:
            self._error(str(exc))

    def _update_compatibility(self):
        result = diagnostics(self.store.load().backend)
        self.compatibility.setText(
            f"Desktop: {result['backend']} · Audio off"
            if result.get("available")
            else str(result.get("error", ""))
        )

    def _autostart_changed(self, enabled):
        try:
            self.desktop.set_autostart(enabled)
        except (AuraFlowError, OSError) as exc:
            with QSignalBlocker(self.autostart):
                self.autostart.setChecked(self.desktop.autostart_enabled())
            self._error(str(exc))

    def _error(self, message):
        QMessageBox.warning(self, "AuraFlow", message)

    def _quiet_error(self, message):
        self.status_label.setText(message)

    def _show(self):
        self.showNormal()
        self.raise_()
        self.activateWindow()

    def _quit(self):
        if not self.busy:
            self.timer.stop()
            self._async(lambda: self.client.request("shutdown"), self._finish_quit)

    def _finish_quit(self, _status):
        self.quitting = True
        self.preview.player.stop()
        self.tray.hide()
        QApplication.instance().quit()

    def closeEvent(self, event: QCloseEvent):
        if self.tray.isVisible() and not self.quitting:
            self.hide()
            event.ignore()
        else:
            self.timer.stop()
            self.pool.waitForDone(30000)
            event.accept()

    def dragEnterEvent(self, event):
        urls = event.mimeData().urls()
        if not self.busy and urls and urls[0].isLocalFile():
            event.acceptProposedAction()

    def dropEvent(self, event):
        urls = event.mimeData().urls()
        if not self.busy and urls and urls[0].isLocalFile():
            self._select_file(urls[0].toLocalFile())
            event.acceptProposedAction()


STYLE = """
QMainWindow, QWidget { background: #10151d; color: #e4eaf3; font-size: 13px; }
QLabel#title { font-size: 29px; font-weight: 650; }
QLabel#filename { font-size: 16px; font-weight: 600; padding: 4px 0; }
QLabel#muted { color: #93a3b8; font-size: 12px; }
QListWidget { background: #171f2b; border: 1px solid #293444; border-radius: 9px; padding: 5px; }
QListWidget::item { padding: 11px 8px; border-radius: 5px; }
QListWidget::item:selected { background: #253d50; color: #8de9e0; }
QPushButton { background: #263243; border: 1px solid #35445a;
              border-radius: 7px; padding: 10px 13px; }
QPushButton:hover { background: #32435a; }
QPushButton:disabled { color: #687589; background: #1b2532; border-color: #253040; }
QPushButton#primary { background: #5bd4c5; border-color: #5bd4c5;
                      color: #102321; font-weight: 650; }
QPushButton#primary:hover { background: #80e4d8; }
QPushButton#primary:disabled { background: #2a5e5d; color: #81a5a3; border-color: #2a5e5d; }
QComboBox, QDoubleSpinBox { background: #1d2938; border: 1px solid #35445a; border-radius: 5px;
                          padding: 6px 9px; min-height: 20px; }
QFrame#preferences { border: 1px solid #293444; border-radius: 9px; }
QStackedWidget { background: #080c12; border: 1px solid #293444; border-radius: 9px; }
QStackedWidget QLabel { background: #080c12; color: #93a3b8; }
QMenuBar { background: #10151d; }
QMenu { background: #1d2938; padding: 5px; }
QMenu::item:selected { background: #32435a; }
QSplitter::handle { background: #10151d; width: 4px; }
QToolTip { background: #263243; color: #e4eaf3; border: 1px solid #35445a; }
"""


def run(paths: AppPaths) -> int:
    application = QApplication(sys.argv[:1])
    application.setApplicationName("AuraFlow")
    application.setDesktopFileName("io.github.mkanami.AuraFlow")
    application.setWindowIcon(QIcon(str(ICON)))
    application.setStyle("Fusion")
    application.setStyleSheet(STYLE)
    window = MainWindow(paths)
    window.show()
    return application.exec()
