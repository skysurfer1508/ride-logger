from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent.parent
TEMPLATES_DIR = BASE_DIR / "templates"
STATIC_DIR = BASE_DIR / "static"
SCHEMA_PATH = Path(__file__).resolve().parent / "schema.sql"
ENV_PATH = BASE_DIR / ".env"
