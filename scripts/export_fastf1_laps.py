#!/usr/bin/env python3
"""Export Fast-F1 telemetry into the CSV format expected by the CUDA app.

The generated CSV columns match `telemetry::load_lap_csv`:
    x,y,t,speed,throttle,brake
"""

from __future__ import annotations

import argparse
from pathlib import Path
import sys

try:
    import fastf1
    import pandas as pd
except ImportError as exc:  # pragma: no cover - import guard for user guidance
    raise SystemExit(
        "Missing dependency. Install Fast-F1 first with:\n"
        "  py -m pip install fastf1 pandas"
    ) from exc


def _pick_lap(laps, driver: str, lap_number: int | None):
    driver_laps = laps.pick_driver(driver).pick_accurate().pick_wo_box()
    if driver_laps.empty:
        raise ValueError(
            f"No accurate non-box laps found for driver '{driver}'. "
            "Try another session or specify a different driver."
        )

    if lap_number is not None:
        selected = driver_laps.pick_lap(lap_number)
        if selected.empty:
            raise ValueError(
                f"Lap {lap_number} for driver '{driver}' was not found "
                "after filtering accurate non-box laps."
            )
        return selected.iloc[0]

    fastest = driver_laps.pick_fastest()
    if fastest is None or fastest.empty:
        raise ValueError(f"Could not determine a fastest lap for driver '{driver}'.")
    return fastest


def _telemetry_to_csv_frame(lap) -> pd.DataFrame:
    pos = lap.get_pos_data().loc[:, ["Date", "X", "Y"]].copy()
    car = lap.get_car_data().loc[:, ["Date", "Speed", "Throttle", "Brake"]].copy()

    pos = pos.sort_values("Date").dropna(subset=["Date", "X", "Y"])
    car = car.sort_values("Date").dropna(subset=["Date", "Speed", "Throttle", "Brake"])

    merged = pd.merge_asof(
        pos,
        car,
        on="Date",
        direction="nearest",
        tolerance=pd.Timedelta(milliseconds=250),
    ).dropna(subset=["Speed", "Throttle", "Brake"])

    if merged.empty:
        raise ValueError("Telemetry merge returned no samples.")

    t0 = merged["Date"].iloc[0]
    exported = pd.DataFrame(
        {
            "x": merged["X"].astype("float64") / 10.0,
            "y": merged["Y"].astype("float64") / 10.0,
            "t": (merged["Date"] - t0).dt.total_seconds(),
            "speed": merged["Speed"].astype("float64"),
            "throttle": merged["Throttle"].astype("float64") / 100.0,
            "brake": merged["Brake"].astype("float64"),
        }
    )

    exported = exported.drop_duplicates(subset=["t"]).reset_index(drop=True)
    if len(exported) < 10:
        raise ValueError("Not enough telemetry samples were exported for this lap.")

    return exported


def _export_driver_lap(
    session,
    driver: str,
    lap_number: int | None,
    output_path: Path,
) -> None:
    lap = _pick_lap(session.laps, driver.upper(), lap_number)
    frame = _telemetry_to_csv_frame(lap)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    frame.to_csv(output_path, index=False)

    lap_time = lap["LapTime"]
    lap_time_text = str(lap_time) if lap_time is not None else "unknown"
    lap_no = int(lap["LapNumber"]) if "LapNumber" in lap else -1
    print(
        f"Exported {driver.upper()} lap {lap_no} ({lap_time_text}) to {output_path}"
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Export one or two Fast-F1 laps into CSV files for the ghost car app."
    )
    parser.add_argument("--year", type=int, required=True, help="Championship year, e.g. 2024")
    parser.add_argument("--event", required=True, help="Event name or round number, e.g. Monaco or 8")
    parser.add_argument("--session", required=True, help="Session identifier, e.g. Q, R, FP1")
    parser.add_argument(
        "--cache-dir",
        default=".fastf1_cache",
        help="Cache directory for Fast-F1 downloads. Default: .fastf1_cache",
    )
    parser.add_argument("--reference-driver", required=True, help="Three-letter driver code for the reference lap")
    parser.add_argument("--compare-driver", required=True, help="Three-letter driver code for the comparison lap")
    parser.add_argument("--reference-lap", type=int, help="Specific reference lap number. Defaults to fastest accurate lap")
    parser.add_argument("--compare-lap", type=int, help="Specific comparison lap number. Defaults to fastest accurate lap")
    parser.add_argument(
        "--reference-output",
        default="data/fastf1_ref.csv",
        help="Output CSV path for the reference lap",
    )
    parser.add_argument(
        "--compare-output",
        default="data/fastf1_cmp.csv",
        help="Output CSV path for the comparison lap",
    )
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    Path(args.cache_dir).mkdir(parents=True, exist_ok=True)
    fastf1.Cache.enable_cache(args.cache_dir)
    session = fastf1.get_session(args.year, args.event, args.session)
    session.load(laps=True, telemetry=True, weather=False, messages=False)

    _export_driver_lap(
        session=session,
        driver=args.reference_driver,
        lap_number=args.reference_lap,
        output_path=Path(args.reference_output),
    )
    _export_driver_lap(
        session=session,
        driver=args.compare_driver,
        lap_number=args.compare_lap,
        output_path=Path(args.compare_output),
    )

    return 0


if __name__ == "__main__":
    sys.exit(main())
