import duckdb
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent.parent.parent.parent
db_path = ROOT_DIR / "data" / "garoca.db"


def get_connection():
    return duckdb.connect(database=db_path, read_only=False)
