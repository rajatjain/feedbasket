"""Store a custom subscription name separately from its publisher title."""

import sqlalchemy as sa
from alembic import op

revision = "0007"
down_revision = "0006"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("feeds", sa.Column("custom_title", sa.Text()))


def downgrade():
    op.drop_column("feeds", "custom_title")
