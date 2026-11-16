"""Add account-owned feed categories."""

import sqlalchemy as sa
from alembic import op

revision = "0012"
down_revision = "0011"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "feed_categories",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("account_id", sa.String(36), sa.ForeignKey("accounts.id", ondelete="CASCADE"), nullable=False),
        sa.Column("name", sa.Text(), nullable=False),
        sa.Column("name_key", sa.Text(), nullable=False),
        sa.UniqueConstraint("account_id", "name_key", name="uq_feed_category_name"),
    )
    # SQLite can add a nullable reference in place, preserving existing feed entries.
    op.execute("ALTER TABLE feeds ADD COLUMN category_id VARCHAR(36) REFERENCES feed_categories(id) ON DELETE SET NULL")
    op.create_index("ix_feeds_category_id", "feeds", ["category_id"])


def downgrade():
    op.drop_index("ix_feeds_category_id", table_name="feeds")
    op.execute("ALTER TABLE feeds DROP COLUMN category_id")
    op.drop_table("feed_categories")
