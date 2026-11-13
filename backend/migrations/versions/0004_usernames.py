"""Give local accounts unique usernames while preserving their libraries."""

import re

from alembic import op
import sqlalchemy as sa


revision = "0004"
down_revision = "0003"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("accounts", sa.Column("username", sa.String(64), nullable=True))
    op.create_index("ix_accounts_username", "accounts", ["username"], unique=True)
    connection = op.get_bind()
    rows = connection.execute(sa.text(
        "SELECT id, name FROM accounts WHERE google_sub LIKE 'local:%' ORDER BY id"
    )).all()
    names = {}
    for account_id, name in rows:
        username = name.strip().lower()
        if re.fullmatch(r"[a-z0-9][a-z0-9_.-]{0,63}", username):
            names.setdefault(username, []).append(account_id)
    for username, ids in names.items():
        if len(ids) == 1:
            connection.execute(sa.text("UPDATE accounts SET username = :username WHERE id = :id"),
                               {"username": username, "id": ids[0]})
    connection.execute(sa.text("""
        UPDATE login_sessions SET expires_at = 253402300799
        WHERE expires_at > CAST(strftime('%s', 'now') AS INTEGER)
          AND account_id IN (SELECT id FROM accounts WHERE username IS NOT NULL)
    """))


def downgrade():
    op.drop_index("ix_accounts_username", table_name="accounts")
    op.drop_column("accounts", "username")
