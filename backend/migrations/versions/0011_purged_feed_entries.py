"""Keep feed entry keys after Trash cleanup."""

import sqlalchemy as sa
from alembic import op

revision = "0011"
down_revision = "0010"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "purged_feed_entries",
        sa.Column("feed_id", sa.String(36), sa.ForeignKey("feeds.id", ondelete="CASCADE"), primary_key=True),
        sa.Column("key", sa.Text(), primary_key=True),
    )


def downgrade():
    op.drop_table("purged_feed_entries")
