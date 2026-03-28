
"""
Training pipeline for CrossStrux v3.2 - optimized with HistGradientBoosting + model registry.
Preserves the original multi-stage structure pipeline while training each asset
across all collected timeframes into its own registry folder.
"""
from __future__ import annotations

import argparse
import json
import logging
import os
import subprocess
from typing import List, Optional, Sequence, Tuple

import joblib
import numpy as np
import pandas as pd
from sklearn.ensemble import HistGradientBoostingClassifier
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler

from utils.parquet_compat import install as install_parquet_compat

install_parquet_compat()

from config.settings import settings
from core.features.feature_pipeline import build_features, get_extended_feature_columns
from core.regimes.regime_classifier import classify_regime
from core.regimes.stability import regime_stability
from core.structure.balance import detect_balance
from core.structure.impulse import detect_impulse
from core.structure.volatility import volatility_expansion

logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s")
logger = logging.getLogger(__name__)

DATA_DIR = os.environ.get("DATA_DIR", os.path.join("data", "raw"))
MODEL_DIR = os.environ.get("MODEL_DIR", settings.MODEL_ROOT)
DEFAULT_MAX_ROWS = 100000
TRANSITION_HORIZON = 5
TIMEFRAMES = ["W1", "D1", "H1", "M15", "M5", "M1"]
FEATURE_COLUMNS = get_extended_feature_columns()


def detect_impulse_column(df: pd.DataFrame) -> str:
    preferred = ["impulse_norm", "impulse_strength", "impulse", "impulse_dir"]
    for col in preferred:
        if col in df.columns:
            return col
    candidates = [c for c in df.columns if "impulse" in c]
    if not candidates:
        raise ValueError("No impulse column found")
    return candidates[0]


def compute_regime_thresholds(df: pd.DataFrame, impulse_col: str):
    low_q = df[impulse_col].quantile(0.4)
    high_q = df[impulse_col].quantile(0.8)
    return float(low_q), float(high_q)


def assign_regime(df: pd.DataFrame, impulse_col: str, low_q: float, high_q: float):
    df = df.copy()
    df["model_regime"] = np.where(
        df[impulse_col] <= low_q,
        "low",
        np.where(df[impulse_col] <= high_q, "mid", "high"),
    )
    return df


def create_continuation_target(df: pd.DataFrame, target_source=None, horizon: int = 10):
    df = df.copy()

    if isinstance(target_source, str):
        source_col = (
            target_source
            if target_source in df.columns
            else (
                "impulse_norm"
                if "impulse_norm" in df.columns
                else ("impulse" if "impulse" in df.columns else None)
            )
        )
        if source_col is not None:
            source = pd.to_numeric(df[source_col], errors="coerce").fillna(0)
            future = source.shift(-1).fillna(0)
            if source.nunique(dropna=True) <= 2 and set(source.dropna().unique()).issubset({0, 1}):
                df["continuation_y"] = future.astype(int)
            else:
                df["continuation_y"] = (future > source).astype(int)
            return df

    future_return = (df["close"].shift(-horizon) - df["close"]) / df["close"]
    if "atr" in df.columns:
        df["atr_pct"] = df["atr"] / df["close"]
        df["continuation_y"] = (future_return.abs() > df["atr_pct"]).astype(int)
    else:
        df["continuation_y"] = (future_return > 0).astype(int)
    return df


def create_transition_target(df: pd.DataFrame):
    df = df.copy()
    regime_map = {"low": 0, "mid": 1, "high": 2}
    df["regime_encoded"] = df["model_regime"].map(regime_map).fillna(1)

    regimes = df["regime_encoded"].values
    targets = []

    for i in range(len(regimes)):
        future = regimes[i + 1 : i + 1 + TRANSITION_HORIZON]
        if len(future) == 0:
            targets.append(0)
        elif any(r != regimes[i] for r in future):
            targets.append(1)
        else:
            targets.append(0)

    df["transition_y"] = targets
    return df


def train_regime_model(X: pd.DataFrame, y: pd.Series):
    model = Pipeline(
        [
            ("scaler", StandardScaler()),
            (
                "clf",
                HistGradientBoostingClassifier(
                    max_iter=400,
                    learning_rate=0.08,
                    max_depth=9,
                    random_state=42,
                    early_stopping=True,
                    validation_fraction=0.15,
                    n_iter_no_change=15,
                    verbose=0,
                ),
            ),
        ]
    )
    model.fit(X, y)
    return model


def train_transition_model(X: pd.DataFrame, y: pd.Series):
    model = Pipeline(
        [
            ("scaler", StandardScaler()),
            (
                "clf",
                HistGradientBoostingClassifier(
                    max_iter=300,
                    learning_rate=0.1,
                    max_depth=7,
                    random_state=42,
                    early_stopping=True,
                    validation_fraction=0.1,
                ),
            ),
        ]
    )
    model.fit(X, y)
    return model


def save_drift_baselines(df: pd.DataFrame, asset_dir: str):
    baseline_df = df.tail(10000).copy()
    generic_baseline = {col: baseline_df[col].tolist() for col in FEATURE_COLUMNS if col in baseline_df.columns}
    with open(os.path.join(asset_dir, "drift_baseline.json"), "w", encoding="utf-8") as f:
        json.dump(generic_baseline, f)
    if "model_regime" in baseline_df.columns:
        for regime in ["low", "mid", "high"]:
            subset = baseline_df[baseline_df["model_regime"] == regime]
            if subset.empty:
                continue
            regime_baseline = {col: subset[col].tolist() for col in FEATURE_COLUMNS if col in subset.columns}
            with open(os.path.join(asset_dir, f"drift_baseline_{regime}.json"), "w", encoding="utf-8") as f:
                json.dump(regime_baseline, f)
    logger.info("Saved drift baselines to %s", asset_dir)


def save_metadata(asset_dir: str, git_hash: str, asset: str, timeframes: Sequence[str]):
    metadata = {
        "version": "3.2",
        "git_hash": git_hash,
        "trained_at": pd.Timestamp.utcnow().isoformat(),
        "asset": asset,
        "timeframes": list(timeframes),
        "feature_columns": FEATURE_COLUMNS,
        "regimes": ["low", "mid", "high"],
        "model_type": "HistGradientBoostingClassifier",
    }
    with open(os.path.join(asset_dir, "metadata.json"), "w", encoding="utf-8") as f:
        json.dump(metadata, f, indent=2)
    logger.info("Model registry metadata saved with git hash %s", git_hash[:8])


def _feature_source_column(df: pd.DataFrame) -> str:
    preferred = ["impulse_norm", "impulse", "cdi", "body_to_range", "atr_pct", "volatility_expansion"]
    for col in preferred:
        if col in df.columns:
            return col
    numeric_candidates = [
        c for c in df.columns
        if c not in {"time", "model_regime", "regime", "regime_encoded"}
        and pd.api.types.is_numeric_dtype(df[c])
    ]
    if not numeric_candidates:
        raise ValueError("Unable to derive model_regime: no numeric feature candidates found")
    return numeric_candidates[0]


def derive_model_regime(df: pd.DataFrame) -> pd.DataFrame:
    """Create the training target used by the models.

    The structural pipeline writes a single 'regime' label for diagnostics, but the
    trainer needs a per-row label distribution for supervised learning. We derive
    that from robust momentum/impulse features so the richer structure remains intact
    without flattening the pipeline.
    """
    df = df.copy()
    if "model_regime" in df.columns:
        return df

    source_col = _feature_source_column(df)
    source = pd.to_numeric(df[source_col], errors="coerce").replace([np.inf, -np.inf], np.nan).fillna(0.0)
    low_q = float(source.quantile(0.40))
    high_q = float(source.quantile(0.80))
    if high_q <= low_q:
        high_q = low_q + 1e-8

    df["model_regime"] = np.where(
        source <= low_q,
        "low",
        np.where(source <= high_q, "mid", "high"),
    )
    return df


def _load_frame(path: str, max_rows: int) -> pd.DataFrame:
    df = pd.read_parquet(path, use_threads=True)
    if len(df) > max_rows:
        df = df.tail(max_rows).reset_index(drop=True)
    if "time" in df.columns:
        df["time"] = pd.to_datetime(df["time"], errors="coerce")
        df = df.dropna(subset=["time"]).reset_index(drop=True)
    return df


def _prepare_timeframe_frame(asset: str, timeframe: str, path: str, max_rows: int) -> Optional[pd.DataFrame]:
    frame_count = len(pd.read_parquet(path, use_threads=True))
    logger.info("Loaded %s rows from %s", frame_count, path)
    df = _load_frame(path, max_rows=max_rows)
    logger.info("Running full structure + feature pipeline for %s (%s)...", asset, timeframe)

    raw_ohlc = {"open", "high", "low", "close"}.issubset(df.columns)
    if raw_ohlc:
        df = detect_impulse(df)
        df = detect_balance(df)
        df = volatility_expansion(df)
        df = classify_regime(df)
        df = regime_stability(df)
        df = build_features(df)
    else:
        logger.info("Using pre-built feature table for %s (%s).", asset, timeframe)

    if "continuation_y" not in df.columns:
        target_seed = "impulse_norm" if "impulse_norm" in df.columns else "impulse"
        if target_seed in df.columns:
            df = create_continuation_target(df, target_seed)
        else:
            df = create_continuation_target(df)

    df = derive_model_regime(df)

    if "transition_y" not in df.columns:
        df = create_transition_target(df)

    missing_features = [c for c in FEATURE_COLUMNS if c not in df.columns]
    if missing_features:
        logger.warning("Missing features in %s (%s): %s. Filling with 0.", asset, timeframe, missing_features)
        for c in missing_features:
            df[c] = 0.0

    df[FEATURE_COLUMNS] = df[FEATURE_COLUMNS].replace([np.inf, -np.inf], 0.0).fillna(0.0)
    df["asset"] = asset
    df["timeframe"] = timeframe
    return df


def _discover_timeframe_files(asset: str) -> List[Tuple[str, str]]:
    files: List[Tuple[str, str]] = []
    for timeframe in TIMEFRAMES:
        path = os.path.join(DATA_DIR, f"{asset}_{timeframe}.parquet")
        if os.path.exists(path):
            files.append((timeframe, path))
    return files


def _train_on_frames(asset: str, frames: List[pd.DataFrame], asset_dir: str) -> str:
    df = pd.concat(frames, ignore_index=True)
    logger.info("Combined training rows for %s: %s", asset, len(df))

    regime_mask = df["model_regime"].isin(["low", "mid", "high"])
    X_reg = df.loc[regime_mask, FEATURE_COLUMNS]
    y_reg = df.loc[regime_mask, "model_regime"]

    if len(y_reg.unique()) < 2:
        logger.warning("Not enough regime diversity - skipping regime model")
    else:
        regime_model = train_regime_model(X_reg, y_reg)
        joblib.dump(regime_model, os.path.join(asset_dir, "regime_model.pkl"))
        logger.info("Regime model trained and saved")

    if "continuation_y" in df.columns:
        X_cont = df[FEATURE_COLUMNS]
        y_cont = df["continuation_y"]
        cont_model = train_regime_model(X_cont, y_cont)
        joblib.dump(cont_model, os.path.join(asset_dir, "continuation_model.pkl"))
        logger.info("Continuation model trained")

    if "transition_y" in df.columns:
        X_trans = df[FEATURE_COLUMNS]
        y_trans = df["transition_y"]
        trans_model = train_transition_model(X_trans, y_trans)
        joblib.dump(trans_model, os.path.join(asset_dir, "transition_model.pkl"))
        logger.info("Transition model trained")

    save_drift_baselines(df, asset_dir)

    try:
        git_hash = subprocess.check_output(["git", "rev-parse", "HEAD"]).decode().strip()
    except Exception:
        git_hash = "unknown"

    return git_hash


def train_asset(
    asset: str, max_rows: int = DEFAULT_MAX_ROWS, force: bool = False, force_retrain: bool = False
):
    asset = asset.upper().strip()
    logger.info("\n" + "=" * 60)
    logger.info("Training asset: %s (%s)", asset, asset)
    logger.info("=" * 60)

    asset_dir = os.path.join(MODEL_DIR, asset)
    os.makedirs(asset_dir, exist_ok=True)
    metadata_path = os.path.join(asset_dir, "metadata.json")

    if not (force or force_retrain) and os.path.exists(metadata_path):
        logger.info("Models already exist for this asset. Use --force-retrain to override.")
        return True

    timeframe_files = _discover_timeframe_files(asset)
    if not timeframe_files:
        raise FileNotFoundError(
            f"No collected parquet files found for {asset}. Expected files like {asset}_M1.parquet"
        )

    prepared_frames: List[pd.DataFrame] = []
    for timeframe, path in timeframe_files:
        df = _prepare_timeframe_frame(asset, timeframe, path, max_rows=max_rows)
        if df is not None and not df.empty:
            prepared_frames.append(df)

    if not prepared_frames:
        raise RuntimeError(f"No usable rows found for {asset} across collected timeframes")

    git_hash = _train_on_frames(asset, prepared_frames, asset_dir)
    save_metadata(asset_dir, git_hash, asset, [tf for tf, _ in timeframe_files])
    logger.info("✅ Training completed successfully for %s", asset)
    return True


def main():
    parser = argparse.ArgumentParser(description="CrossStrux GoldDiggr / HashDiggr Training Pipeline v3.2")
    parser.add_argument("--assets", type=str, default=",".join(settings.SUPPORTED_ASSETS), help="Comma-separated assets")
    parser.add_argument("--max-rows", type=int, default=DEFAULT_MAX_ROWS)
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--force-retrain", action="store_true")
    args = parser.parse_args()

    assets = [a.strip().upper() for a in args.assets.split(",") if a.strip()]
    for asset in assets:
        train_asset(
            asset, max_rows=args.max_rows, force=args.force, force_retrain=args.force_retrain
        )


if __name__ == "__main__":
    main()
