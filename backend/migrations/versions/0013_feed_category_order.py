"""Persist manual category order and sync it to existing clients."""

import sqlalchemy as sa
from alembic import op

revision = "0013"
down_revision = "0012"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("feed_categories", sa.Column("position", sa.Integer(), nullable=False, server_default="0"))
    op.execute("""
        WITH ranked AS (
            SELECT id, row_number() OVER (PARTITION BY account_id ORDER BY name_key, id) - 1 AS position
            FROM feed_categories
        )
        UPDATE feed_categories SET position = (SELECT position FROM ranked WHERE ranked.id = feed_categories.id)
    """)
    op.execute("""
        INSERT INTO changes (account_id, kind, object_id, operation)
        SELECT account_id, 'feed_category', id, 'upsert' FROM feed_categories
    """)


def downgrade():
    op.drop_column("feed_categories", "position")
