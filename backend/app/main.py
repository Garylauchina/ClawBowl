"""ClawBowl Orchestrator – FastAPI application entry point."""

from __future__ import annotations

import asyncio
import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.config import settings
from app.database import Base, engine
from app.routers import auth_router, chat_router, cron_router, file_router, instance_router, notification_router
from app.services.instance_manager import instance_manager

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(name)s] %(levelname)s %(message)s",
)
logger = logging.getLogger("clawbowl")


async def _idle_reaper() -> None:
    """Background loop that stops idle OpenClaw containers."""
    while True:
        try:
            stopped = await instance_manager.stop_idle_instances()
            if stopped:
                logger.info("Idle reaper stopped %d instance(s)", stopped)
        except Exception:
            logger.exception("Idle reaper error")
        await asyncio.sleep(300)  # Check every 5 minutes


async def _health_checker() -> None:
    """Background loop that checks running container health."""
    while True:
        try:
            results = await instance_manager.health_check_all()
            unhealthy = [k for k, v in results.items() if v != "healthy"]
            if unhealthy:
                logger.warning("Unhealthy instances: %s", unhealthy)
        except Exception:
            logger.exception("Health checker error")
        await asyncio.sleep(60)  # Check every minute


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application startup / shutdown lifecycle."""
    # Create tables (in production, use Alembic migrations instead)
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    logger.info("ClawBowl Orchestrator starting up")
    logger.info("Database: %s", settings.database_url)
    logger.info("OpenClaw port range: %d-%d", settings.openclaw_port_range_start, settings.openclaw_port_range_end)

    # Start background tasks
    from app.services.alert_monitor import alert_monitor_loop
    idle_task = asyncio.create_task(_idle_reaper())
    health_task = asyncio.create_task(_health_checker())
    alert_task = asyncio.create_task(alert_monitor_loop())

    yield

    # Shutdown
    idle_task.cancel()
    health_task.cancel()
    alert_task.cancel()
    logger.info("ClawBowl Orchestrator shutting down")


app = FastAPI(
    title="ClawBowl Orchestrator",
    description="Single-user OpenClaw instance orchestrator",
    version="0.1.0",
    lifespan=lifespan,
)

# CORS – allow iOS app and web clients
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Register routers
app.include_router(auth_router.router)
app.include_router(chat_router.router)
app.include_router(file_router.router)
app.include_router(instance_router.router)
app.include_router(cron_router.router)
app.include_router(notification_router.router)


@app.get("/healthz")
async def healthz():
    return {"status": "ok"}
