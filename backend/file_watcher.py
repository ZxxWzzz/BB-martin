import asyncio
import json
import time
from pathlib import Path
from threading import Thread

from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler


class StateFileHandler(FileSystemEventHandler):
    def __init__(self, state_path: Path, callback):
        self.state_path = state_path
        self.callback = callback
        self.loop: asyncio.AbstractEventLoop = None
        self._last_read = 0

    def on_modified(self, event):
        if event.is_directory:
            return
        if Path(event.src_path).name != "bb_martin_state.json":
            return
        now = time.time()
        if now - self._last_read < 0.5:
            return
        self._last_read = now
        self._read_and_notify()

    def _read_and_notify(self):
        try:
            text = self.state_path.read_text(encoding="utf-8")
            data = json.loads(text)
            if self.loop and self.loop.is_running():
                asyncio.run_coroutine_threadsafe(self.callback(data), self.loop)
        except (json.JSONDecodeError, OSError, PermissionError):
            pass


class FileWatcher:
    def __init__(self, mql5_files_dir: Path, callback):
        self.mql5_files_dir = mql5_files_dir
        self.state_path = mql5_files_dir / "bb_martin_state.json"
        self.handler = StateFileHandler(self.state_path, callback)
        self.observer = Observer()

    def start(self):
        self.handler.loop = asyncio.get_event_loop()
        watch_path = str(self.mql5_files_dir)
        self.observer.schedule(self.handler, watch_path, recursive=False)
        self.observer.daemon = True
        self.observer.start()

    def stop(self):
        self.observer.stop()
        self.observer.join(timeout=2)
