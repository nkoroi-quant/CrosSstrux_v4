"""
CrosSstrux v4.1.0 - Asset Profiles Module

Centralized asset configuration for Python backend.
Must match MT5 AssetProfile.mqh exactly.
"""

from dataclasses import dataclass, field
from typing import List, Dict, Optional
from enum import Enum


class AssetClass(Enum):
    """Asset classification matching MT5 ENUM_ASSET_CLASS"""
    FOREX = "forex"
    GOLD = "gold"
    SILVER = "silver"
    CRYPTO = "cryptocurrency"
    INDICES = "indices"
    ENERGIES = "energies"


@dataclass
class AssetProfile:
    """
    Asset profile configuration.
    Mirrors MQL5 AssetProfile structure exactly.
    """
    symbol: str
    asset_class: AssetClass
    
    # Point & Spread Configuration (CRITICAL FIX)
    point_multiplier: int = 10  # 10 for FX/Gold, 100 for Crypto
    spread_threshold_pips: float = 2.0
    spread_emergency_pips: float = 6.0
    digits: int = 5
    
    # Volatility Thresholds (% of price)
    vol_low_threshold: float = 0.1
    vol_normal_threshold: float = 0.3
    vol_high_threshold: float = 0.6
    vol_breakout_threshold: float = 1.0
    
    # Pyramiding Parameters
    pyramid_max_trades: int = 3
    pyramid_distance_atr: float = 0.5
    pyramid_lot_multiplier: float = 1.0
    pyramid_require_profit: bool = True
    
    # Market Hours
    is_24_hour_market: bool = False
    high_volume_hours: List[int] = field(default_factory=list)
    low_volume_hours: List[int] = field(default_factory=list)
    
    # Session Quality
    entry_precision_threshold: float = 0.65
    momentum_lookback: int = 10
    min_impulse_ratio: float = 1.2
    
    # API & Caching
    context_cache_seconds: int = 60
    signal_cache_seconds: int = 30
    max_cache_age_fallback: int = 300
    
    # Volume Reliability
    volume_reliable: bool = True
    volume_method: str = "tick"  # "tick", "real", "synthetic"
    
    # Risk Parameters
    max_spread_pct_of_atr: float = 10.0
    sl_multiplier: float = 1.2
    tp_multiplier: float = 2.0
    max_daily_volatility: float = 2.0
    
    def to_dict(self) -> Dict:
        """Convert to dictionary for serialization"""
        return {
            "symbol": self.symbol,
            "asset_class": self.asset_class.value,
            "point_multiplier": self.point_multiplier,
            "spread_threshold_pips": self.spread_threshold_pips,
            "spread_emergency_pips": self.spread_emergency_pips,
            "digits": self.digits,
            "vol_low_threshold": self.vol_low_threshold,
            "vol_normal_threshold": self.vol_normal_threshold,
            "vol_high_threshold": self.vol_high_threshold,
            "vol_breakout_threshold": self.vol_breakout_threshold,
            "pyramid_max_trades": self.pyramid_max_trades,
            "pyramid_distance_atr": self.pyramid_distance_atr,
            "pyramid_lot_multiplier": self.pyramid_lot_multiplier,
            "pyramid_require_profit": self.pyramid_require_profit,
            "is_24_hour_market": self.is_24_hour_market,
            "high_volume_hours": self.high_volume_hours,
            "low_volume_hours": self.low_volume_hours,
            "entry_precision_threshold": self.entry_precision_threshold,
            "momentum_lookback": self.momentum_lookback,
            "min_impulse_ratio": self.min_impulse_ratio,
            "context_cache_seconds": self.context_cache_seconds,
            "signal_cache_seconds": self.signal_cache_seconds,
            "max_cache_age_fallback": self.max_cache_age_fallback,
            "volume_reliable": self.volume_reliable,
            "volume_method": self.volume_method,
            "max_spread_pct_of_atr": self.max_spread_pct_of_atr,
            "sl_multiplier": self.sl_multiplier,
            "tp_multiplier": self.tp_multiplier,
            "max_daily_volatility": self.max_daily_volatility,
        }


class AssetProfileRegistry:
    """
    Central registry for all asset profiles.
    Singleton pattern ensures consistency across the system.
    """
    _instance = None
    _profiles: Dict[str, AssetProfile] = {}
    
    def __new__(cls):
        if cls._instance is None:
            cls._instance = super().__new__(cls)
            cls._instance._initialize_defaults()
        return cls._instance
    
    def _initialize_defaults(self):
        """Initialize default profiles - must match MT5 exactly"""
        
        # --- XAUUSD (Gold) Profile ---
        gold = AssetProfile(
            symbol="XAUUSD",
            asset_class=AssetClass.GOLD,
            point_multiplier=10,  # 1 pip = 10 points = $0.01
            spread_threshold_pips=5.0,  # 5 pips = $5 acceptable
            spread_emergency_pips=15.0,
            digits=2,
            
            vol_low_threshold=0.3,  # 0.3% daily
            vol_normal_threshold=0.5,
            vol_high_threshold=0.8,
            vol_breakout_threshold=1.5,
            
            pyramid_max_trades=3,
            pyramid_distance_atr=0.5,
            pyramid_lot_multiplier=1.0,
            pyramid_require_profit=True,
            
            is_24_hour_market=False,
            high_volume_hours=[8, 9, 10, 11, 12, 13, 14, 15],  # London/NY
            low_volume_hours=[22, 23, 0, 1, 2],  # Late night
            
            entry_precision_threshold=0.65,
            momentum_lookback=10,
            min_impulse_ratio=1.2,
            
            context_cache_seconds=120,  # 2 minutes
            signal_cache_seconds=60,    # 1 minute
            max_cache_age_fallback=600, # 10 minutes
            
            volume_reliable=True,
            volume_method="tick",
            
            max_spread_pct_of_atr=10.0,
            sl_multiplier=1.5,
            tp_multiplier=2.5,
            max_daily_volatility=2.0,
        )
        self._profiles["XAUUSD"] = gold
        self._profiles["GOLD"] = gold  # Alias
        
        # --- BTCUSD (Bitcoin) Profile ---
        btc = AssetProfile(
            symbol="BTCUSD",
            asset_class=AssetClass.CRYPTO,
            point_multiplier=100,  # CRITICAL: 1 pip = 100 points = $1.00
            spread_threshold_pips=50.0,  # 50 pips = ~$50 (NORMAL for BTC!)
            spread_emergency_pips=150.0,
            digits=2,
            
            vol_low_threshold=1.0,  # 1% daily = low for BTC
            vol_normal_threshold=2.5,
            vol_high_threshold=5.0,
            vol_breakout_threshold=8.0,
            
            pyramid_max_trades=5,  # More pyramiding for crypto
            pyramid_distance_atr=0.3,  # Tighter spacing
            pyramid_lot_multiplier=0.8,
            pyramid_require_profit=True,
            
            is_24_hour_market=True,  # 24/7 trading
            high_volume_hours=[0, 1, 2, 3, 13, 14, 15, 16, 17],  # Asia + US/EU
            low_volume_hours=[21, 22, 23],  # US close
            
            entry_precision_threshold=0.70,  # Higher threshold (more noise)
            momentum_lookback=6,  # Faster momentum
            min_impulse_ratio=1.5,
            
            context_cache_seconds=30,  # Faster updates
            signal_cache_seconds=15,     # Very fast signals
            max_cache_age_fallback=150,  # 2.5 min fallback
            
            volume_reliable=False,  # Synthetic volume only
            volume_method="synthetic",
            
            max_spread_pct_of_atr=15.0,  # Allow wider spread %
            sl_multiplier=2.0,  # Wider stops
            tp_multiplier=3.0,  # Larger targets
            max_daily_volatility=15.0,
        )
        self._profiles["BTCUSD"] = btc
        self._profiles["BTCUSDT"] = btc
        
        # --- ETHUSD (Ethereum) Profile ---
        eth = AssetProfile(
            symbol="ETHUSD",
            asset_class=AssetClass.CRYPTO,
            point_multiplier=100,
            spread_threshold_pips=6.0,  # Tighter than BTC
            spread_emergency_pips=20.0,
            digits=2,
            
            vol_low_threshold=1.5,
            vol_normal_threshold=3.0,
            vol_high_threshold=6.0,
            vol_breakout_threshold=10.0,
            
            pyramid_max_trades=4,
            pyramid_distance_atr=0.35,
            pyramid_lot_multiplier=0.8,
            
            is_24_hour_market=True,
            high_volume_hours=[0, 1, 2, 3, 13, 14, 15, 16, 17],
            low_volume_hours=[21, 22, 23],
            
            entry_precision_threshold=0.70,
            momentum_lookback=6,
            
            context_cache_seconds=30,
            signal_cache_seconds=15,
            max_cache_age_fallback=150,
            
            volume_reliable=False,
            volume_method="synthetic",
            
            max_spread_pct_of_atr=15.0,
            sl_multiplier=2.0,
            tp_multiplier=3.0,
            max_daily_volatility=12.0,
        )
        self._profiles["ETHUSD"] = eth
        self._profiles["ETHUSDT"] = eth
        
        # --- EURUSD (Forex Baseline) ---
        eurusd = AssetProfile(
            symbol="EURUSD",
            asset_class=AssetClass.FOREX,
            point_multiplier=10,  # 1 pip = 10 points
            spread_threshold_pips=2.0,
            spread_emergency_pips=5.0,
            digits=5,
            
            vol_low_threshold=0.05,
            vol_normal_threshold=0.15,
            vol_high_threshold=0.30,
            vol_breakout_threshold=0.50,
            
            pyramid_max_trades=3,
            pyramid_distance_atr=0.5,
            
            is_24_hour_market=False,
            high_volume_hours=[8, 9, 10, 11, 12, 13, 14, 15],
            low_volume_hours=[22, 23, 0, 1, 2, 3, 4, 5],
            
            entry_precision_threshold=0.65,
            momentum_lookback=10,
            
            context_cache_seconds=60,
            signal_cache_seconds=30,
            max_cache_age_fallback=300,
            
            volume_reliable=True,
            volume_method="tick",
            
            max_spread_pct_of_atr=10.0,
            sl_multiplier=1.2,
            tp_multiplier=2.0,
            max_daily_volatility=2.0,
        )
        self._profiles["EURUSD"] = eurusd
    
    def get_profile(self, symbol: str) -> AssetProfile:
        """
        Get profile for symbol with fallback to defaults.
        Handles various symbol suffixes (.r, .ecn, etc.)
        """
        # Direct match
        if symbol in self._profiles:
            return self._profiles[symbol]
        
        # Try base symbol (remove suffix)
        base = symbol.split('.')[0]
        if base in self._profiles:
            return self._profiles[base]
        
        # Try common suffixes
        for suffix in ['.r', '.ecn', '.pro', '.std', '.mini']:
            if symbol + suffix in self._profiles:
                return self._profiles[symbol + suffix]
        
        # Return default (Forex)
        print(f"AssetProfileRegistry: No profile found for {symbol}, using FOREX defaults")
        return AssetProfile(
            symbol=symbol,
            asset_class=AssetClass.FOREX
        )
    
    def register_profile(self, symbol: str, profile: AssetProfile):
        """Register a new or override existing profile"""
        self._profiles[symbol] = profile
    
    def list_profiles(self) -> List[str]:
        """List all registered symbols"""
        return list(self._profiles.keys())
    
    def get_by_class(self, asset_class: AssetClass) -> List[AssetProfile]:
        """Get all profiles for an asset class"""
        return [p for p in self._profiles.values() if p.asset_class == asset_class]


# Global registry instance
ASSET_PROFILES = AssetProfileRegistry()


def get_profile(symbol: str) -> AssetProfile:
    """Convenience function to get profile"""
    return ASSET_PROFILES.get_profile(symbol)


def normalize_spread_to_pips(symbol: str, spread_points: float) -> float:
    """
    CRITICAL FIX: Normalize spread from points to pips.
    
    Args:
        symbol: Trading symbol
        spread_points: Raw spread in points
        
    Returns:
        Normalized spread in pips
        
    Example:
        >>> normalize_spread_to_pips("BTCUSD", 5000)
        50.0  # 5000 / 100 = 50 pips (NORMAL for BTC!)
        >>> normalize_spread_to_pips("XAUUSD", 50)
        5.0   # 50 / 10 = 5 pips (NORMAL for Gold!)
    """
    profile = get_profile(symbol)
    return spread_points / profile.point_multiplier


def is_spread_acceptable(symbol: str, spread_pips: float) -> bool:
    """Check if spread is within acceptable limits for asset"""
    profile = get_profile(symbol)
    return spread_pips <= profile.spread_threshold_pips
