#!/usr/bin/env python3
"""Export Fast-F1 telemetry into the CSV format expected by the CUDA app.

The generated CSV columns match `telemetry::load_lap_csv`:
    x,y,t,speed,throttle,brake
"""

from __future__ import annotations

import argparse
import json
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


EXPORT_MODES = (
    "fastest-accurate-non-box",
    "all-accurate",
    "all-laps",
)


def _laps_for_mode(laps, driver: str, mode: str):
    """Return the lap subset implied by the requested export mode.

    The native picker supports both a lightweight "best representative lap"
    workflow and more exploratory multi-lap workflows. Keeping the selection
    policy here makes the exported folder format predictable.
    """
    driver_laps = laps.pick_driver(driver)
    if driver_laps.empty:
        raise ValueError(f"No laps found for driver '{driver}'.")

    if mode == "fastest-accurate-non-box":
        filtered = driver_laps.pick_accurate().pick_wo_box()
        if filtered.empty:
            raise ValueError(
                f"No accurate non-box laps found for driver '{driver}'. "
                "Try another session or choose a broader export mode."
            )
        return filtered

    if mode == "all-accurate":
        filtered = driver_laps.pick_accurate()
        if filtered.empty:
            raise ValueError(
                f"No accurate laps found for driver '{driver}'. "
                "Try another session or choose --lap-mode all-laps."
            )
        return filtered

    if mode == "all-laps":
        return driver_laps

    raise ValueError(f"Unsupported lap mode '{mode}'.")


def _pick_lap(laps, driver: str, lap_number: int | None, mode: str):
    """Resolve the one lap used for direct two-file exports."""
    driver_laps = _laps_for_mode(laps, driver, mode)

    if lap_number is not None:
        selected = driver_laps.pick_lap(lap_number)
        if selected.empty:
            raise ValueError(
                f"Lap {lap_number} for driver '{driver}' was not found "
                f"after applying lap mode '{mode}'."
            )
        return selected.iloc[0]

    fastest = driver_laps.pick_fastest()
    if fastest is None or fastest.empty:
        raise ValueError(f"Could not determine a fastest lap for driver '{driver}'.")
    return fastest


def _format_lap_time(lap_time) -> str:
    """Format pandas/Timedelta lap values as motorsport-style M:SS.mmm text."""
    if lap_time is None:
        return "unknown"
    total_seconds = lap_time.total_seconds()
    minutes = int(total_seconds // 60)
    seconds = total_seconds - (minutes * 60)
    return f"{minutes}:{seconds:06.3f}"


def _telemetry_to_csv_frame(lap) -> pd.DataFrame:
    """Merge positional and car telemetry into the CSV schema consumed by C++.

    Fast-F1 exposes position and car channels on separate sampling schedules.
    merge_asof keeps the export simple while still producing a replay-friendly
    single time axis.
    """
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


def _lap_filename(driver: str, lap) -> str:
    """Generate stable per-lap filenames for multi-lap session exports."""
    lap_no = int(lap["LapNumber"]) if "LapNumber" in lap else -1
    if lap_no >= 0:
        return f"{driver.upper()}_lap_{lap_no}.csv"
    return f"{driver.upper()}_lap_unknown.csv"


def _export_driver_lap(
    session,
    driver: str,
    lap_number: int | None,
    output_path: Path,
    mode: str,
) -> dict[str, object]:
    """Export one selected lap and return the manifest metadata for it."""
    lap = _pick_lap(session.laps, driver.upper(), lap_number, mode)
    frame = _telemetry_to_csv_frame(lap)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    frame.to_csv(output_path, index=False)

    lap_time = lap["LapTime"]
    lap_time_text = _format_lap_time(lap_time)
    lap_no = int(lap["LapNumber"]) if "LapNumber" in lap else -1
    print(
        f"Exported {driver.upper()} lap {lap_no} ({lap_time_text}) to {output_path}"
    )
    return {
        "driver": driver.upper(),
        "file": output_path.name,
        "lap_number": lap_no,
        "lap_time": lap_time_text,
    }


def _export_driver_laps_for_directory(
    session,
    driver: str,
    export_dir: Path,
    mode: str,
) -> list[dict[str, object]]:
    """Export the session-folder contents for one driver.

    The fastest-lap mode keeps the short historical filename format for
    convenience. Multi-lap modes switch to one file per lap so the native
    picker can offer specific lap choices later.
    """
    driver_laps = _laps_for_mode(session.laps, driver.upper(), mode)
    exported_entries: list[dict[str, object]] = []

    if mode == "fastest-accurate-non-box":
        path = export_dir / f"{driver.upper()}.csv"
        exported_entries.append(
            _export_driver_lap(
                session=session,
                driver=driver,
                lap_number=None,
                output_path=path,
                mode=mode,
            )
        )
        return exported_entries

    skipped_laps: list[str] = []
    for _, lap in driver_laps.iterrows():
        path = export_dir / _lap_filename(driver, lap)
        lap_no = int(lap["LapNumber"]) if "LapNumber" in lap else -1
        try:
            frame = _telemetry_to_csv_frame(lap)
            path.parent.mkdir(parents=True, exist_ok=True)
            frame.to_csv(path, index=False)

            lap_time = lap["LapTime"]
            lap_time_text = _format_lap_time(lap_time)
            print(f"Exported {driver.upper()} lap {lap_no} ({lap_time_text}) to {path}")
            exported_entries.append(
                {
                    "driver": driver.upper(),
                    "file": path.name,
                    "lap_number": lap_no,
                    "lap_time": lap_time_text,
                }
            )
        except ValueError as exc:
            skipped_laps.append(f"lap {lap_no}: {exc}")

    if not exported_entries:
        raise ValueError(f"No laps were exported for driver '{driver}'.")

    if skipped_laps:
        print(f"Skipped {len(skipped_laps)} lap(s) for {driver.upper()}:")
        for item in skipped_laps:
            print(f"  - {item}")

    return exported_entries


def _driver_codes(session) -> list[str]:
    """Return sorted unique driver codes available in the loaded session."""
    codes = session.laps["Driver"].dropna().astype(str).unique().tolist()
    return sorted(code.strip().upper() for code in codes if code.strip())


def build_parser() -> argparse.ArgumentParser:
    """Define the command-line interface for one-off and session-wide exports."""
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
    parser.add_argument("--reference-driver", help="Three-letter driver code for the reference lap")
    parser.add_argument("--compare-driver", help="Three-letter driver code for the comparison lap")
    parser.add_argument("--reference-lap", type=int, help="Specific reference lap number. Defaults to fastest accurate lap")
    parser.add_argument("--compare-lap", type=int, help="Specific comparison lap number. Defaults to fastest accurate lap")
    parser.add_argument(
        "--lap-mode",
        choices=EXPORT_MODES,
        default="fastest-accurate-non-box",
        help=(
            "Lap selection mode. "
            "Use fastest-accurate-non-box for one clean representative lap per driver, "
            "all-accurate for every accurate lap, or all-laps for the full session."
        ),
    )
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
    parser.add_argument(
        "--list-drivers",
        action="store_true",
        help="List all driver codes available in the session and exit.",
    )
    parser.add_argument(
        "--export-all-dir",
        help="Export laps for every available driver into this directory using the chosen --lap-mode.",
    )
    return parser


def main() -> int:
    """Entry point for exporting one comparison pair or an entire session."""
    parser = build_parser()
    args = parser.parse_args()

    Path(args.cache_dir).mkdir(parents=True, exist_ok=True)
    fastf1.Cache.enable_cache(args.cache_dir)
    session = fastf1.get_session(args.year, args.event, args.session)
    session.load(laps=True, telemetry=True, weather=False, messages=False)

    if args.list_drivers:
        for code in _driver_codes(session):
            print(code)
        return 0

    if args.export_all_dir:
        export_dir = Path(args.export_all_dir)
        export_dir.mkdir(parents=True, exist_ok=True)
        manifest = {
            "session": {
                "year": args.year,
                "event": args.event,
                "session": args.session,
                "lap_mode": args.lap_mode,
            },
            "entries": [],
        }
        for code in _driver_codes(session):
            try:
                manifest["entries"].extend(
                    _export_driver_laps_for_directory(
                        session=session,
                        driver=code,
                        export_dir=export_dir,
                        mode=args.lap_mode,
                    )
                )
            except ValueError as exc:
                print(f"Skipping {code}: {exc}")
        manifest_path = export_dir / "session_manifest.json"
        manifest_path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
        print(f"Wrote session manifest to {manifest_path}")
        return 0

    if not args.reference_driver or not args.compare_driver:
        raise SystemExit(
            "--reference-driver and --compare-driver are required unless you use "
            "--list-drivers or --export-all-dir."
        )

    _export_driver_lap(
        session=session,
        driver=args.reference_driver,
        lap_number=args.reference_lap,
        output_path=Path(args.reference_output),
        mode=args.lap_mode,
    )
    _export_driver_lap(
        session=session,
        driver=args.compare_driver,
        lap_number=args.compare_lap,
        output_path=Path(args.compare_output),
        mode=args.lap_mode,
    )

    return 0


if __name__ == "__main__":
    sys.exit(main())
