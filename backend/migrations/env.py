from alembic import context

from feedbasket.config import Config
from feedbasket.db import Base, make_engine


def migrate(connection):
    context.configure(connection=connection, target_metadata=Base.metadata, render_as_batch=True)
    with context.begin_transaction():
        context.run_migrations()


if context.is_offline_mode():
    raise RuntimeError("Run FeedBasket migrations against an open database")
elif connection := context.config.attributes.get("connection"):
    migrate(connection)
else:
    engine = make_engine(Config.load().db_path)
    try:
        with engine.begin() as connection:
            migrate(connection)
    finally:
        engine.dispose()
