"""SQLAlchemy ORM models."""

import uuid
from datetime import datetime, timezone

from sqlalchemy import DateTime, Float, ForeignKey, Integer, String
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.database import Base


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


def _new_uuid() -> str:
    return str(uuid.uuid4())


class User(Base):
    __tablename__ = "users"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_new_uuid)
    username: Mapped[str] = mapped_column(String(64), unique=True, nullable=False, index=True)
    password_hash: Mapped[str] = mapped_column(String(128), nullable=False)
    subscription_tier: Mapped[str] = mapped_column(String(16), default="free")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow)
    last_active_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow)

    instance: Mapped["OpenClawInstance | None"] = relationship(
        back_populates="user", uselist=False, cascade="all, delete-orphan"
    )


class OpenClawInstance(Base):
    __tablename__ = "instances"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_new_uuid)
    user_id: Mapped[str] = mapped_column(
        String(36), ForeignKey("users.id", ondelete="CASCADE"), unique=True, nullable=False
    )
    container_id: Mapped[str | None] = mapped_column(String(64))
    container_name: Mapped[str] = mapped_column(String(64), unique=True, nullable=False)
    port: Mapped[int] = mapped_column(Integer, unique=True, nullable=False)
    state: Mapped[str] = mapped_column(String(16), default="creating")
    gateway_token: Mapped[str] = mapped_column(String(64), nullable=False)
    config_path: Mapped[str] = mapped_column(String(256), nullable=False)
    data_path: Mapped[str] = mapped_column(String(256), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow)
    last_active_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow)

    user: Mapped["User"] = relationship(back_populates="instance")
