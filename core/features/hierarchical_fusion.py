"""
CrosSstrux v4.1.0 - Hierarchical Timeframe Fusion Module

Implements hierarchical feature fusion to prevent M1-collapse and ensure
balanced multi-timeframe representation in models.
"""

import pandas as pd
import numpy as np
from typing import Dict, List, Optional, Tuple, Any
from dataclasses import dataclass
from collections import defaultdict
import logging

logger = logging.getLogger(__name__)


@dataclass
class TimeframeConfig:
    """Configuration for a specific timeframe"""
    name: str
    priority: int  # Lower = higher priority (W1=0, M1=7)
    feature_weight: float  # Importance weight in fusion
    is_context: bool  # True for higher TFs (context)
    is_entry: bool    # True for lower TFs (entry timing)
    max_features: int  # Maximum features to extract


class HierarchicalTimeframeFusion:
    """
    Hierarchical multi-timeframe feature fusion with M1-collapse prevention.
    """
    
    TIMEFRAME_HIERARCHY = {
        'W1': 0, 'D1': 1, 'H4': 2, 'H1': 3,
        'M30': 4, 'M15': 5, 'M5': 6, 'M1': 7
    }
    
    DEFAULT_CONFIG = {
        'W1': TimeframeConfig('W1', 0, 0.15, True, False, 5),
        'D1': TimeframeConfig('D1', 1, 0.20, True, False, 8),
        'H4': TimeframeConfig('H4', 2, 0.15, True, False, 6),
        'H1': TimeframeConfig('H1', 3, 0.25, True, False, 10),
        'M30': TimeframeConfig('M30', 4, 0.10, False, True, 4),
        'M15': TimeframeConfig('M15', 5, 0.10, False, True, 6),
        'M5': TimeframeConfig('M5', 6, 0.15, False, True, 8),
        'M1': TimeframeConfig('M1', 7, 0.05, False, True, 4),  # Limited to prevent collapse
    }
    
    def __init__(self, config: Optional[Dict[str, TimeframeConfig]] = None):
        self.config = config or self.DEFAULT_CONFIG.copy()
        self.feature_importance_history: List[Dict] = []
        self.m1_collapse_warnings: int = 0
    
    def create_hierarchical_features(
        self, 
        data_dict: Dict[str, pd.DataFrame],
        target_timeframe: str = 'M5'
    ) -> pd.DataFrame:
        """
        Create hierarchical features from multi-timeframe data.
        
        Args:
            data_dict: Dictionary of {timeframe: DataFrame}
            target_timeframe: Target alignment timeframe
            
        Returns:
            DataFrame with fused hierarchical features
        """
        if target_timeframe not in data_dict:
            raise ValueError(f"Target timeframe {target_timeframe} not in data")
        
        # Step 1: Extract features PER TIMEFRAME separately
        tf_features = {}
        for tf, df in data_dict.items():
            if tf in self.config:
                tf_features[tf] = self._extract_timeframe_features(df, tf)
        
        # Step 2: Align all features to target index
        aligned_features = self._align_to_target(
            tf_features, 
            data_dict[target_timeframe].index
        )
        
        # Step 3: Create CROSS-TIMEFRAME features
        cross_tf_features = self._create_cross_timeframe_features(
            aligned_features, 
            data_dict
        )
        
        # Step 4: M1-COLLAPSE PREVENTION
        aligned_features = self._apply_m1_collapse_prevention(aligned_features)
        
        # Step 5: Weighted fusion
        fused = self._weighted_fusion(aligned_features, cross_tf_features)
        
        return fused
    
    def _extract_timeframe_features(
        self, 
        df: pd.DataFrame, 
        timeframe: str
    ) -> pd.DataFrame:
        """Extract features specific to a timeframe"""
        features = pd.DataFrame(index=df.index)
        config = self.config[timeframe]
        
        # Core price features
        features[f'{timeframe}_returns'] = df['close'].pct_change()
        features[f'{timeframe}_log_returns'] = np.log(df['close'] / df['close'].shift(1))
        
        # Trend features
        if 'ema20' in df.columns:
            features[f'{timeframe}_ema_dist'] = (df['close'] - df['ema20']) / df['ema20']
        if 'ema50' in df.columns:
            features[f'{timeframe}_ema50_dist'] = (df['close'] - df['ema50']) / df['ema50']
        
        # Volatility features
        features[f'{timeframe}_atr'] = self._calculate_atr(df)
        features[f'{timeframe}_atr_pct'] = features[f'{timeframe}_atr'] / df['close']
        
        # Momentum features
        features[f'{timeframe}_momentum'] = df['close'].diff(config.max_features)
        features[f'{timeframe}_momentum_norm'] = features[f'{timeframe}_momentum'] / df['close']
        
        # Context-specific features (higher TFs)
        if config.is_context:
            features[f'{timeframe}_trend_strength'] = self._calculate_trend_strength(df)
            features[f'{timeframe}_swing_position'] = self._calculate_swing_position(df)
            features[f'{timeframe}_volatility_regime'] = self._classify_volatility(df)
        
        # Entry-specific features (lower TFs)
        if config.is_entry:
            features[f'{timeframe}_wick_rejection'] = self._calculate_wick_rejection(df)
            features[f'{timeframe}_microstructure'] = self._calculate_microstructure(df)
            features[f'{timeframe}_order_flow'] = self._estimate_order_flow(df)
        
        # Volume features (if available)
        if 'volume_synthetic' in df.columns or 'tick_volume' in df.columns:
            vol_col = 'volume_synthetic' if 'volume_synthetic' in df.columns else 'tick_volume'
            features[f'{timeframe}_volume_impulse'] = df[vol_col] / df[vol_col].rolling(20).mean()
            features[f'{timeframe}_volume_trend'] = (
                df[vol_col].rolling(5).mean() / df[vol_col].rolling(20).mean()
            )
        
        # Limit feature count
        if len(features.columns) > config.max_features:
            # Select most important based on variance
            variances = features.var().sort_values(ascending=False)
            selected = variances.head(config.max_features).index
            features = features[selected]
        
        return features
    
    def _calculate_atr(self, df: pd.DataFrame, period: int = 14) -> pd.Series:
        """Calculate Average True Range"""
        high_low = df['high'] - df['low']
        high_close = (df['high'] - df['close'].shift()).abs()
        low_close = (df['low'] - df['close'].shift()).abs()
        tr = pd.concat([high_low, high_close, low_close], axis=1).max(axis=1)
        return tr.rolling(period).mean()
    
    def _calculate_trend_strength(self, df: pd.DataFrame, period: int = 20) -> pd.Series:
        """Calculate trend strength using linear regression slope"""
        from scipy import stats
        
        def slope(x):
            if len(x) < period:
                return 0
            x_vals = np.arange(len(x))
            slope, _, _, _, _ = stats.linregress(x_vals, x)
            return slope
        
        return df['close'].rolling(period).apply(slope, raw=True)
    
    def _calculate_swing_position(self, df: pd.DataFrame, lookback: int = 10) -> pd.Series:
        """Calculate position within recent swing"""
        recent_high = df['high'].rolling(lookback).max()
        recent_low = df['low'].rolling(lookback).min()
        
        position = (df['close'] - recent_low) / (recent_high - recent_low + 1e-10)
        return position
    
    def _classify_volatility(self, df: pd.DataFrame) -> pd.Series:
        """Classify volatility regime"""
        atr_pct = self._calculate_atr(df) / df['close']
        
        regimes = pd.Series(index=df.index, data=1)  # Default NORMAL
        regimes[atr_pct < atr_pct.quantile(0.33)] = 0  # LOW
        regimes[atr_pct > atr_pct.quantile(0.67)] = 2  # HIGH
        regimes[atr_pct > atr_pct.quantile(0.90)] = 3  # EXTREME
        
        return regimes
    
    def _calculate_wick_rejection(self, df: pd.DataFrame) -> pd.Series:
        """Calculate wick rejection strength"""
        upper_wick = df['high'] - df[['open', 'close']].max(axis=1)
        lower_wick = df[['open', 'close']].min(axis=1) - df['low']
        body = (df['close'] - df['open']).abs()
        
        # Rejection ratio
        total_range = df['high'] - df['low']
        rejection = (upper_wick + lower_wick) / (total_range + 1e-10)
        
        # Directional rejection
        bullish_rejection = (lower_wick > upper_wick * 2) & (df['close'] > df['open'])
        bearish_rejection = (upper_wick > lower_wick * 2) & (df['close'] < df['open'])
        
        return rejection * (np.where(bullish_rejection, 1, np.where(bearish_rejection, -1, 0)))
    
    def _calculate_microstructure(self, df: pd.DataFrame) -> pd.Series:
        """Calculate microstructure score"""
        # Consecutive bars in same direction
        direction = np.sign(df['close'] - df['open'])
        consecutive = direction.groupby((direction != direction.shift()).cumsum()).cumcount()
        
        return consecutive
    
    def _estimate_order_flow(self, df: pd.DataFrame) -> pd.Series:
        """Estimate order flow imbalance"""
        if 'volume_synthetic' not in df.columns and 'tick_volume' not in df.columns:
            return pd.Series(0, index=df.index)
        
        vol_col = 'volume_synthetic' if 'volume_synthetic' in df.columns else 'tick_volume'
        
        # Volume-weighted by direction
        direction = np.sign(df['close'] - df['open'])
        flow = df[vol_col] * direction
        
        return flow.rolling(5).sum()
    
    def _align_to_target(
        self, 
        tf_features: Dict[str, pd.DataFrame],
        target_index: pd.DatetimeIndex
    ) -> Dict[str, pd.DataFrame]:
        """Align all timeframe features to target index using forward-fill"""
        aligned = {}
        
        for tf, features in tf_features.items():
            # Reindex to target
            aligned_df = features.reindex(target_index, method='ffill')
            
            # Fill remaining NaNs with 0 (new bars)
            aligned_df = aligned_df.fillna(0)
            
            aligned[tf] = aligned_df
        
        return aligned
    
    def _create_cross_timeframe_features(
        self,
        aligned_features: Dict[str, pd.DataFrame],
        data_dict: Dict[str, pd.DataFrame]
    ) -> pd.DataFrame:
        """Create cross-timeframe derived features"""
        cross_features = pd.DataFrame(index=list(aligned_features.values())[0].index)
        
        # 1. Trend alignment score
        trend_cols = [col for tf in aligned_features for col in aligned_features[tf].columns 
                     if 'trend' in col or 'momentum_norm' in col]
        
        if len(trend_cols) >= 3:
            # Count agreeing directions
            directions = pd.concat([
                np.sign(aligned_features[tf].filter(like='momentum_norm')) 
                for tf in aligned_features
            ], axis=1)
            
            cross_features['trend_alignment_score'] = (
                directions.abs().sum(axis=1) / len(directions.columns)
            )
        
        # 2. Volatility regime consistency
        vol_cols = [col for tf in aligned_features for col in aligned_features[tf].columns 
                   if 'volatility_regime' in col]
        
        if len(vol_cols) >= 2:
            vol_data = pd.concat([
                aligned_features[tf]['volatility_regime'] 
                for tf in aligned_features if 'volatility_regime' in aligned_features[tf].columns
            ], axis=1)
            
            # Standard deviation of regimes across TFs
            cross_features['vol_regime_consistency'] = vol_data.std(axis=1)
        
        # 3. Structure context (higher TF position)
        higher_tfs = [tf for tf in aligned_features if self.config[tf].is_context]
        if higher_tfs:
            swing_cols = [f'{tf}_swing_position' for tf in higher_tfs 
                         if f'{tf}_swing_position' in aligned_features[tf].columns]
            
            if swing_cols:
                cross_features['structure_context'] = pd.concat([
                    aligned_features[tf]['swing_position'] 
                    for tf in higher_tfs if 'swing_position' in aligned_features[tf].columns
                ], axis=1).mean(axis=1)
        
        # 4. Entry precision score (microstructure quality)
        entry_tfs = [tf for tf in aligned_features if self.config[tf].is_entry]
        if entry_tfs:
            micro_cols = [f'{tf}_microstructure' for tf in entry_tfs 
                         if f'{tf}_microstructure' in aligned_features[tf].columns]
            wick_cols = [f'{tf}_wick_rejection' for tf in entry_tfs 
                        if f'{tf}_wick_rejection' in aligned_features[tf].columns]
            
            if micro_cols and wick_cols:
                micro_score = pd.concat([
                    aligned_features[tf]['microstructure'].abs() 
                    for tf in entry_tfs if 'microstructure' in aligned_features[tf].columns
                ], axis=1).mean(axis=1)
                
                wick_score = pd.concat([
                    aligned_features[tf]['wick_rejection'].abs() 
                    for tf in entry_tfs if 'wick_rejection' in aligned_features[tf].columns
                ], axis=1).mean(axis=1)
                
                cross_features['entry_precision_score'] = (micro_score + wick_score) / 2
        
        # 5. Near key level count
        ema_cols = [col for tf in aligned_features for col in aligned_features[tf].columns 
                   if 'ema_dist' in col or 'ema50_dist' in col]
        
        if ema_cols:
            ema_proximity = pd.concat([
                aligned_features[tf].filter(like='ema_dist').abs() 
                for tf in aligned_features
            ], axis=1)
            
            # Count how many EMAs we're close to (< 0.5%)
            cross_features['near_key_level_count'] = (ema_proximity < 0.005).sum(axis=1)
        
        return cross_features
    
    def _apply_m1_collapse_prevention(
        self, 
        aligned_features: Dict[str, pd.DataFrame]
    ) -> Dict[str, pd.DataFrame]:
        """
        CRITICAL: Prevent M1-collapse by limiting M1 feature importance.
        """
        if 'M1' not in aligned_features:
            return aligned_features
        
        m1_config = self.config['M1']
        m1_features = aligned_features['M1']
        
        # Strategy 1: Drop M1-only features that duplicate higher TF info
        higher_tf_features = set()
        for tf, features in aligned_features.items():
            if tf != 'M1':
                higher_tf_features.update(features.columns)
        
        # Remove redundant columns from M1
        m1_cols = list(m1_features.columns)
        redundant = [col for col in m1_cols if col.replace('M1_', '') in 
                    [c.split('_', 1)[1] if '_' in c else c for c in higher_tf_features]]
        
        # Keep only microstructure-specific features
        keep_patterns = ['microstructure', 'order_flow', 'wick_rejection']
        cols_to_keep = [col for col in m1_cols if any(p in col for p in keep_patterns)]
        
        # Limit to max features
        if len(cols_to_keep) > m1_config.max_features:
            cols_to_keep = cols_to_keep[:m1_config.max_features]
        
        aligned_features['M1'] = m1_features[cols_to_keep]
        
        logger.info(f"M1-collapse prevention: Reduced from {len(m1_cols)} to {len(cols_to_keep)} features")
        
        return aligned_features
    
    def _weighted_fusion(
        self,
        aligned_features: Dict[str, pd.DataFrame],
        cross_tf_features: pd.DataFrame
    ) -> pd.DataFrame:
        """Apply weighted fusion of all features"""
        # Combine all timeframe features
        all_features = []
        
        for tf, features in aligned_features.items():
            weight = self.config[tf].feature_weight
            # Apply weight to all features from this TF
            weighted = features * weight
            all_features.append(weighted)
        
        # Add cross-timeframe features (full weight)
        all_features.append(cross_tf_features)
        
        # Concatenate
        fused = pd.concat(all_features, axis=1)
        
        # Handle any remaining NaNs
        fused = fused.fillna(0)
        
        return fused
    
    def detect_m1_collapse(
        self, 
        model_feature_importance: Dict[str, float],
        threshold: float = 0.6
    ) -> Tuple[bool, str]:
        """
        Detect if model is over-relying on M1 features (M1-collapse).
        
        Args:
            model_feature_importance: Dict of {feature_name: importance}
            threshold: M1 importance threshold (0.6 = 60%)
            
        Returns:
            (is_collapsed, message)
        """
        # Sum importance by timeframe
        tf_importance = defaultdict(float)
        
        for feature, importance in model_feature_importance.items():
            for tf in self.config.keys():
                if feature.startswith(f'{tf}_'):
                    tf_importance[tf] += importance
                    break
        
        total_importance = sum(tf_importance.values())
        if total_importance == 0:
            return False, "No feature importance data"
        
        m1_pct = tf_importance.get('M1', 0) / total_importance
        
        self.feature_importance_history.append(dict(tf_importance))
        
        if m1_pct > threshold:
            self.m1_collapse_warnings += 1
            return True, f"M1-collapse detected: M1 accounts for {m1_pct:.1%} of importance"
        
        return False, f"No collapse: M1 = {m1_pct:.1%}, balanced across TFs"
    
    def get_feature_balance_report(self) -> Dict[str, Any]:
        """Get report on feature balance across timeframes"""
        if not self.feature_importance_history:
            return {"status": "No data"}
        
        recent = self.feature_importance_history[-10:]  # Last 10 checks
        
        avg_importance = defaultdict(float)
        for hist in recent:
            for tf, imp in hist.items():
                avg_importance[tf] += imp
        
        for tf in avg_importance:
            avg_importance[tf] /= len(recent)
        
        total = sum(avg_importance.values())
        
        return {
            "status": "healthy" if self.m1_collapse_warnings < 3 else "warning",
            "m1_collapse_warnings": self.m1_collapse_warnings,
            "timeframe_distribution": {
                tf: f"{imp/total:.1%}" if total > 0 else "0%"
                for tf, imp in avg_importance.items()
            },
            "recommendation": (
                "Consider reducing M1 features further" 
                if avg_importance.get('M1', 0) / total > 0.5 
                else "Feature balance is good"
            )
        }


def fuse_timeframe_features(
    data_dict: Dict[str, pd.DataFrame],
    target_tf: str = 'M5',
    prevent_m1_collapse: bool = True
) -> pd.DataFrame:
    """
    Convenience function for hierarchical feature fusion.
    
    Args:
        data_dict: {timeframe: DataFrame} dictionary
        target_tf: Target alignment timeframe
        prevent_m1_collapse: Enable M1-collapse prevention
        
    Returns:
        Fused feature DataFrame
    """
    fusion = HierarchicalTimeframeFusion()
    
    if not prevent_m1_collapse:
        # Disable M1 prevention by setting high max_features
        fusion.config['M1'].max_features = 20
    
    return fusion.create_hierarchical_features(data_dict, target_tf)

