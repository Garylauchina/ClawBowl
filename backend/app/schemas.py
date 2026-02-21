"""Pydantic request / response schemas."""

from datetime import datetime

from pydantic import BaseModel, Field


# ── Auth ──────────────────────────────────────────────────────────────

class RegisterRequest(BaseModel):
    username: str = Field(..., min_length=3, max_length=64)
    password: str = Field(..., min_length=6, max_length=128)


class LoginRequest(BaseModel):
    username: str
    password: str


class TokenResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    user_id: str


# ── Chat History ──────────────────────────────────────────────────────

class ChatHistoryRequest(BaseModel):
    limit: int = Field(default=30, ge=1, le=500)
    before: str | None = None
    after: str | None = None


# ── Instance ──────────────────────────────────────────────────────────

class InstanceStatusResponse(BaseModel):
    state: str
    port: int
    container_name: str
    created_at: datetime
    last_active_at: datetime


class MessageResponse(BaseModel):
    message: str
