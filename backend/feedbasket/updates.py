import asyncio
from collections import defaultdict
from contextlib import asynccontextmanager


class SavedUpdates:
    """Coalesced wakeups. SQLite remains the source of truth for reconnects."""

    def __init__(self):
        self.loop = asyncio.get_running_loop()
        self.listeners = defaultdict(set)

    @asynccontextmanager
    async def subscribe(self, account_id):
        wakeup = asyncio.Event()
        listeners = self.listeners[account_id]
        listeners.add(wakeup)
        try:
            yield wakeup
        finally:
            listeners.remove(wakeup)
            if not listeners:
                del self.listeners[account_id]

    def publish(self, account_id):
        self.loop.call_soon_threadsafe(self._wake, account_id)

    def _wake(self, account_id):
        for wakeup in self.listeners.get(account_id, ()):
            wakeup.set()
