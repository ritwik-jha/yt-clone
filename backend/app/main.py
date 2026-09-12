"""FastAPI application entrypoint.

Run for local dev:
    uvicorn app.main:app --reload

Production (systemd unit uses this):
    uvicorn app.main:app --host 0.0.0.0 --port 8000 --workers 2
"""

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.config import get_settings
from app.routers import auth, upload, videos

settings = get_settings()

app = FastAPI(title="Video Platform Backend", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origin_list or ["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(auth.router)
app.include_router(upload.router)
app.include_router(videos.router)


@app.get("/healthz", tags=["meta"])
def health():
    return {"status": "ok"}
