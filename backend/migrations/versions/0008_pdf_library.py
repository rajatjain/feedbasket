"""Add PDF library metadata, reading positions, and highlights."""

import sqlalchemy as sa
from alembic import op

revision = "0008"
down_revision = "0007"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("accounts", sa.Column("pdf_quota", sa.BigInteger(), nullable=False, server_default="5000000000"))
    op.add_column("jobs", sa.Column("account_id", sa.String(36)))
    for column in (
        sa.Column("document_type", sa.String(16), nullable=False, server_default="article"),
        sa.Column("pdf_key", sa.Text()),
        sa.Column("pdf_filename", sa.Text()),
        sa.Column("pdf_bytes", sa.BigInteger(), nullable=False, server_default="0"),
        sa.Column("pdf_pages", sa.Integer()),
        sa.Column("pdf_import_id", sa.String(36)),
        sa.Column("pdf_digest", sa.String(64)),
        sa.Column("pdf_expires_at", sa.BigInteger()),
        sa.Column("reading_position", sa.JSON()),
        sa.Column("position_updated_at", sa.BigInteger(), nullable=False, server_default="0"),
    ):
        op.add_column("articles", column)
    op.create_index("ix_articles_account_pdf_import", "articles", ["account_id", "pdf_import_id"], unique=True)
    op.create_table(
        "highlights",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("article_id", sa.String(36), sa.ForeignKey("articles.id", ondelete="CASCADE"), nullable=False),
        sa.Column("style", sa.String(16), nullable=False),
        sa.Column("quote", sa.Text(), nullable=False),
        sa.Column("color", sa.String(16), nullable=False),
        sa.Column("anchor", sa.JSON(), nullable=False),
        sa.Column("created_at", sa.BigInteger(), nullable=False),
    )
    op.create_index("ix_highlights_article_id", "highlights", ["article_id"])
    op.execute("INSERT INTO changes (account_id, kind, object_id, operation) "
               "SELECT account_id, 'article', id, 'upsert' FROM articles WHERE content_status = 'pdf_unsupported'")
    op.execute("UPDATE articles SET document_type = 'pdf', content_status = 'ready' "
               "WHERE content_status = 'pdf_unsupported'")


def downgrade():
    if op.get_bind().scalar(sa.text("SELECT 1 FROM articles WHERE pdf_key IS NOT NULL LIMIT 1")):
        raise RuntimeError("Migration 0008 cannot be downgraded while PDF uploads reference R2 objects.")
    op.drop_index("ix_highlights_article_id", table_name="highlights")
    op.drop_table("highlights")
    op.drop_index("ix_articles_account_pdf_import", table_name="articles")
    op.execute("UPDATE articles SET content_status = 'pdf_unsupported' WHERE document_type = 'pdf' AND pdf_key IS NULL")
    for name in ("position_updated_at", "reading_position", "pdf_expires_at", "pdf_digest", "pdf_import_id",
                 "pdf_pages", "pdf_bytes", "pdf_filename", "pdf_key", "document_type"):
        op.drop_column("articles", name)
    op.drop_column("accounts", "pdf_quota")
    op.drop_column("jobs", "account_id")
