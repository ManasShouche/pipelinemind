"""
File-system watcher for incremental re-indexing.
Uses watchdog to detect .py, .sql, .yml, .yaml, .md file changes
and emits events to a queue consumed by IngestionPipeline.
"""
from __future__ import annotations

import logging
import queue
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

from watchdog.events import FileSystemEventHandler, FileModifiedEvent, FileCreatedEvent
from watchdog.observers import Observer

logger = logging.getLogger(__name__)

WATCHED_EXTENSIONS = {".py", ".sql", ".yml", ".yaml", ".md", ".json"}


@dataclass
class FileChangeEvent:
    file_path: str
    event_type: Literal["created", "modified", "deleted"]


class _PipelineEventHandler(FileSystemEventHandler):
    def __init__(self, change_queue: queue.Queue[FileChangeEvent]) -> None:
        super().__init__()
        self._queue = change_queue

    def _handle(self, event_type: str, src_path: str) -> None:
        if Path(src_path).suffix not in WATCHED_EXTENSIONS:
            return
        self._queue.put(FileChangeEvent(file_path=src_path, event_type=event_type))  # type: ignore[arg-type]

    def on_modified(self, event: FileModifiedEvent) -> None:
        if not event.is_directory:
            self._handle("modified", event.src_path)

    def on_created(self, event: FileCreatedEvent) -> None:
        if not event.is_directory:
            self._handle("created", event.src_path)


class PipelineWatcher:
    """
    Watches a repository path for file changes and feeds them to a queue.
    Run start() in a background thread; consume the queue in the ingestion loop.
    """

    def __init__(self, watch_path: str | Path) -> None:
        self.watch_path = str(watch_path)
        self.change_queue: queue.Queue[FileChangeEvent] = queue.Queue()
        self._observer = Observer()
        self._stop_event = threading.Event()

    def start(self) -> None:
        handler = _PipelineEventHandler(self.change_queue)
        self._observer.schedule(handler, self.watch_path, recursive=True)
        self._observer.start()
        logger.info("File watcher started on %s", self.watch_path)

    def stop(self) -> None:
        self._observer.stop()
        self._observer.join()
        logger.info("File watcher stopped")

    def drain(self, timeout: float = 1.0) -> list[FileChangeEvent]:
        """Drain all available events from the queue (non-blocking)."""
        events: list[FileChangeEvent] = []
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                events.append(self.change_queue.get_nowait())
            except queue.Empty:
                break
        return events
