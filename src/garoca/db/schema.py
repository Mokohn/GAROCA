from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent.parent.parent.parent
schema_file = ROOT_DIR / "src" / "garoca" / "db" / "schema.sql"


def create_database(con):
    with open(schema_file, "r") as f:
        schema_sql = f.read()
    con.sql(schema_sql)
