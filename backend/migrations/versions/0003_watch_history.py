"""watch_history: one row per (user, video) with the latest progress.

Additive only, like 0002, so API tasks still on 0002 code keep working while
this deploy rolls out.

Revision ID: 0003
Revises: 0002
Create Date: 2026-10-24
"""

from alembic import op
import sqlalchemy as sa

revision = "0003"
down_revision = "0002"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "watch_history",
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("video_id", sa.Uuid(), nullable=False),
        sa.Column("position_seconds", sa.Integer(), nullable=False),
        sa.Column("duration_seconds", sa.Integer(), nullable=True),
        sa.Column("completed", sa.Boolean(), server_default=sa.text("false"), nullable=False),
        sa.Column("first_watched_at", sa.DateTime(timezone=True),
                  server_default=sa.func.now(), nullable=False),
        sa.Column("last_watched_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True),
                  server_default=sa.func.now(), nullable=False),
        sa.CheckConstraint("position_seconds >= 0",
                           name=op.f("ck_watch_history_position_nonneg")),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE",
                                name="fk_watch_history_user_id_users"),
        sa.ForeignKeyConstraint(["video_id"], ["videos.id"], ondelete="CASCADE",
                                name="fk_watch_history_video_id_videos"),
        sa.PrimaryKeyConstraint("user_id", "video_id", name="pk_watch_history"),
    )
    op.create_index(
        "ix_watch_history_user_id_last_watched", "watch_history",
        ["user_id", sa.text("last_watched_at DESC"), sa.text("video_id DESC")],
    )
    # Lets ON DELETE CASCADE from videos find the rows without a scan.
    op.create_index("ix_watch_history_video_id", "watch_history", ["video_id"])


def downgrade() -> None:
    op.drop_table("watch_history")
