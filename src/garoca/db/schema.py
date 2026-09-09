from pathlib import Path
from connection import get_connection

ROOT_DIR = Path(__file__).resolve().parent.parent.parent.parent
schema_file = ROOT_DIR / "src" / "garoca" / "db" / "schema.sql"
db_path = ROOT_DIR / "data" / "garoca.db"

duckdb_instance = get_connection()


def create_database():
    with duckdb_instance as con:
        with open(schema_file, "r") as f:
            schema_sql = f.read()
        con.sql(schema_sql)
