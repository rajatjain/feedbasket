"""Add private Account ID credentials."""

from alembic import op
import sqlalchemy as sa

revision = "0002"
down_revision = "0001"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "account_keys",
        sa.Column("account_id", sa.String(36), sa.ForeignKey("accounts.id", ondelete="CASCADE"), primary_key=True),
        sa.Column("digest", sa.String(64), nullable=False, unique=True),
    )


def downgrade():
    op.drop_table("account_keys")
