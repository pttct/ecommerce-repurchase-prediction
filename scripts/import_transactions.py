"""Reproducible one-time import of UCI Online Retail II into MySQL.

Run from any directory after executing sql/01_create_tables.sql:
    python scripts/import_transactions.py --check
    python scripts/import_transactions.py --execute   # ONLY on an empty raw table

Neither mode deletes or overwrites data. A partially populated raw table causes a
hard stop: do not attempt to resume by row count, because import ordering may differ.
"""

from __future__ import annotations

import argparse
import os
from getpass import getpass
from pathlib import Path

import pandas as pd
from sqlalchemy import create_engine, text
from sqlalchemy.engine import URL

PROJECT_ROOT = Path(__file__).resolve().parents[1]
RAW_PATH = PROJECT_ROOT / "data" / "raw" / "online_retail_II.xlsx"
PARQUET_PATH = PROJECT_ROOT / "data" / "interim" / "online_retail_ii_combined.parquet"
EXPECTED_ROWS = 1_067_371
SHEETS = ("Year 2009-2010", "Year 2010-2011")
SOURCE_LABELS = ("2009-2010", "2010-2011")

COLUMN_MAP = {
    "Invoice": "invoice",
    "StockCode": "stock_code",
    "Description": "description",
    "Quantity": "quantity",
    "InvoiceDate": "invoice_date",
    "Price": "price",
    "Customer ID": "customer_id",
    "Country": "country",
    "SourceYear": "source_year",
}


def mysql_engine():
    password = os.environ.get("MYSQL_PASSWORD")
    if password is None:
        password = getpass("MySQL password: ")
    url = URL.create(
        "mysql+pymysql",
        username=os.environ.get("MYSQL_USER", "ds_portfolio"),
        password=password,
        host=os.environ.get("MYSQL_HOST", "127.0.0.1"),
        port=int(os.environ.get("MYSQL_PORT", "3306")),
        database=os.environ.get("MYSQL_DATABASE", "ecommerce_repurchase"),
    )
    return create_engine(url, pool_pre_ping=True, connect_args={"connect_timeout": 10})


def load_source() -> pd.DataFrame:
    if not RAW_PATH.is_file():
        raise FileNotFoundError(f"Download the UCI dataset to {RAW_PATH}")

    frames = []
    for sheet, source_year in zip(SHEETS, SOURCE_LABELS):
        frame = pd.read_excel(RAW_PATH, sheet_name=sheet)
        frame["SourceYear"] = source_year
        frames.append(frame)

    combined = pd.concat(frames, ignore_index=True)
    if len(combined) != EXPECTED_ROWS:
        raise ValueError(f"Unexpected row count: {len(combined):,} (expected {EXPECTED_ROWS:,})")

    for column in ("Invoice", "StockCode", "Description"):
        combined[column] = combined[column].astype("string")

    PARQUET_PATH.parent.mkdir(parents=True, exist_ok=True)
    combined.to_parquet(PARQUET_PATH, index=False)
    imported = combined.rename(columns=COLUMN_MAP)
    imported["customer_id"] = imported["customer_id"].astype("Int64")
    return imported[list(COLUMN_MAP.values())]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--check", action="store_true", help="Inspect raw-table row count; do not import")
    group.add_argument("--execute", action="store_true", help="Import only if raw table is empty")
    args = parser.parse_args()

    engine = mysql_engine()
    try:
        with engine.connect() as conn:
            existing_rows = conn.execute(text("SELECT COUNT(*) FROM transactions_raw")).scalar_one()
        print(f"Current transactions_raw rows: {existing_rows:,}")

        if args.check:
            print("No changes made.")
            return
        if existing_rows != 0:
            raise RuntimeError(
                "Import aborted: transactions_raw is not empty. "
                "Never resume imports using only the existing row count. "
                "Use a new, empty database for reproduction."
            )

        df_import = load_source()
        print(f"Prepared {len(df_import):,} source rows. Importing into empty raw table...")
        # One transaction: failures roll back all inserted rows on InnoDB.
        with engine.begin() as conn:
            df_import.to_sql(
                name="transactions_raw",
                con=conn,
                if_exists="append",
                index=False,
                chunksize=1000,
                method=None,
            )
        with engine.connect() as conn:
            actual_rows = conn.execute(text("SELECT COUNT(*) FROM transactions_raw")).scalar_one()
        if actual_rows != EXPECTED_ROWS:
            raise RuntimeError(f"Post-import row-count mismatch: {actual_rows:,}")
        print(f"Import complete: {actual_rows:,} rows.")
    finally:
        engine.dispose()


if __name__ == "__main__":
    main()
