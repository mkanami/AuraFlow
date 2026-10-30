from PySide6.QtCore import QObject, QRunnable, Signal


class TaskSignals(QObject):
    succeeded = Signal(object)
    failed = Signal(str)
    progress = Signal(object)
    finished = Signal()


class Task(QRunnable):
    def __init__(self, function):
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
