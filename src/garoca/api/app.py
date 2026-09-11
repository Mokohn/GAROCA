from fastapi import FastAPI
from contextlib import asynccontextmanager
from typing import AsyncGenerator
from garoca.db.connection import get_connection
from garoca.db.schema import create_database
from garoca.api.routes import health


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncGenerator:
    # Create the database connection
    app.state.db = get_connection()
    create_database(app.state.db)
    yield
    # Close the database connection
    app.state.db.close()


app = FastAPI(lifespan=lifespan)
app.include_router(health.router)

