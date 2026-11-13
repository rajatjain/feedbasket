"""Store an independent star on each article."""

from alembic import op
import sqlalchemy as sa

revision = "0003"
down_revision = "0002"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("articles", sa.Column("starred", sa.Boolean(), nullable=False, server_default=sa.false()))
    op.add_column("articles", sa.Column("starred_at", sa.BigInteger(), nullable=False, server_default="0"))


def downgrade():
    op.drop_column("articles", "starred_at")
    op.drop_column("articles", "starred")
