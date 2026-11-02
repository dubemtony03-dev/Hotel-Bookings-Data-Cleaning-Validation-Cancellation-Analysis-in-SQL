"""
Run the whole SQL pipeline:

    python run_pipeline.py

1. Loads data/raw/hotel_bookings.csv into SQLite as raw_bookings (every column TEXT, unmodified)
2. Executes sql/01_audit.sql, 02_clean.sql, 03_validate.sql, 04_eda.sql in order
3. Saves every named result set to results/<name>.csv
4. Stops with an error if any validation check fails
5. Exports data/cleaned/hotel_bookings_clean.csv.gz and draws the charts in images/

All of the cleaning, validation and analysis logic lives in the .sql files.
Python is only the loader, the runner and the chart drawer.
"""
import csv
import gzip
import re
import sqlite3
import sys
from pathlib import Path

ROOT = Path(__file__).parent
RAW_CSV = ROOT / "data" / "raw" / "hotel_bookings.csv"
DB_PATH = ROOT / "data" / "hotel_bookings.db"
SQL_DIR = ROOT / "sql"
RESULTS = ROOT / "results"
CLEAN_CSV = ROOT / "data" / "cleaned" / "hotel_bookings_clean.csv.gz"
IMAGES = ROOT / "images"

SQL_FILES = ["01_audit.sql", "02_clean.sql", "03_validate.sql", "04_eda.sql"]


def load_raw(conn):
    """Load the CSV as-is: every column TEXT, plus a row_id (file order) because the data has no booking ID."""
    csv.field_size_limit(sys.maxsize)
    with open(RAW_CSV, newline="", encoding="utf-8") as f:
        reader = csv.reader(f)
        header = [h.strip() for h in next(reader)]
        conn.execute("DROP TABLE IF EXISTS raw_bookings")
        cols = ", ".join(f'"{h}" TEXT' for h in header)
        conn.execute(f"CREATE TABLE raw_bookings (row_id INTEGER PRIMARY KEY, {cols})")
        marks = ",".join("?" * (len(header) + 1))
        conn.executemany(f"INSERT INTO raw_bookings VALUES ({marks})",
                         ((i, *r) for i, r in enumerate(reader, start=1)))
    n = conn.execute("SELECT COUNT(*) FROM raw_bookings").fetchone()[0]
    print(f"Loaded {n:,} rows into raw_bookings")


def split_statements(text):
    """Split a SQL script into (name, statement) pairs using sqlite3.complete_statement."""
    buf, out = "", []
    for line in text.splitlines(keepends=True):
        buf += line
        if sqlite3.complete_statement(buf):
            m = re.search(r"^--\s*name:\s*(\w+)", buf, flags=re.M)
            out.append((m.group(1) if m else None, buf.strip()))
            buf = ""
    return out


def run_sql_file(conn, path):
    print(f"\n=== {path.name} ===")
    for name, stmt in split_statements(path.read_text(encoding="utf-8")):
        cur = conn.execute(stmt)
        if name and cur.description:
            cols = [d[0] for d in cur.description]
            rows = cur.fetchall()
            with open(RESULTS / f"{name}.csv", "w", newline="", encoding="utf-8") as f:
                w = csv.writer(f)
                w.writerow(cols)
                w.writerows(rows)
            print(f"-- {name}: {len(rows)} rows")
    conn.commit()


def check_validation(conn):
    rows = conn.execute("SELECT check_name, expected, actual, status FROM validation_checks").fetchall()
    failed = [r for r in rows if r[3] != "PASS"]
    print(f"\nValidation: {len(rows) - len(failed)}/{len(rows)} checks passed")
    for r in failed:
        print(f"  FAIL  {r[0]}: expected {r[1]}, got {r[2]}")
    if failed:
        sys.exit("Validation failed. Fix the cleaning logic before using the results.")


def export_clean(conn):
    cur = conn.execute("SELECT * FROM bookings_clean")
    cols = [d[0] for d in cur.description]
    with gzip.open(CLEAN_CSV, "wt", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(cols)
        w.writerows(cur)
    print(f"Exported cleaned table to {CLEAN_CSV.relative_to(ROOT)}")


def draw_charts():
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import pandas as pd

    BLUE, ORANGE = "#1f6f8b", "#e07b39"
    r = lambda n: pd.read_csv(RESULTS / f"{n}.csv")

    def tidy(ax):
        ax.spines[["top", "right"]].set_visible(False)

    # 1. cancellation by lead time
    d = r("eda_cancel_by_lead_time")
    fig, ax = plt.subplots(figsize=(8.5, 4.4))
    ax.bar(d["lead_time_bucket"].str[3:], d["cancel_pct"], color=BLUE)
    for i, v in enumerate(d["cancel_pct"]):
        ax.text(i, v + 0.8, f"{v:.0f}%", ha="center", fontsize=9)
    ax.set_ylabel("% of bookings cancelled"); ax.set_ylim(0, d["cancel_pct"].max() * 1.18)
    ax.set_title("The earlier the booking, the more likely it is cancelled", loc="left", fontweight="bold"); tidy(ax)
    fig.savefig(IMAGES / "cancel_by_lead_time.png", dpi=150, bbox_inches="tight"); plt.close(fig)

    # 2. cancellation by segment and deposit
    seg = r("eda_cancel_by_segment").sort_values("cancel_pct")
    dep = r("eda_cancel_by_deposit").sort_values("cancel_pct")
    fig, axes = plt.subplots(1, 2, figsize=(11, 4.3))
    for ax, df, col, title in [(axes[0], seg, "market_segment", "By market segment"), (axes[1], dep, "deposit_type", "By deposit type")]:
        ax.barh(df[col], df["cancel_pct"], color=BLUE)
        for i, v in enumerate(df["cancel_pct"]):
            ax.text(v + 1, i, f"{v:.0f}%", va="center", fontsize=9)
        ax.set_xlim(0, 118); ax.set_title(title, loc="left", fontweight="bold"); ax.set_xlabel("% cancelled"); tidy(ax)
    fig.savefig(IMAGES / "cancel_by_segment_deposit.png", dpi=150, bbox_inches="tight"); plt.close(fig)

    # 3. seasonality
    vol = r("eda_seasonality_volume"); adr = r("eda_seasonality_adr")
    mn = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    fig, axes = plt.subplots(1, 2, figsize=(11, 4.2))
    for hotel, color in [("City Hotel", BLUE), ("Resort Hotel", ORANGE)]:
        v = vol[vol.hotel == hotel]; a = adr[adr.hotel == hotel]
        axes[0].plot(v["month"], v["bookings"], marker="o", ms=4, color=color, label=hotel)
        axes[1].plot(a["month"], a["median_adr"], marker="o", ms=4, color=color, label=hotel)
    for ax, t, yl in [(axes[0], "Bookings by arrival month (2016)", "Bookings"), (axes[1], "Median nightly rate by month", "Median rate (ADR)")]:
        ax.set_xticks(range(1, 13)); ax.set_xticklabels(mn, fontsize=8); ax.set_title(t, loc="left", fontweight="bold")
        ax.set_ylabel(yl); ax.legend(frameon=False); tidy(ax)
    fig.savefig(IMAGES / "seasonality.png", dpi=150, bbox_inches="tight"); plt.close(fig)

    # 4. cancellation by country
    c = r("eda_cancel_by_country").sort_values("cancel_pct")
    fig, ax = plt.subplots(figsize=(8.5, 4.6))
    colors = [ORANGE if v == c["cancel_pct"].max() else BLUE for v in c["cancel_pct"]]
    ax.barh(c["country"], c["cancel_pct"], color=colors)
    for i, (v, s) in enumerate(zip(c["cancel_pct"], c["share_pct"])):
        ax.text(v + 0.6, i, f"{v:.0f}%  ({s:.0f}% of bookings)", va="center", fontsize=8.5)
    ax.set_xlim(0, c["cancel_pct"].max() * 1.5); ax.set_xlabel("% cancelled")
    ax.set_title("Cancellation rate by guest country (countries with 1,500+ bookings)", loc="left", fontweight="bold"); tidy(ax)
    fig.savefig(IMAGES / "cancel_by_country.png", dpi=150, bbox_inches="tight"); plt.close(fig)

    # 5. value realised vs lost by segment
    v = r("eda_revenue_lost_by_segment").sort_values("realised_value")
    fig, ax = plt.subplots(figsize=(9, 4.4))
    ax.barh(v["market_segment"], v["realised_value"] / 1e6, color=BLUE, label="Realised (stayed)")
    ax.barh(v["market_segment"], v["lost_value"] / 1e6, left=v["realised_value"] / 1e6, color=ORANGE, label="Lost (cancelled / no-show)")
    for i, (a, l, p) in enumerate(zip(v["realised_value"], v["lost_value"], v["lost_pct"])):
        ax.text((a + l) / 1e6 + 0.1, i, f"{p:.0f}% lost", va="center", fontsize=9)
    ax.set_xlabel("Booked value, millions (nightly rate x nights)"); ax.legend(frameon=False, loc="lower right")
    ax.set_title("Booked value by market segment", loc="left", fontweight="bold")
    ax.set_xlim(0, (v["realised_value"] + v["lost_value"]).max() / 1e6 * 1.18); tidy(ax)
    fig.savefig(IMAGES / "value_by_segment.png", dpi=150, bbox_inches="tight"); plt.close(fig)

    # 6. special requests
    s = r("eda_cancel_by_special_requests")
    fig, ax = plt.subplots(figsize=(7, 4))
    ax.bar(["0", "1", "2", "3 or more"], s["cancel_pct"], color=BLUE)
    for i, p in enumerate(s["cancel_pct"]):
        ax.text(i, p + 0.6, f"{p:.0f}%", ha="center", fontsize=9)
    ax.set_xlabel("Special requests made"); ax.set_ylabel("% cancelled"); ax.set_ylim(0, s["cancel_pct"].max() * 1.2)
    ax.set_title("Guests who make requests rarely cancel", loc="left", fontweight="bold"); tidy(ax)
    fig.savefig(IMAGES / "cancel_by_special_requests.png", dpi=150, bbox_inches="tight"); plt.close(fig)
    print("Charts saved to images/")


def main():
    RESULTS.mkdir(exist_ok=True)
    IMAGES.mkdir(exist_ok=True)
    CLEAN_CSV.parent.mkdir(parents=True, exist_ok=True)
    if DB_PATH.exists():
        DB_PATH.unlink()
    conn = sqlite3.connect(DB_PATH)
    load_raw(conn)
    for name in SQL_FILES:
        run_sql_file(conn, SQL_DIR / name)
        if name == "03_validate.sql":
            check_validation(conn)
    export_clean(conn)
    conn.close()
    draw_charts()


if __name__ == "__main__":
    main()
