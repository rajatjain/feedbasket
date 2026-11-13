"""Track website subscriptions and their last observed content."""

import sqlalchemy as sa
from alembic import op

revision = "0005"
down_revision = "0004"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("feeds", sa.Column("kind", sa.String(16), nullable=False, server_default="feed"))
    op.add_column("feeds", sa.Column("page_digest", sa.String(64)))


def downgrade():
    op.drop_column("feeds", "page_digest")
    op.drop_column("feeds", "kind")
