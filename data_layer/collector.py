
# data_layer/collector.py - MT5 data loader with graceful fallback for test/dev environments.

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
from typing import Dict, List, Optional

import pandas as pd

from config.settings import settings
from utils.parquet_compat import install as install_parquet_compat

install_parquet_compat()

try:  # pragma: no cover - optional runtime dependency
    import MetaTrader5 as mt5
except ImportError:  # pragma: no cover - makes tests/local development possible
    mt5 = None

DATA_DIR = os.path.join("data", "raw")
os.makedirs(DATA_DIR, exist_ok=True)

DEFAULT_SYMBOL_MAP = {
    "XAUUSD": "GOLD",
    "BTCUSD": "BTCUSD",
}

TIMEFRAME_REQUESTS = {
    "W1": 1000,
    "D1": 1000,
    "H1": 2000,
    "M15": 5000,
    "M5": 5000,
    "M1": 9000,
}

TIMEFRAME_ATTRS = {
    "W1": "TIMEFRAME_W1",
    "D1": "TIMEFRAME_D1",
    "H1": "TIMEFRAME_H1",
    "M15": "TIMEFRAME_M15",
    "M5": "TIMEFRAME_M5",
    "M1": "TIMEFRAME_M1",
}


def load_symbol_map(config_path: Optional[str] = None) -> Dict[str, str]:
    if config_path and Path(config_path).exists():
        with open(config_path, encoding="utf-8") as f:
            return json.load(f)
    if Path("config/symbol_map.json").exists():
        with open("config/symbol_map.json", encoding="utf-8") as f:
            return json.load(f)
    print("WARNING: No symbol_map.json found — using defaults")
    return DEFAULT_SYMBOL_MAP.copy()


def initialize_mt5() -> bool:
    if mt5 is None:
        raise RuntimeError("MetaTrader5 package is not installed")
    if not mt5.initialize():
        raise RuntimeError("❌ MT5 initialization failed")
    return True


def _resolve_timeframe(timeframe):
    if mt5 is None:
        raise RuntimeError("MetaTrader5 package is not installed")
    if isinstance(timeframe, int):
        return timeframe
    attr = TIMEFRAME_ATTRS.get(str(timeframe).upper())
    if not attr:
        raise RuntimeError(f"Unsupported timeframe: {timeframe}")
    return getattr(mt5, attr, timeframe)


def fetch_candles(symbol: str, max_candles: int = 1000, timeframe: str | int = "M1") -> pd.DataFrame:
    if mt5 is None:
        raise RuntimeError("MetaTrader5 package is not installed")

    initialize_mt5()
    if not mt5.symbol_select(symbol, True):
        raise RuntimeError(f"❌ Failed to select symbol: {symbol}")

    mt5_timeframe = _resolve_timeframe(timeframe)
    print(f"Fetching {max_candles} candles for {symbol} ({timeframe})...")
    rates = mt5.copy_rates_from_pos(symbol, mt5_timeframe, 0, max_candles)
    if rates is None or len(rates) == 0:
        raise RuntimeError(f"❌ No data returned for {symbol} ({timeframe})")

    df = pd.DataFrame(rates)
    if "time" not in df.columns:
        raise RuntimeError("MT5 rates payload missing time column")
    df["time"] = pd.to_datetime(df["time"], unit="s", errors="coerce")

    cols = [c for c in ["time", "open", "high", "low", "close", "tick_volume"] if c in df.columns]
    if "spread" in df.columns:
        cols.append("spread")
    if "real_volume" in df.columns:
        cols.append("real_volume")
    if "volume" in df.columns:
        cols.append("volume")
    return df[cols].copy()


def update_parquet(
    broker_symbol: str,
    logical_symbol: str,
    timeframe: str = "M1",
    max_candles: Optional[int] = None,
    output_dir: Optional[str] = None,
) -> bool:
    count = max_candles or TIMEFRAME_REQUESTS.get(timeframe.upper(), 1000)
    df = fetch_candles(broker_symbol, max_candles=count, timeframe=timeframe)
    out_dir = output_dir or DATA_DIR
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, f"{logical_symbol}_{timeframe.upper()}.parquet")
    df.to_parquet(path, index=False)
    print(f"Saved {len(df)} rows to {path}")
    return True


def collect_assets(
    assets: List[str],
    config_path: Optional[str] = None,
    output_dir: Optional[str] = None,
    timeframes: Optional[List[str]] = None,
) -> Dict[str, bool]:
    results: Dict[str, bool] = {}
    symbol_map = load_symbol_map(config_path)
    requested_timeframes = [tf.upper() for tf in (timeframes or ["M1"]) if tf.strip()]

    for asset in assets:
        broker = symbol_map.get(asset, asset)
        print(f"Starting collection for {asset} ({broker})")
        asset_ok = True
        for timeframe in requested_timeframes:
            candles = TIMEFRAME_REQUESTS.get(timeframe, 1000)
            print(f"[{asset}] {timeframe} -> collecting {candles} candles")
            try:
                update_parquet(
                    broker,
                    asset,
                    timeframe=timeframe,
                    max_candles=candles,
                    output_dir=output_dir,
                )
            except Exception as exc:
                asset_ok = False
                print(f"[{asset}] {timeframe} FAILED: {exc}")
        results[asset] = asset_ok
    return results


def deduplicate(df: pd.DataFrame) -> pd.DataFrame:
    if "time" not in df.columns:
        return df.copy()
    return df.drop_duplicates(subset=["time"]).sort_values("time").reset_index(drop=True)


def main() -> None:
    parser = argparse.ArgumentParser(description="Collect raw MT5 candles for CrosSstrux assets")
    parser.add_argument("--assets", default=",".join(settings.SUPPORTED_ASSETS), help="Comma-separated assets")
    parser.add_argument("--config", default="config/symbol_map.json", help="Path to symbol map JSON")
    parser.add_argument("--output-dir", default=DATA_DIR, help="Destination directory for parquet files")
    parser.add_argument(
        "--timeframes",
        default=",".join(settings.SUPPORTED_TIMEFRAMES),
        help="Comma-separated timeframes (W1,D1,H1,M15,M5,M1)",
    )
    args = parser.parse_args()

    assets = [a.strip().upper() for a in args.assets.split(",") if a.strip()]
    timeframes = [tf.strip().upper() for tf in args.timeframes.split(",") if tf.strip()]
    results = collect_assets(assets, config_path=args.config, output_dir=args.output_dir, timeframes=timeframes)
    for asset, ok in results.items():
        print(f"{asset}: {'OK' if ok else 'FAILED'}")


if __name__ == "__main__":
    main()
