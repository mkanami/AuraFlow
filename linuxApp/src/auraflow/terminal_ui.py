from __future__ import annotations

from PySide6.QtCore import Qt, QTimer, Signal
from PySide6.QtGui import QImage, QPixmap
from PySide6.QtWidgets import (
    QDialog,
    QFormLayout,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QListWidget,
    QListWidgetItem,
    QPushButton,
    QSpinBox,
    QSplitter,
    QVBoxLayout,
    QWidget,
)

from . import AuraFlowError
from .terminal import TerminalProducer
from .terminal_config import TerminalConfig, programs


class TerminalDialog(QDialog):
    selected = Signal(object)

    def __init__(self, paths, parent=None):
        super().__init__(parent)
        from .settings import SettingsStore

        self.store = SettingsStore(paths)
        self.producer = None
        self.preset = None
        self.setWindowTitle("Terminal Wallpapers · AuraFlow")
        self.resize(1080, 720)
        outer = QVBoxLayout(self)
        self.search = QLineEdit()
        self.search.setPlaceholderText("Search presets and installed programs…")
        self.search.textChanged.connect(self._programs)
        outer.addWidget(self.search)
        split = QSplitter()
        self.list = QListWidget()
        self.list.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self.list.currentItemChanged.connect(self._program_selected)
        split.addWidget(self.list)
        panel = QWidget()
        layout = QVBoxLayout(panel)
        self.preview = QLabel("Choose a preset or enter a command, then press Preview")
        self.preview.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.preview.setWordWrap(True)
        self.preview.setMinimumSize(400, 220)
        from PySide6.QtWidgets import QSizePolicy

        self.preview.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Expanding)
        layout.addWidget(self.preview, 1)
        self.command = QLineEdit()
        self.command.setPlaceholderText("Program and arguments, e.g. cmatrix -u 4")
        self.command.textEdited.connect(lambda: setattr(self, "preset", None))
        layout.addWidget(self.command)
        fields = QFormLayout()
        self.columns = self._spin(20, 200, 100)
        self.rows = self._spin(8, 80, 30)
        self.font_size = self._spin(8, 32, 16)
        self.fps = self._spin(1, 30, 20)
        self.background = QLineEdit("#0b0f16")
        self.foreground = QLineEdit("#dce6f2")
        for label, control in (
            ("Columns", self.columns),
            ("Rows", self.rows),
            ("Font size", self.font_size),
            ("Frames per second", self.fps),
            ("Background", self.background),
            ("Text", self.foreground),
        ):
            fields.addRow(label, control)
        layout.addLayout(fields)
        buttons = QHBoxLayout()
        preview = QPushButton("Preview")
        preview.clicked.connect(self.start_preview)
        stop = QPushButton("Stop preview")
        stop.clicked.connect(self.stop_preview)
        select = QPushButton("Select wallpaper")
        select.setObjectName("primary")
        select.clicked.connect(self.select_wallpaper)
        for button in (preview, stop, select):
            buttons.addWidget(button)
        layout.addLayout(buttons)
        self.message = QLabel(
            "Commands run as your user. Shell operators require an explicit shell command."
        )
        self.message.setWordWrap(True)
        layout.addWidget(self.message)
        split.addWidget(panel)
        split.setSizes([280, 800])
        outer.addWidget(split)
        self._programs()
        saved = self.store.load().terminal
        if saved:
            config = TerminalConfig.parse(saved)
            self.preset = config.preset
            self.command.setText(config.label)
            for key in ("columns", "rows", "font_size", "fps"):
                getattr(self, key).setValue(getattr(config, key))
            self.background.setText(config.background)
            self.foreground.setText(config.foreground)
        self.timer = QTimer(self)
        self.timer.setInterval(50)
        self.timer.timeout.connect(self._frame)

    @staticmethod
    def _spin(low, high, value):
        spin = QSpinBox()
        spin.setRange(low, high)
        spin.setValue(value)
        return spin

    def _programs(self):
        self.list.clear()
        for program in programs(self.search.text()):
            item = QListWidgetItem(
                program["title"] + ("" if program["installed"] else " · not installed")
            )
            item.setData(Qt.ItemDataRole.UserRole, program)
            item.setToolTip(
                program["command"] + "\n" + str(program["installed"] or "Not installed")
            )
            self.list.addItem(item)

    def _program_selected(self, item, _previous):
        if not item:
            return
        program = item.data(Qt.ItemDataRole.UserRole)
        self.preset = program["id"]
        self.command.setText(program["command"])
        self.message.setText(
            "Installed · " + str(program["installed"])
            if program["installed"]
            else f"Install {program['package'] or program['executable']} with your package manager."
        )

    def config(self):
        return TerminalConfig.from_command(
            self.command.text(),
            preset=self.preset,
            columns=self.columns.value(),
            rows=self.rows.value(),
            font_size=self.font_size.value(),
            fps=self.fps.value(),
            background=self.background.text(),
            foreground=self.foreground.text(),
        )

    def start_preview(self):
        try:
            config = self.config()
            config.executable()
            self.stop_preview()
            self.producer = TerminalProducer(config, self.store.load().speed)
            self.message.setText("Previewing · " + config.label)
            self.timer.start()
        except (AuraFlowError, OSError) as exc:
            self.message.setText(str(exc))

    def _frame(self):
        if not self.producer:
            return
        if self.producer.failure:
            self.message.setText(self.producer.failure)
            self.stop_preview()
            return
        data = self.producer.latest_frame
        if data:
            video = self.producer.format
            image = QImage(
                data, video.width, video.height, video.width * 3, QImage.Format.Format_RGB888
            )
            pixmap = QPixmap.fromImage(image.copy())
            self.preview.setPixmap(
                pixmap.scaled(
                    self.preview.size(),
                    Qt.AspectRatioMode.KeepAspectRatio,
                    Qt.TransformationMode.SmoothTransformation,
                )
            )

    def select_wallpaper(self):
        try:
            config = self.config()
            config.executable()
            self.store.select_terminal(config)
            self.selected.emit(config)
            self.message.setText(
                "Selected. Press Start in AuraFlow to apply this terminal wallpaper."
            )
        except (AuraFlowError, OSError) as exc:
            self.message.setText(str(exc))

    def stop_preview(self):
        self.timer.stop()
        if self.producer:
            previous, self.producer = self.producer, None
            previous.close()

    def hideEvent(self, event):
        self.stop_preview()
        super().hideEvent(event)
