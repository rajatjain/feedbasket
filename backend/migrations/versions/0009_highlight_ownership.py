"""Scope highlight UUIDs and their document references to an account."""

import sqlalchemy as sa
from alembic import op

revision = "0009"
down_revision = "0008"
branch_labels = None
depends_on = None


def replace_highlights(*, scoped):
    op.rename_table("highlights", "previous_highlights")
    op.drop_index("ix_highlights_article_id", table_name="previous_highlights")
    ownership = (
        sa.Column("account_id", sa.String(36), primary_key=True),
        sa.Column("article_id", sa.String(36), nullable=False),
        sa.ForeignKeyConstraint(("account_id", "article_id"), ("articles.account_id", "articles.id"), ondelete="CASCADE"),
    ) if scoped else (
        sa.Column("article_id", sa.String(36), sa.ForeignKey("articles.id", ondelete="CASCADE"), nullable=False),
    )
    op.create_table(
        "highlights", *ownership,
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("style", sa.String(16), nullable=False),
        sa.Column("quote", sa.Text(), nullable=False),
        sa.Column("color", sa.String(16), nullable=False),
        sa.Column("anchor", sa.JSON(), nullable=False),
        sa.Column("created_at", sa.BigInteger(), nullable=False),
    )
    columns = "id, article_id, style, quote, color, anchor, created_at"
    if scoped:
        previous = ", ".join(f"previous_highlights.{column}" for column in columns.split(", "))
        op.execute(f"INSERT INTO highlights (account_id, {columns}) "
                   f"SELECT articles.account_id, {previous} FROM previous_highlights "
                   "JOIN articles ON articles.id = previous_highlights.article_id")
    else:
        op.execute(f"INSERT INTO highlights ({columns}) SELECT {columns} FROM previous_highlights")
    op.drop_table("previous_highlights")
    op.create_index("ix_highlights_article_id", "highlights", ["article_id"])


def upgrade():
    op.add_column("articles", sa.Column("submitted_url", sa.Text()))
    op.create_index("ix_articles_account_id_document", "articles", ["account_id", "id"], unique=True)
    replace_highlights(scoped=True)


def downgrade():
    if op.get_bind().scalar(sa.text("SELECT 1 FROM highlights GROUP BY id HAVING count(*) > 1 LIMIT 1")):
        raise RuntimeError("Cannot downgrade while different accounts share highlight UUIDs.")
    replace_highlights(scoped=False)
    op.drop_index("ix_articles_account_id_document", table_name="articles")
    op.drop_column("articles", "submitted_url")
