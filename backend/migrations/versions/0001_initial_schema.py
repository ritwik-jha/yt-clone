"""Initial schema: users, videos, and their enums.

Revision ID: 0001
Revises:
Create Date: 2026-09-30
"""

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision = "0001"
down_revision = None
branch_labels = None
depends_on = None

visibility_enum = postgresql.ENUM(
    "PUBLIC", "PRIVATE", "UNLISTED", name="visibility_enum", create_type=False,
)
status_enum = postgresql.ENUM(
    "PENDING", "PROCESSING", "COMPLETED", "FAILED", name="status_enum", create_type=False,
)


def _timestamps() -> list[sa.Column]:
    return [
        sa.Column("created_at", sa.DateTime(timezone=True),
                  server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True),
                  server_default=sa.func.now(), nullable=False),
    ]


def upgrade() -> None:
    bind = op.get_bind()
    visibility_enum.create(bind)
    status_enum.create(bind)

    op.create_table(
        "users",
        sa.Column("id", sa.Uuid(), server_default=sa.text("gen_random_uuid()"), nullable=False),
        sa.Column("name", sa.String(100), nullable=False),
        sa.Column("email", sa.String(255), nullable=False),
        sa.Column("cognito_sub", sa.String(255), nullable=False),
        *_timestamps(),
        sa.PrimaryKeyConstraint("id", name="pk_users"),
        sa.UniqueConstraint("email", name="uq_users_email"),
        sa.UniqueConstraint("cognito_sub", name="uq_users_cognito_sub"),
    )

    op.create_table(
        "videos",
        sa.Column("id", sa.Uuid(), server_default=sa.text("gen_random_uuid()"), nullable=False),
        sa.Column("title", sa.String(150), nullable=False),
        sa.Column("description", sa.Text(), nullable=True),
        sa.Column("s3_key", sa.String(500), nullable=False),
        sa.Column("thumbnail_s3_key", sa.String(500), nullable=False),
        sa.Column("dash_manifest_s3_key", sa.String(500), nullable=True),
        sa.Column("visibility", visibility_enum, server_default="PUBLIC", nullable=False),
        sa.Column("status", status_enum, server_default="PENDING", nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("views_count", sa.BigInteger(), server_default=sa.text("0"), nullable=False),
        sa.Column("duration_seconds", sa.Integer(), nullable=True),
        *_timestamps(),
        sa.PrimaryKeyConstraint("id", name="pk_videos"),
        sa.UniqueConstraint("s3_key", name="uq_videos_s3_key"),
        sa.ForeignKeyConstraint(
            ["user_id"], ["users.id"],
            name="fk_videos_user_id_users", ondelete="CASCADE",
        ),
    )
    for column in ("title", "visibility", "status", "user_id", "created_at"):
        op.create_index(f"ix_videos_{column}", "videos", [column])


def downgrade() -> None:
    op.drop_table("videos")
    op.drop_table("users")
    bind = op.get_bind()
    status_enum.drop(bind)
    visibility_enum.drop(bind)
