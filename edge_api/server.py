"""
CrosSstrux v4.2.0 - FastAPI Analysis Server with Rolling Window Support
"""

import os
import time
import json
import hashlib
import logging
import numpy as np
from typing import Dict, List, Optional, Any, Tuple
from datetime import datetime
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException, Request, Depends, status
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.middleware.gzip import GZipMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field, field_validator
import uvicorn

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(name)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

try:
    import redis.asyncio as redis
    REDIS_AVAILABLE = True
except ImportError:
    REDIS_AVAILABLE = False

try:
    from core.asset_profiles import ASSET_PROFILES, get_profile
    from core.features.synthetic_volume import add_synthetic_volume
    from core.features.hierarchical_fusion import fuse_timeframe_features
    FEATURES_AVAILABLE = True
except ImportError as e:
    FEATURES_AVAILABLE = False
    logger.warning(f"Feature modules not available: {e}")

# =============================================================================
# Pydantic Models
# =============================================================================

class CandleData(BaseModel):
    time: int
    open: float
    high: float
    low: float
    close: float
    tick_volume: int
    real_volume: int

class TimeframeWindow(BaseModel):
    candles: List[CandleData]
    atr: Optional[float] = None

class AnalysisRequest(BaseModel):
    symbol: str
    asset_class: Optional[str] = None
    context_h1: TimeframeWindow
    context_m15: TimeframeWindow
    execution_m5: TimeframeWindow
    execution_m1: TimeframeWindow
    account: Optional[Dict[str, float]] = None
    spread_pips: Optional[float] = None

    @field_validator('symbol')
    @classmethod
    def validate_symbol(cls, v: str) -> str:
        return v.upper().strip()

class SignalResponse(BaseModel):
    signal: str = Field(..., pattern="^(BUY|SELL|HOLD)$")
    confidence: float = Field(..., ge=0.0, le=1.0)
    entry_precision: float = Field(..., ge=0.0, le=1.0)
    regime: str
    trend_alignment: float = Field(..., ge=0.0, le=1.0)
    spread_status: str
    execution_allowed: bool
    reason: Optional[str] = None

class HealthResponse(BaseModel):
    status: str
    version: str
    timestamp: str
    redis_connected: bool
    uptime_seconds: float

# =============================================================================
# Rate Limiter
# =============================================================================

class RateLimiter:
    def __init__(self, redis_client=None):
        self.redis = redis_client
        self.memory_store: Dict[str, Dict] = {}
        self.use_redis = redis_client is not None and REDIS_AVAILABLE
        self.limits = {
            'default': {'requests': 60, 'window': 60},
            'batch': {'requests': 5, 'window': 60},
        }
    
    async def is_allowed(self, key: str, limit_type: str = 'default') -> Tuple[bool, int, int]:
        limit_config = self.limits.get(limit_type, self.limits['default'])
        max_requests = limit_config['requests']
        window = limit_config['window']
        now = time.time()
        
        if self.use_redis:
            return await self._check_redis(key, max_requests, window, now)
        else:
            return self._check_memory(key, max_requests, window, now)
    
    async def _check_redis(self, key: str, max_requests: int, window: int, now: float):
        pipe = self.redis.pipeline()
        window_start = now - window
        pipe.zremrangebyscore(f"ratelimit:{key}", 0, window_start)
        pipe.zcard(f"ratelimit:{key}")
        pipe.zadd(f"ratelimit:{key}", {str(now): now})
        pipe.expire(f"ratelimit:{key}", window)
        results = await pipe.execute()
        current_count = results[1]
        allowed = current_count < max_requests
        remaining = max(0, max_requests - current_count - 1)
        retry_after = int(window - (now % window)) if not allowed else 0
        return allowed, remaining, retry_after
    
    def _check_memory(self, key: str, max_requests: int, window: int, now: float):
        window_start = now - window
        if key not in self.memory_store:
            self.memory_store[key] = {'requests': []}
        self.memory_store[key]['requests'] = [
            req_time for req_time in self.memory_store[key]['requests']
            if req_time > window_start
        ]
        current_count = len(self.memory_store[key]['requests'])
        allowed = current_count < max_requests
        if allowed:
            self.memory_store[key]['requests'].append(now)
        remaining = max(0, max_requests - current_count - 1)
        retry_after = int(window - (now % window)) if not allowed else 0
        return allowed, remaining, retry_after

# =============================================================================
# Analysis Cache
# =============================================================================

class AnalysisCache:
    def __init__(self, redis_client=None):
        self.redis = redis_client
        self.use_redis = redis_client is not None and REDIS_AVAILABLE
        self.memory_cache: Dict[str, Dict] = {}
        self.ttl_map = {'cryptocurrency': 5, 'gold': 30, 'forex': 15, 'default': 10}
        self.stats = {'hits': 0, 'misses': 0}
    
    def _get_cache_key(self, request: AnalysisRequest) -> str:
        key_data = {
            'symbol': request.symbol,
            'h1_close': request.context_h1.candles[-1].close if request.context_h1.candles else 0,
            'm5_close': request.execution_m5.candles[-1].close if request.execution_m5.candles else 0,
        }
        key_str = json.dumps(key_data, sort_keys=True)
        return hashlib.sha256(key_str.encode()).hexdigest()
    
    def get_ttl(self, asset_class: str) -> int:
        return self.ttl_map.get(asset_class, self.ttl_map['default'])
    
    async def get(self, key: str) -> Optional[Dict]:
        if self.use_redis:
            data = await self.redis.get(f"analysis:{key}")
            if data:
                self.stats['hits'] += 1
                return json.loads(data)
        else:
            if key in self.memory_cache:
                entry = self.memory_cache[key]
                if entry['expires'] > time.time():
                    self.stats['hits'] += 1
                    return entry['data']
                else:
                    del self.memory_cache[key]
        self.stats['misses'] += 1
        return None
    
    async def set(self, key: str, data: Dict, asset_class: str):
        ttl = self.get_ttl(asset_class)
        if self.use_redis:
            await self.redis.setex(f"analysis:{key}", ttl, json.dumps(data))
        else:
            self.memory_cache[key] = {'data': data, 'expires': time.time() + ttl}

# =============================================================================
# Analysis Engine
# =============================================================================

class AnalysisEngine:
    def __init__(self):
        self.model = None
    
    async def analyze(self, request: AnalysisRequest) -> SignalResponse:
        start_time = time.time()
        
        try:
            profile = get_profile(request.symbol)
            asset_class = request.asset_class or profile.asset_class.value
        except:
            asset_class = 'default'
            profile = None
        
        # Check spread
        spread_status = "OK"
        execution_allowed = True
        reason = None
        
        if request.spread_pips and profile:
            if request.spread_pips > getattr(profile, 'spread_emergency_pips', 50):
                spread_status = "EMERGENCY"
                execution_allowed = False
                reason = f"Spread {request.spread_pips}pips exceeds emergency limit"
            elif request.spread_pips > getattr(profile, 'spread_threshold_pips', 20):
                spread_status = "HIGH"
        
        # Analysis
        if FEATURES_AVAILABLE:
            try:
                signal, confidence = await self._analyze_with_features(request, profile)
            except Exception as e:
                logger.error(f"Feature analysis error: {e}")
                signal, confidence = self._basic_window_analysis(request)
        else:
            signal, confidence = self._basic_window_analysis(request)
        
        entry_precision = self._calc_entry_precision(request)
        regime = self._detect_regime(request.context_h1.candles)
        trend_alignment = self._calc_trend_alignment(request)
        
        logger.info(f"Analysis completed in {(time.time() - start_time)*1000:.1f}ms for {request.symbol}")
        
        return SignalResponse(
            signal=signal,
            confidence=confidence,
            entry_precision=entry_precision,
            regime=regime,
            trend_alignment=trend_alignment,
            spread_status=spread_status,
            execution_allowed=execution_allowed,
            reason=reason
        )
    
    def _candles_to_df(self, candles: List[CandleData]):
        import pandas as pd
        data = {
            'time': [c.time for c in candles],
            'open': [c.open for c in candles],
            'high': [c.high for c in candles],
            'low': [c.low for c in candles],
            'close': [c.close for c in candles],
            'tick_volume': [c.tick_volume for c in candles],
            'real_volume': [c.real_volume for c in candles]
        }
        df = pd.DataFrame(data)
        
        # CRITICAL FIX: Convert Unix timestamp (seconds from MT5) to DatetimeIndex
        df['time'] = pd.to_datetime(df['time'], unit='s')
        df.set_index('time', inplace=True)
        df.sort_index(inplace=True)  # Ensure chronological order
        
        return df

    async def _analyze_with_features(self, request: AnalysisRequest, profile):
        """Analyze with manual feature calculation - completely bypasses fusion library"""
        import pandas as pd
        import numpy as np
        
        context_dfs = {
            'H1': self._candles_to_df(request.context_h1.candles),
            'M15': self._candles_to_df(request.context_m15.candles)
        }
        execution_dfs = {
            'M5': self._candles_to_df(request.execution_m5.candles),
            'M1': self._candles_to_df(request.execution_m1.candles)
        }
        
        # Validate data
        if len(context_dfs['H1']) < 10 or len(execution_dfs['M5']) < 10:
            return self._basic_window_analysis(request)
        
        try:
            # Add synthetic volume if needed (optional enhancement)
            if profile and not profile.volume_reliable:
                try:
                    for tf, df in context_dfs.items():
                        if not df.empty:
                            context_dfs[tf] = add_synthetic_volume(df, request.symbol, tf)
                    for tf, df in execution_dfs.items():
                        if not df.empty:
                            execution_dfs[tf] = add_synthetic_volume(df, request.symbol, tf)
                except Exception as vol_err:
                    logger.warning(f"Synthetic volume failed: {vol_err}, proceeding without")
            
            # Manual feature calculation instead of fusion
            ctx_score = self._calculate_context_score(context_dfs)
            exec_score = self._calculate_execution_score(execution_dfs)
            
            # Combine scores (60% context, 40% execution as per original design)
            combined = (ctx_score * 0.6) + (exec_score * 0.4)
            
            logger.info(f"Manual fusion - Context: {ctx_score:.3f}, Execution: {exec_score:.3f}, Combined: {combined:.3f}")
            
            if combined > 0.65:
                return "BUY", min(combined, 0.95)
            elif combined < 0.35:
                return "SELL", min(1 - combined, 0.95)
            
            return "HOLD", 0.5
            
        except Exception as e:
            logger.error(f"Manual feature analysis error: {e}")
            return self._basic_window_analysis(request)

    def _calculate_context_score(self, context_dfs: dict) -> float:
        """Calculate trend alignment score from H1 and M15 without fusion library"""
        import numpy as np
        
        h1_df = context_dfs.get('H1')
        m15_df = context_dfs.get('M15')
        
        if h1_df is None or len(h1_df) < 5 or m15_df is None or len(m15_df) < 5:
            return 0.5
        
        def get_trend_strength(df):
            """Calculate trend strength using linear regression slope normalized to 0-1"""
            x = np.arange(len(df))
            y = df['close'].values
            
            # Normalize price to percentage change from start
            y_norm = (y - y[0]) / y[0] if y[0] != 0 else y
            
            # Linear regression slope
            try:
                slope = np.polyfit(x, y_norm, 1)[0]
            except:
                return 0.5
            
            # Convert slope to score: 0.5 = neutral, 1.0 = strong up, 0.0 = strong down
            # Scale factor tuned for 30-candle windows (multiply by len to normalize)
            score = 0.5 + (slope * len(df) * 5)
            return float(np.clip(score, 0.0, 1.0))
        
        h1_trend = get_trend_strength(h1_df)
        m15_trend = get_trend_strength(m15_df)
        
        # Trend alignment: if both agree, boost confidence; if disagree, neutralize toward 0.5
        trend_diff = abs(h1_trend - m15_trend)
        
        # Average the trends
        avg_trend = (h1_trend + m15_trend) / 2
        
        # If they disagree significantly (>0.3 apart), dampen the signal toward neutral
        if trend_diff > 0.3:
            final_score = 0.5 + (avg_trend - 0.5) * (1 - trend_diff)
        else:
            final_score = avg_trend
        
        return float(np.clip(final_score, 0.0, 1.0))



    
    def _basic_window_analysis(self, request: AnalysisRequest):
        h1_candles = request.context_h1.candles
        m5_candles = request.execution_m5.candles
        
        if len(h1_candles) < 5 or len(m5_candles) < 5:
            return "HOLD", 0.5
        
        h1_change = (h1_candles[-1].close - h1_candles[0].close) / h1_candles[0].close if h1_candles[0].close != 0 else 0
        m5_change = (m5_candles[-1].close - m5_candles[0].close) / m5_candles[0].close if m5_candles[0].close != 0 else 0
        
        if h1_change > 0.001 and m5_change > 0.0005:
            return "BUY", 0.7
        elif h1_change < -0.001 and m5_change < -0.0005:
            return "SELL", 0.7
        
        return "HOLD", 0.5

    def _calculate_execution_score(self, execution_dfs: dict) -> float:
        """Calculate momentum score from M5 and M1 without fusion library"""
        import numpy as np
        
        m5_df = execution_dfs.get('M5')
        m1_df = execution_dfs.get('M1')
        
        if m5_df is None or len(m5_df) < 5:
            return 0.5
        
        def get_momentum(df, name=""):
            """Calculate momentum score 0-1 based on recent price velocity"""
            # Split into recent (last 5) vs previous (before last 5)
            recent = df['close'].iloc[-5:].mean()
            previous_idx = max(0, len(df) - 10)
            previous = df['close'].iloc[previous_idx:-5].mean() if len(df) > 5 else df['close'].iloc[0]
            
            if previous == 0:
                return 0.5
            
            pct_change = (recent - previous) / previous
            
            # Convert to score: 0.5 = neutral, scale factor 50 for typical gold/forex moves
            score = 0.5 + (pct_change * 50)
            
            # Volatility adjustment - reduce confidence if current candle is an outlier spike
            ranges = (df['high'] - df['low']).values
            if len(ranges) > 5 and np.mean(ranges[:-1]) > 0:
                avg_range = np.mean(ranges[:-1])
                current_range = ranges[-1]
                if current_range > avg_range * 3:  # Spike detected
                    score = 0.5 + (score - 0.5) * 0.3  # Reduce confidence heavily
            
            return float(np.clip(score, 0.0, 1.0))
        
        m5_momentum = get_momentum(m5_df, "M5")
        
        # If M1 available, use it but weight it lower (noisier)
        if m1_df is not None and len(m1_df) >= 5:
            m1_momentum = get_momentum(m1_df, "M1")
            # Weight M5 higher (0.7) than M1 (0.3) for execution reliability
            final_score = (m5_momentum * 0.7) + (m1_momentum * 0.3)
        else:
            final_score = m5_momentum
        
        return float(np.clip(final_score, 0.0, 1.0))

    
    def _calc_entry_precision(self, request: AnalysisRequest):
        m1_candles = request.execution_m1.candles
        if len(m1_candles) < 5:
            return 0.5
        
        recent_ranges = [c.high - c.low for c in m1_candles[-5:]]
        avg_range = sum(recent_ranges) / len(recent_ranges)
        current_range = m1_candles[-1].high - m1_candles[-1].low
        
        if avg_range == 0:
            return 0.5
        
        ratio = current_range / avg_range
        if ratio < 0.7:
            return 0.8
        elif ratio > 1.3:
            return 0.4
        return 0.6
    
    def _detect_regime(self, h1_candles: List[CandleData]):
        if len(h1_candles) < 10:
            return "NORMAL"
        
        closes = [c.close for c in h1_candles]
        returns = [(closes[i] - closes[i-1])/closes[i-1] for i in range(1, len(closes)) if closes[i-1] != 0]
        
        if not returns:
            return "NORMAL"
        
        volatility = sum(r**2 for r in returns) / len(returns)
        
        if volatility < 0.0001:
            return "LOW"
        elif volatility < 0.0005:
            return "NORMAL"
        elif volatility < 0.001:
            return "HIGH"
        return "BREAKOUT"
    
    def _calc_trend_alignment(self, request: AnalysisRequest):
        h1 = self._get_window_trend(request.context_h1.candles)
        m15 = self._get_window_trend(request.context_m15.candles)
        m5 = self._get_window_trend(request.execution_m5.candles)
        
        agreement = 0.0
        if h1 == m15:
            agreement += 0.4
        if m15 == m5:
            agreement += 0.4
        if h1 == m5:
            agreement += 0.2
        
        return agreement
    
    def _get_window_trend(self, candles: List[CandleData]):
        if len(candles) < 10:
            return "NEUTRAL"
        
        first = candles[0].close
        last = candles[-1].close
        mid = candles[len(candles)//2].close
        
        if last > mid > first:
            return "BULLISH"
        elif last < mid < first:
            return "BEARISH"
        return "NEUTRAL"

# =============================================================================
# Global State
# =============================================================================

redis_client = None
rate_limiter = None
analysis_cache = None
analysis_engine = None
metrics = {
    'total_requests': 0,
    'successful_requests': 0,
    'failed_requests': 0,
    'response_times': [],
    'start_time': time.time()
}

# =============================================================================
# FastAPI App
# =============================================================================

@asynccontextmanager
async def lifespan(app: FastAPI):
    global redis_client, rate_limiter, analysis_cache, analysis_engine
    
    logger.info("Starting CrosSstrux Analysis Server v4.2.0")
    
    if REDIS_AVAILABLE:
        try:
            redis_host = os.getenv('REDIS_HOST', 'localhost')
            redis_port = int(os.getenv('REDIS_PORT', 6379))
            redis_client = redis.Redis(host=redis_host, port=redis_port, decode_responses=True)
            await redis_client.ping()
            logger.info(f"Redis connected: {redis_host}:{redis_port}")
        except Exception as e:
            logger.warning(f"Redis failed: {e}")
            redis_client = None
    
    rate_limiter = RateLimiter(redis_client)
    analysis_cache = AnalysisCache(redis_client)
    analysis_engine = AnalysisEngine()
    
    yield
    
    logger.info("Shutting down...")
    if redis_client:
        await redis_client.close()

app = FastAPI(
    title="CrosSstrux Analysis API",
    description="Multi-asset AI-assisted trading analysis with rolling windows",
    version="4.2.0",
    lifespan=lifespan
)

app.add_middleware(GZipMiddleware, minimum_size=1000)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# =============================================================================
# Exception Handlers
# =============================================================================

@app.exception_handler(RequestValidationError)
async def validation_exception_handler(request: Request, exc: RequestValidationError):
    body = await request.body()
    # Strip null bytes for logging
    clean_body = body.rstrip(b'\x00')
    logger.error(f"Validation error: {exc.errors()}")
    logger.error(f"Request body: {clean_body}")
    return JSONResponse(status_code=422, content={"detail": exc.errors()})

@app.exception_handler(Exception)
async def general_exception_handler(request: Request, exc: Exception):
    logger.error(f"Unhandled exception: {exc}", exc_info=True)
    return JSONResponse(status_code=500, content={"detail": "Internal server error"})

# =============================================================================
# Dependencies
# =============================================================================

async def check_rate_limit(request: Request, limit_type: str = 'default'):
    client_ip = request.client.host if request.client else "unknown"
    forwarded = request.headers.get('X-Forwarded-For')
    if forwarded:
        client_ip = forwarded.split(',')[0].strip()
    
    key = f"{client_ip}:{request.url.path}"
    allowed, remaining, retry_after = await rate_limiter.is_allowed(key, limit_type)
    
    if not allowed:
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail="Rate limit exceeded",
            headers={"Retry-After": str(retry_after)}
        )
    return {"remaining": remaining}

async def rate_limit_default(request: Request):
    return await check_rate_limit(request, 'default')

# =============================================================================
# Endpoints - CRITICAL FIX HERE
# =============================================================================

@app.get("/health", response_model=HealthResponse)
async def health_check():
    return HealthResponse(
        status="healthy",
        version="4.2.0",
        timestamp=datetime.utcnow().isoformat(),
        redis_connected=redis_client is not None and REDIS_AVAILABLE,
        uptime_seconds=time.time() - metrics['start_time']
    )

@app.post("/analyze")
async def analyze(request: Request, rate_limit: dict = Depends(rate_limit_default)):
    """
    Analyze market data with manual JSON parsing to handle MQL5 null bytes.
    """
    global metrics
    start_time = time.time()
    metrics['total_requests'] += 1
    
    try:
        # CRITICAL FIX: Read body and strip null bytes before parsing
        body = await request.body()
        clean_body = body.rstrip(b'\x00').strip()
        
        # Parse JSON manually
        try:
            data = json.loads(clean_body)
        except json.JSONDecodeError as e:
            logger.error(f"JSON decode error: {e}")
            logger.error(f"Body preview: {clean_body[:200]}")
            metrics['failed_requests'] += 1
            raise HTTPException(status_code=400, detail=f"Invalid JSON: {str(e)}")
        
        # Convert to Pydantic model manually
        try:
            analysis_request = AnalysisRequest(**data)
        except Exception as e:
            logger.error(f"Pydantic validation error: {e}")
            metrics['failed_requests'] += 1
            raise HTTPException(status_code=422, detail=f"Validation error: {str(e)}")
        
        # Check cache
        cache_key = analysis_cache._get_cache_key(analysis_request)
        cached = await analysis_cache.get(cache_key)
        
        if cached:
            response_time = (time.time() - start_time) * 1000
            metrics['response_times'].append(response_time)
            return SignalResponse(**cached)
        
        # Perform analysis
        result = await analysis_engine.analyze(analysis_request)
        
        # Cache result
        try:
            profile = get_profile(analysis_request.symbol)
            asset_class = profile.asset_class.value
        except:
            asset_class = 'default'
        
        await analysis_cache.set(cache_key, result.dict(), asset_class)
        
        metrics['successful_requests'] += 1
        response_time = (time.time() - start_time) * 1000
        metrics['response_times'].append(response_time)
        
        if len(metrics['response_times']) > 1000:
            metrics['response_times'] = metrics['response_times'][-1000:]
        
        return result
        
    except HTTPException:
        raise
    except Exception as e:
        metrics['failed_requests'] += 1
        logger.error(f"Analysis error: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=f"Analysis failed: {str(e)}")

@app.get("/assets")
async def list_assets():
    try:
        profiles = ASSET_PROFILES.list_profiles()
        return {
            "assets": [
                {"symbol": symbol, "profile": ASSET_PROFILES.get_profile(symbol).to_dict()}
                for symbol in profiles
            ]
        }
    except:
        return {"assets": []}

# =============================================================================
# Main
# =============================================================================

if __name__ == "__main__":
    port = int(os.getenv('PORT', 8000))
    host = os.getenv('HOST', '127.0.0.1')
    uvicorn.run("server:app", host=host, port=port, reload=os.getenv('DEBUG', 'false').lower() == 'true')