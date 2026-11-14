"""Add the stored article word count."""

import sqlalchemy as sa
from alembic import op

revision = "0010"
down_revision = "0009"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("articles", sa.Column("word_count", sa.Integer()))


def downgrade():
    op.drop_column("articles", "word_count")
