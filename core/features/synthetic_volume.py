"""
CrosSstrux v4.1.0 - Synthetic Volume Module

Implements synthetic volume modeling for cryptocurrency CFDs that lack
reliable tick_volume or real_volume data. Uses price-based metrics to
estimate volume activity.
"""

import pandas as pd
import numpy as np
from typing import Dict, List, Optional, Literal
from dataclasses import dataclass
from enum import Enum
import logging

logger = logging.getLogger(__name__)


class VolumeMethod(Enum):
    """Volume calculation method"""
    RANGE_BASED = "range_based"      # volume ∝ price_range * multiplier
    TICK_BASED = "tick_based"        # use actual tick volume if available
    HYBRID = "hybrid"                # combination with momentum boost
    IMPULSE_BASED = "impulse_based"  # volume ∝ momentum * range


@dataclass
class VolumeConfig:
    """Configuration for synthetic volume calculation"""
    method: VolumeMethod = VolumeMethod.HYBRID
    range_multiplier: float = 1000.0  # Base multiplier for range-based
    momentum_boost: float = 1.5       # Multiplier for high momentum
    volatility_adjustment: bool = True
    time_of_day_adjustment: bool = True
    smoothing_period: int = 3         # EMA smoothing for output


class SyntheticVolumeModel:
    """
    Synthetic volume model for cryptocurrency and other assets
    with unreliable volume data.
    """
    
    # Crypto volume patterns (UTC hours, 0-23)
    CRYPTO_VOLUME_PROFILE = {
        # High volume periods
        0: 1.3, 1: 1.3, 2: 1.3, 3: 1.3,  # Asia open
        13: 1.4, 14: 1.5, 15: 1.5, 16: 1.4, 17: 1.3,  # US/EU overlap
        # Normal volume
        4: 1.0, 5: 1.0, 6: 1.0, 7: 1.0,
        8: 1.0, 9: 1.0, 10: 1.0, 11: 1.0, 12: 1.1,
        18: 1.0, 19: 1.0, 20: 1.0,
        # Low volume
        21: 0.7, 22: 0.6, 23: 0.6,  # US close
    }
    
    def __init__(self, config: Optional[VolumeConfig] = None):
        self.config = config or VolumeConfig()
        self._volume_history: Dict[str, List[float]] = {}
    
    def calculate_synthetic_volume(
        self, 
        df: pd.DataFrame, 
        timeframe: str = 'M5',
        asset_class: str = 'cryptocurrency',
        symbol: Optional[str] = None
    ) -> pd.DataFrame:
        """
        Calculate synthetic volume for a dataframe.
        
        Args:
            df: DataFrame with OHLC data
            timeframe: Timeframe string (M1, M5, M15, H1, etc.)
            asset_class: Asset class for adjustments
            symbol: Symbol for specific adjustments
            
        Returns:
            DataFrame with added volume columns
        """
        df = df.copy()
        
        # Ensure required columns exist
        required = ['open', 'high', 'low', 'close']
        for col in required:
            if col not in df.columns:
                raise ValueError(f"Missing required column: {col}")
        
        # 1. Calculate price-based metrics
        df['true_range'] = self._calculate_true_range(df)
        df['true_range_pct'] = (df['true_range'] / df['close']) * 100
        
        # 2. Calculate momentum
        df['momentum'] = df['close'].diff().abs()
        df['momentum_pct'] = (df['momentum'] / df['close']) * 100
        
        # 3. Base volume calculation
        if self.config.method == VolumeMethod.RANGE_BASED:
            df['volume_synthetic'] = self._range_based_volume(df)
        elif self.config.method == VolumeMethod.IMPULSE_BASED:
            df['volume_synthetic'] = self._impulse_based_volume(df)
        elif self.config.method == VolumeMethod.HYBRID:
            df['volume_synthetic'] = self._hybrid_volume(df)
        else:
            df['volume_synthetic'] = self._range_based_volume(df)
        
        # 4. Time-of-day adjustment for crypto
        if self.config.time_of_day_adjustment and asset_class == 'cryptocurrency':
            df['volume_synthetic'] = self._apply_time_adjustment(df)
        
        # 5. Volatility regime adjustment
        if self.config.volatility_adjustment:
            df['volume_synthetic'] = self._apply_volatility_adjustment(df)
        
        # 6. Smoothing
        if self.config.smoothing_period > 1:
            df['volume_synthetic'] = df['volume_synthetic'].ewm(
                span=self.config.smoothing_period, adjust=False
            ).mean()
        
        # 7. Calculate derived metrics
        df = self._calculate_volume_metrics(df)
        
        return df
    
    def _calculate_true_range(self, df: pd.DataFrame) -> pd.Series:
        """Calculate true range"""
        high_low = df['high'] - df['low']
        high_close = (df['high'] - df['close'].shift()).abs()
        low_close = (df['low'] - df['close'].shift()).abs()
        
        tr = pd.concat([high_low, high_close, low_close], axis=1).max(axis=1)
        return tr
    
    def _range_based_volume(self, df: pd.DataFrame) -> pd.Series:
        """Volume proportional to price range"""
        base_volume = df['true_range'] * self.config.range_multiplier
        return base_volume.fillna(0)
    
    def _impulse_based_volume(self, df: pd.DataFrame) -> pd.Series:
        """Volume proportional to momentum * range"""
        impulse = df['momentum'] * df['true_range']
        base_volume = impulse * self.config.range_multiplier * 0.5
        return base_volume.fillna(0)
    
    def _hybrid_volume(self, df: pd.DataFrame) -> pd.Series:
        """Hybrid: range-based with momentum boost"""
        base = df['true_range'] * self.config.range_multiplier
        
        # Momentum boost for strong moves
        momentum_factor = 1.0 + (df['momentum_pct'] / df['momentum_pct'].rolling(20).mean()) * 0.5
        momentum_factor = momentum_factor.clip(0.5, 3.0)
        
        volume = base * momentum_factor
        return volume.fillna(0)
    
    def _apply_time_adjustment(self, df: pd.DataFrame) -> pd.Series:
        """Apply time-of-day volume adjustments for crypto"""
        if not isinstance(df.index, pd.DatetimeIndex):
            return df['volume_synthetic']
        
        hours = df.index.hour
        multipliers = hours.map(lambda h: self.CRYPTO_VOLUME_PROFILE.get(h, 1.0))
        
        return df['volume_synthetic'] * multipliers
    
    def _apply_volatility_adjustment(self, df: pd.DataFrame) -> pd.Series:
        """Adjust volume based on volatility regime"""
        # Calculate rolling volatility
        vol_ma = df['true_range_pct'].rolling(20).mean()
        vol_current = df['true_range_pct']
        
        # Volume should be higher in high volatility
        vol_ratio = vol_current / vol_ma
        vol_factor = np.sqrt(vol_ratio.clip(0.5, 3.0))  # Square root for dampening
        
        return df['volume_synthetic'] * vol_factor
    
    def _calculate_volume_metrics(self, df: pd.DataFrame) -> pd.DataFrame:
        """Calculate volume-derived metrics"""
        vol = df['volume_synthetic']
        
        # Volume moving averages
        df['volume_ma_short'] = vol.rolling(5).mean()
        df['volume_ma_long'] = vol.rolling(20).mean()
        
        # Volume impulse (ratio to MA)
        df['volume_impulse'] = vol / df['volume_ma_long']
        
        # Volume trend (short/long ratio)
        df['volume_trend'] = df['volume_ma_short'] / df['volume_ma_long']
        
        # On-balance volume (synthetic)
        df['obv_synthetic'] = self._calculate_obv(df)
        
        # Volume intensity (volume * range)
        df['volume_intensity'] = vol * df['true_range']
        
        # Volume anomaly detection
        df['volume_zscore'] = (vol - vol.rolling(50).mean()) / vol.rolling(50).std()
        df['volume_anomaly'] = df['volume_zscore'].abs() > 2.0
        
        return df
    
    def _calculate_obv(self, df: pd.DataFrame) -> pd.Series:
        """Calculate On-Balance Volume using synthetic volume"""
        direction = np.where(df['close'] > df['close'].shift(), 1, 
                    np.where(df['close'] < df['close'].shift(), -1, 0))
        obv_change = df['volume_synthetic'] * direction
        return obv_change.cumsum()


class VolumeProfileAnalyzer:
    """
    Analyze volume profile characteristics for market structure.
    """
    
    def __init__(self, n_bins: int = 24):
        self.n_bins = n_bins
    
    def calculate_volume_profile(
        self, 
        df: pd.DataFrame, 
        value_area_pct: float = 0.70
    ) -> Dict:
        """
        Calculate volume profile metrics.
        
        Args:
            df: DataFrame with 'volume_synthetic' and price columns
            value_area_pct: Percentage for value area calculation
            
        Returns:
            Dictionary with volume profile metrics
        """
        if 'volume_synthetic' not in df.columns:
            raise ValueError("DataFrame must contain 'volume_synthetic' column")
        
        # Create price bins
        price_range = df['high'].max() - df['low'].min()
        bin_size = price_range / self.n_bins
        
        df['price_bin'] = ((df['close'] - df['low'].min()) / bin_size).astype(int).clip(0, self.n_bins - 1)
        
        # Volume by price level
        volume_by_price = df.groupby('price_bin')['volume_synthetic'].sum()
        
        # Point of Control (POC) - price level with highest volume
        poc_bin = volume_by_price.idxmax()
        poc_price = df['low'].min() + (poc_bin + 0.5) * bin_size
        
        # Value Area (70% of volume)
        total_volume = volume_by_price.sum()
        sorted_levels = volume_by_price.sort_values(ascending=False)
        cumulative = sorted_levels.cumsum()
        
        value_area_levels = cumulative[cumulative <= total_volume * value_area_pct].index
        
        if len(value_area_levels) > 0:
            value_area_high_bin = value_area_levels.max()
            value_area_low_bin = value_area_levels.min()
            value_area_high = df['low'].min() + (value_area_high_bin + 1) * bin_size
            value_area_low = df['low'].min() + value_area_low_bin * bin_size
        else:
            value_area_high = df['high'].max()
            value_area_low = df['low'].min()
        
        # Volume anomalies
        mean_vol = df['volume_synthetic'].mean()
        std_vol = df['volume_synthetic'].std()
        volume_spikes = df[df['volume_synthetic'] > mean_vol + 2 * std_vol]
        
        return {
            'poc_price': poc_price,
            'value_area_high': value_area_high,
            'value_area_low': value_area_low,
            'value_area_range': value_area_high - value_area_low,
            'volume_concentration': volume_by_price.max() / total_volume,
            'volume_spike_count': len(volume_spikes),
            'volume_spike_prices': volume_spikes['close'].tolist() if len(volume_spikes) > 0 else [],
            'total_volume': total_volume,
            'volume_by_price': volume_by_price.to_dict(),
        }
    
    def detect_volume_climax(
        self, 
        df: pd.DataFrame, 
        lookback: int = 20,
        threshold_std: float = 2.5
    ) -> pd.Series:
        """
        Detect volume climax bars (potential reversals).
        
        Returns:
            Boolean series indicating climax bars
        """
        vol = df['volume_synthetic']
        vol_ma = vol.rolling(lookback).mean()
        vol_std = vol.rolling(lookback).std()
        
        # High volume + large range
        high_volume = vol > (vol_ma + threshold_std * vol_std)
        large_range = df['true_range'] > df['true_range'].rolling(lookback).mean() * 2
        
        # Climax = high volume + large range
        climax = high_volume & large_range
        
        return climax


def add_synthetic_volume(
    df: pd.DataFrame,
    symbol: str,
    timeframe: str = 'M5',
    method: Literal['range', 'impulse', 'hybrid'] = 'hybrid'
) -> pd.DataFrame:
    """
    Convenience function to add synthetic volume to dataframe.
    
    Args:
        df: OHLC DataFrame
        symbol: Trading symbol
        timeframe: Timeframe string
        method: Volume calculation method
        
    Returns:
        DataFrame with synthetic volume columns added
    """
    from core.asset_profiles import get_profile
    
    profile = get_profile(symbol)
    
    # Determine method
    method_map = {
        'range': VolumeMethod.RANGE_BASED,
        'impulse': VolumeMethod.IMPULSE_BASED,
        'hybrid': VolumeMethod.HYBRID,
    }
    
    config = VolumeConfig(
        method=method_map.get(method, VolumeMethod.HYBRID),
        time_of_day_adjustment=profile.is_24_hour_market,
    )
    
    model = SyntheticVolumeModel(config)
    
    return model.calculate_synthetic_volume(
        df, 
        timeframe=timeframe,
        asset_class=profile.asset_class.value
    )
