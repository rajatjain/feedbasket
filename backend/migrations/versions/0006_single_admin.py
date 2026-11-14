"""Remove reader admin roles while preserving existing Google reader access."""

import sqlalchemy as sa
from alembic import op

revision = "0006"
down_revision = "0005"
branch_labels = None
depends_on = None


def upgrade():
    op.execute(sa.text("""
        INSERT OR IGNORE INTO allowed_accounts (email)
        SELECT email FROM accounts
        WHERE admin = 1 AND google_sub NOT LIKE 'local:%'
    """))
    op.drop_column("accounts", "admin")


def downgrade():
    op.add_column("accounts", sa.Column("admin", sa.Boolean(), nullable=False, server_default=sa.false()))
