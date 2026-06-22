import asyncio
import json
from pathlib import Path
from contextlib import asynccontextmanager

from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse
import uvicorn

from file_watcher import FileWatcher
from data_service import DataService

MQL5_FILES = Path(r"C:\Users\张兴旺\AppData\Roaming\MetaQuotes\Terminal\Common\Files")
FRONTEND_DIR = Path(__file__).parent.parent / "frontend"

ws_clients: set[WebSocket] = set()
data_service = DataService(MQL5_FILES)
file_watcher: FileWatcher = None


async def on_state_changed(state: dict):
    dead = set()
    for ws in ws_clients:
        try:
            await ws.send_json({"type": "state", "data": state})
        except Exception:
            dead.add(ws)
    ws_clients -= dead


@asynccontextmanager
async def lifespan(app: FastAPI):
    global file_watcher
    file_watcher = FileWatcher(MQL5_FILES, on_state_changed)
    file_watcher.start()
    yield
    file_watcher.stop()


app = FastAPI(lifespan=lifespan)


@app.websocket("/ws/state")
async def websocket_endpoint(ws: WebSocket):
    await ws.accept()
    ws_clients.add(ws)
    try:
        state = data_service.get_current_state()
        if state:
            await ws.send_json({"type": "state", "data": state})
        while True:
            await ws.receive_text()
    except WebSocketDisconnect:
        pass
    finally:
        ws_clients.discard(ws)


@app.get("/api/state")
def api_state():
    return data_service.get_current_state() or {}


@app.get("/api/trades")
def api_trades(limit: int = 100, offset: int = 0):
    trades = data_service.get_trades()
    return {"total": len(trades), "trades": trades[offset:offset+limit]}


@app.get("/api/stats")
def api_stats():
    return data_service.get_stats()


@app.get("/api/equity")
def api_equity(limit: int = 1440):
    points = data_service.get_equity()
    return {"total": len(points), "data": points[-limit:]}


@app.get("/")
def serve_index():
    return FileResponse(FRONTEND_DIR / "index.html")


app.mount("/css", StaticFiles(directory=FRONTEND_DIR / "css"), name="css")
app.mount("/js", StaticFiles(directory=FRONTEND_DIR / "js"), name="js")


if __name__ == "__main__":
    uvicorn.run("main:app", host="0.0.0.0", port=8877, reload=False)
