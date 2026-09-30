"""HLS manifest key on videos; transcode_results for early completions.

Additive only, so API and poller tasks still on 0001 code keep working
while this deploy rolls out.

Revision ID: 0002
Revises: 0001
Create Date: 2026-09-30
"""

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision = "0002"
down_revision = "0001"
branch_labels = None
depends_on = None

# Created by 0001.
status_enum = postgresql.ENUM(
    "PENDING", "PROCESSING", "COMPLETED", "FAILED", name="status_enum", create_type=False,
)


def upgrade() -> None:
    op.add_column("videos", sa.Column("hls_manifest_s3_key", sa.String(500), nullable=True))

    op.create_table(
        "transcode_results",
        sa.Column("raw_key", sa.String(500), nullable=False),
        sa.Column("status", status_enum, nullable=False),
        sa.Column("dash_manifest_s3_key", sa.String(500), nullable=True),
        sa.Column("hls_manifest_s3_key", sa.String(500), nullable=True),
        sa.Column("duration_seconds", sa.Integer(), nullable=True),
        sa.Column("error", sa.Text(), nullable=True),
        sa.Column("received_at", sa.DateTime(timezone=True),
                  server_default=sa.func.now(), nullable=False),
        sa.PrimaryKeyConstraint("raw_key", name="pk_transcode_results"),
    )


def downgrade() -> None:
    op.drop_table("transcode_results")
    op.drop_column("videos", "hls_manifest_s3_key")
