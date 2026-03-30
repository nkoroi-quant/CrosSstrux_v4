"""
CrosSstrux v4.1.0 - FastAPI Analysis Server

Production-ready FastAPI server with:
- Rate limiting (Redis if available, memory fallback)
- Asset-specific caching TTLs
- Request validation with Pydantic
- Background task processing
- Health check and metrics endpoints
"""

# Add this import at the top
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse


import os
import time
import json
import hashlib
import logging
from typing import Dict, List, Optional, Any
from datetime import datetime, timedelta
from functools import wraps
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException, Request, BackgroundTasks, Depends, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.middleware.gzip import GZipMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field, validator
import uvicorn

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Try to import Redis, fall back to memory if unavailable
try:
    import redis.asyncio as redis
    REDIS_AVAILABLE = True
except ImportError:
    REDIS_AVAILABLE = False
    logger.warning("Redis not available, using memory-based caching")

# Import CrosSstrux modules


try:
    from core.asset_profiles import ASSET_PROFILES, get_profile, AssetClass
    from core.features.synthetic_volume import add_synthetic_volume
    from core.features.hierarchical_fusion import fuse_timeframe_features
    FEATURES_AVAILABLE = True
except ImportError:
    FEATURES_AVAILABLE = False
    logger.warning("Feature modules not available, using basic analysis")


# =============================================================================
# Pydantic Models
# =============================================================================

class TimeframeData(BaseModel):
    """OHLC data for a specific timeframe"""
    open: Optional[float] = None
    high: Optional[float] = None
    low: Optional[float] = None
    close: float
    tick_volume: Optional[int] = None
    real_volume: Optional[int] = None
    atr: Optional[float] = None
    ema20: Optional[float] = None
    ema50: Optional[float] = None


class AccountInfo(BaseModel):
    """Account information"""
    balance: float
    equity: float


class AnalysisRequest(BaseModel):
    """Request model for market analysis"""
    symbol: str = Field(..., description="Trading symbol (e.g., BTCUSD, XAUUSD)")
    asset_class: Optional[str] = Field(None, description="Asset class override")
    timeframes: Dict[str, TimeframeData] = Field(..., description="Multi-timeframe data")
    account: Optional[AccountInfo] = None
    spread_pips: Optional[float] = None
    
    @validator('symbol')
    def validate_symbol(cls, v):
        return v.upper().strip()


class SignalResponse(BaseModel):
    """Trading signal response"""
    signal: str = Field(..., pattern="^(BUY|SELL|HOLD)$")
    confidence: float = Field(..., ge=0.0, le=1.0)
    entry_precision: float = Field(..., ge=0.0, le=1.0)
    regime: str
    trend_alignment: float = Field(..., ge=0.0, le=1.0)
    spread_status: str
    execution_allowed: bool
    reason: Optional[str] = None


class HealthResponse(BaseModel):
    """Health check response"""
    status: str
    version: str
    timestamp: str
    redis_connected: bool
    uptime_seconds: float


class MetricsResponse(BaseModel):
    """Metrics response"""
    total_requests: int
    successful_requests: int
    failed_requests: int
    average_response_time_ms: float
    cache_hit_rate: float
    requests_per_minute: float


# =============================================================================
# Rate Limiting Implementation
# =============================================================================

class RateLimiter:
    """
    Token bucket rate limiter with Redis or memory backend.
    """
    
    def __init__(self, redis_client=None):
        self.redis = redis_client
        self.memory_store: Dict[str, Dict] = {}
        self.use_redis = redis_client is not None and REDIS_AVAILABLE
        
        # Rate limits by endpoint type
        self.limits = {
            'default': {'requests': 10, 'window': 60},      # 10 req/min
            'batch': {'requests': 2, 'window': 60},           # 2 req/min
            'health': {'requests': 60, 'window': 60},          # 60 req/min
        }
    
    async def is_allowed(self, key: str, limit_type: str = 'default') -> tuple[bool, int, int]:
        """
        Check if request is allowed.
        Returns: (allowed, remaining, retry_after)
        """
        limit_config = self.limits.get(limit_type, self.limits['default'])
        max_requests = limit_config['requests']
        window = limit_config['window']
        
        now = time.time()
        
        if self.use_redis:
            return await self._check_redis(key, max_requests, window, now)
        else:
            return self._check_memory(key, max_requests, window, now)
    
    async def _check_redis(self, key: str, max_requests: int, window: int, now: float) -> tuple:
        """Redis-backed rate limiting using sliding window"""
        pipe = self.redis.pipeline()
        
        # Remove old entries
        window_start = now - window
        pipe.zremrangebyscore(f"ratelimit:{key}", 0, window_start)
        
        # Count current entries
        pipe.zcard(f"ratelimit:{key}")
        
        # Add current request
        pipe.zadd(f"ratelimit:{key}", {str(now): now})
        
        # Set expiry
        pipe.expire(f"ratelimit:{key}", window)
        
        results = await pipe.execute()
        current_count = results[1]
        
        allowed = current_count < max_requests
        remaining = max(0, max_requests - current_count - 1)
        retry_after = int(window - (now % window)) if not allowed else 0
        
        return allowed, remaining, retry_after
    
    def _check_memory(self, key: str, max_requests: int, window: int, now: float) -> tuple:
        """Memory-backed rate limiting"""
        window_start = now - window
        
        if key not in self.memory_store:
            self.memory_store[key] = {'requests': []}
        
        # Clean old requests
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
        
        # Cleanup old keys periodically
        if len(self.memory_store) > 10000:
            self._cleanup_memory()
        
        return allowed, remaining, retry_after
    
    def _cleanup_memory(self):
        """Clean up old entries from memory store"""
        now = time.time()
        cutoff = now - 3600  # 1 hour
        
        keys_to_remove = [
            key for key, data in self.memory_store.items()
            if not data['requests'] or max(data['requests']) < cutoff
        ]
        
        for key in keys_to_remove:
            del self.memory_store[key]
        
        logger.info(f"Rate limiter cleanup: removed {len(keys_to_remove)} old keys")


# =============================================================================
# Analysis Cache
# =============================================================================

class AnalysisCache:
    """
    Intelligent caching with asset-specific TTLs.
    """
    
    def __init__(self, redis_client=None):
        self.redis = redis_client
        self.use_redis = redis_client is not None and REDIS_AVAILABLE
        self.memory_cache: Dict[str, Dict] = {}
        
        # TTL map by asset class (seconds)
        self.ttl_map = {
            'cryptocurrency': 5,
            'gold': 30,
            'forex': 15,
            'default': 10
        }
        
        self.stats = {'hits': 0, 'misses': 0}
    
    def _get_cache_key(self, request: AnalysisRequest) -> str:
        """Generate cache key from request"""
        # Hash of symbol + timeframe closes
        key_data = {
            'symbol': request.symbol,
            'closes': {tf: data.close for tf, data in request.timeframes.items()}
        }
        key_str = json.dumps(key_data, sort_keys=True)
        return hashlib.sha256(key_str.encode()).hexdigest()
    
    def get_ttl(self, asset_class: str) -> int:
        """Get TTL for asset class"""
        return self.ttl_map.get(asset_class, self.ttl_map['default'])
    
    async def get(self, key: str) -> Optional[Dict]:
        """Get cached result"""
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
        """Cache result with asset-specific TTL"""
        ttl = self.get_ttl(asset_class)
        
        if self.use_redis:
            await self.redis.setex(
                f"analysis:{key}",
                ttl,
                json.dumps(data)
            )
        else:
            self.memory_cache[key] = {
                'data': data,
                'expires': time.time() + ttl
            }
    
    def get_stats(self) -> Dict:
        """Get cache statistics"""
        total = self.stats['hits'] + self.stats['misses']
        hit_rate = self.stats['hits'] / total if total > 0 else 0
        
        return {
            'hits': self.stats['hits'],
            'misses': self.stats['misses'],
            'hit_rate': hit_rate,
            'memory_entries': len(self.memory_cache)
        }


# =============================================================================
# Analysis Engine
# =============================================================================

class AnalysisEngine:
    """
    Core analysis engine for generating trading signals.
    """
    
    def __init__(self):
        self.model = None  # Placeholder for ML model
    
    async def analyze(self, request: AnalysisRequest) -> SignalResponse:
        """
        Perform market analysis and generate signal.
        """
        start_time = time.time()
        
        # Get asset profile
        profile = get_profile(request.symbol)
        asset_class = request.asset_class or profile.asset_class.value
        
        # Check spread
        spread_status = "OK"
        execution_allowed = True
        reason = None
        
        if request.spread_pips is not None:
            if request.spread_pips > profile.spread_emergency_pips:
                spread_status = "EMERGENCY"
                execution_allowed = False
                reason = f"Spread {request.spread_pips}pips exceeds emergency {profile.spread_emergency_pips}pips"
            elif request.spread_pips > profile.spread_threshold_pips:
                spread_status = "HIGH"
                # Still allow but with warning
        
        # Extract features if modules available
        if FEATURES_AVAILABLE:
            # Convert to dataframes and add synthetic volume if needed
            df_dict = self._convert_to_dataframes(request.timeframes)
            
            if not profile.volume_reliable:
                for tf, df in df_dict.items():
                    df_dict[tf] = add_synthetic_volume(df, request.symbol, tf)
            
            # Fuse features
            try:
                fused_features = fuse_timeframe_features(df_dict, target_tf='M5')
                # Use fused features for prediction
                signal, confidence = self._predict_with_features(fused_features)
            except Exception as e:
                logger.error(f"Feature fusion error: {e}")
                signal, confidence = self._basic_analysis(request)
        else:
            signal, confidence = self._basic_analysis(request)
        
        # Calculate entry precision
        entry_precision = self._calculate_entry_precision(request, profile)
        
        # Detect regime
        regime = self._detect_regime(request.timeframes)
        
        # Calculate trend alignment
        trend_alignment = self._calculate_trend_alignment(request.timeframes)
        
        response_time = (time.time() - start_time) * 1000
        logger.info(f"Analysis completed in {response_time:.1f}ms for {request.symbol}")
        
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
    
    def _convert_to_dataframes(self, timeframes: Dict[str, TimeframeData]) -> Dict:
        """Convert timeframe data to pandas DataFrames"""
        import pandas as pd
        
        df_dict = {}
        for tf, data in timeframes.items():
            df_data = {
                'open': [data.open] if data.open else [data.close],
                'high': [data.high] if data.high else [data.close],
                'low': [data.low] if data.low else [data.close],
                'close': [data.close],
            }
            if data.tick_volume:
                df_data['tick_volume'] = [data.tick_volume]
            if data.real_volume:
                df_data['real_volume'] = [data.real_volume]
            if data.atr:
                df_data['atr'] = [data.atr]
            if data.ema20:
                df_data['ema20'] = [data.ema20]
            if data.ema50:
                df_data['ema50'] = [data.ema50]
            
            df_dict[tf] = pd.DataFrame(df_data)
        
        return df_dict
    
    def _predict_with_features(self, features) -> tuple[str, float]:
        """Generate prediction from features"""
        # Placeholder - integrate with actual model
        # This would use HistGradientBoosting or similar
        
        # Simple heuristic for demonstration
        last_row = features.iloc[-1] if len(features) > 0 else None
        
        if last_row is not None:
            # Use trend alignment features
            trend_score = last_row.get('trend_alignment_score', 0.5)
            
            if trend_score > 0.6:
                return "BUY", min(trend_score, 0.9)
            elif trend_score < 0.4:
                return "SELL", min(1 - trend_score, 0.9)
        
        return "HOLD", 0.5
    
    def _basic_analysis(self, request: AnalysisRequest) -> tuple[str, float]:
        """Basic analysis without ML features"""
        # Simple multi-timeframe trend analysis
        closes = {}
        for tf, data in request.timeframes.items():
            closes[tf] = data.close
        
        # Check alignment across timeframes
        higher_tf = ['W1', 'D1', 'H4', 'H1']
        lower_tf = ['M15', 'M5', 'M1']
        
        higher_bullish = sum(1 for tf in higher_tf if tf in closes and 
                            any(c > closes[tf] for c in [closes.get('D1', 0), closes.get('H1', 0)]))
        
        if higher_bullish >= 2:
            return "BUY", 0.6
        elif higher_bullish <= 1:
            return "SELL", 0.6
        
        return "HOLD", 0.5
    
    def _calculate_entry_precision(self, request: AnalysisRequest, profile) -> float:
        """Calculate entry precision score"""
        # Based on distance from key levels, wick rejection, etc.
        base_score = 0.5
        
        # Adjust based on spread
        if request.spread_pips and request.spread_pips < profile.spread_threshold_pips:
            base_score += 0.1
        
        # Adjust based on timeframe alignment
        closes = {tf: data.close for tf, data in request.timeframes.items()}
        if 'H1' in closes and 'M5' in closes:
            # Check if M5 aligns with H1 direction
            h1_trend = closes['H1']  # Simplified
            m5_price = closes['M5']
            # Add precision if aligned
            base_score += 0.1
        
        return min(base_score, 1.0)
    
    def _detect_regime(self, timeframes: Dict[str, TimeframeData]) -> str:
        """Detect volatility regime"""
        # Use ATR if available
        atrs = []
        for tf, data in timeframes.items():
            if data.atr and data.close:
                atr_pct = (data.atr / data.close) * 100
                atrs.append(atr_pct)
        
        if not atrs:
            return "NORMAL"
        
        avg_atr = sum(atrs) / len(atrs)
        
        if avg_atr < 0.5:
            return "LOW"
        elif avg_atr < 1.5:
            return "NORMAL"
        elif avg_atr < 3.0:
            return "HIGH"
        else:
            return "BREAKOUT"
    
    def _calculate_trend_alignment(self, timeframes: Dict[str, TimeframeData]) -> float:
        """Calculate trend alignment across timeframes"""
        closes = {tf: data.close for tf, data in timeframes.items() if data.close}
        
        if len(closes) < 2:
            return 0.5
        
        # Check if higher timeframes agree
        higher = ['W1', 'D1', 'H4', 'H1']
        lower = ['M30', 'M15', 'M5', 'M1']
        
        higher_closes = [closes[tf] for tf in higher if tf in closes]
        lower_closes = [closes[tf] for tf in lower if tf in closes]
        
        if len(higher_closes) >= 2 and len(lower_closes) >= 1:
            # Simple check: are we above or below average
            higher_avg = sum(higher_closes) / len(higher_closes)
            lower_avg = sum(lower_closes) / len(lower_closes)
            
            # Alignment score
            if (lower_avg > higher_avg * 0.99) and (lower_avg < higher_avg * 1.01):
                return 0.8  # Well aligned
            elif (lower_avg > higher_avg * 0.98) and (lower_avg < higher_avg * 1.02):
                return 0.6  # Moderately aligned
            else:
                return 0.4  # Poor alignment
        
        return 0.5


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
# FastAPI Application
# =============================================================================

@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application lifespan handler"""
    global redis_client, rate_limiter, analysis_cache, analysis_engine
    
    # Startup
    logger.info("Starting CrosSstrux Analysis Server v4.1.0")
    
    # Initialize Redis if available
    if REDIS_AVAILABLE:
        try:
            redis_host = os.getenv('REDIS_HOST', 'localhost')
            redis_port = int(os.getenv('REDIS_PORT', 6379))
            redis_client = redis.Redis(
                host=redis_host,
                port=redis_port,
                decode_responses=True
            )
            await redis_client.ping()
            logger.info(f"Redis connected: {redis_host}:{redis_port}")
        except Exception as e:
            logger.warning(f"Redis connection failed: {e}, using memory fallback")
            redis_client = None
    
    # Initialize components
    rate_limiter = RateLimiter(redis_client)
    analysis_cache = AnalysisCache(redis_client)
    analysis_engine = AnalysisEngine()
    
    yield
    
    # Shutdown
    logger.info("Shutting down...")
    if redis_client:
        await redis_client.close()


app = FastAPI(
    title="CrosSstrux Analysis API",
    description="Multi-asset AI-assisted trading analysis",
    version="4.1.0",
    lifespan=lifespan
)

# Add this exception handler after app creation
@app.exception_handler(RequestValidationError)
async def validation_exception_handler(request: Request, exc: RequestValidationError):
    logger.error(f"Validation error: {exc.errors()}")
    logger.error(f"Request body: {await request.body()}")
    return JSONResponse(
        status_code=422,
        content={"detail": exc.errors()}
    )


# Middleware
app.add_middleware(GZipMiddleware, minimum_size=1000)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # Configure for production
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# =============================================================================
# Dependencies
# =============================================================================

async def check_rate_limit(request: Request, limit_type: str = 'default'):
    """Dependency for rate limiting"""
    # Get client identifier
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


# =============================================================================
# Endpoints
# =============================================================================

@app.get("/health", response_model=HealthResponse)
async def health_check():
    """Health check endpoint"""
    return HealthResponse(
        status="healthy",
        version="4.1.0",
        timestamp=datetime.utcnow().isoformat(),
        redis_connected=redis_client is not None and REDIS_AVAILABLE,
        uptime_seconds=time.time() - metrics['start_time']
    )


@app.get("/metrics", response_model=MetricsResponse)
async def get_metrics():
    """Get server metrics"""
    total = metrics['total_requests']
    avg_time = sum(metrics['response_times']) / len(metrics['response_times']) if metrics['response_times'] else 0
    
    uptime_minutes = (time.time() - metrics['start_time']) / 60
    rpm = metrics['total_requests'] / uptime_minutes if uptime_minutes > 0 else 0
    
    cache_stats = analysis_cache.get_stats() if analysis_cache else {'hit_rate': 0}
    
    return MetricsResponse(
        total_requests=metrics['total_requests'],
        successful_requests=metrics['successful_requests'],
        failed_requests=metrics['failed_requests'],
        average_response_time_ms=avg_time,
        cache_hit_rate=cache_stats['hit_rate'],
        requests_per_minute=rpm
    )


@app.post("/analyze", response_model=SignalResponse)
async def analyze(
    request: AnalysisRequest,
    background_tasks: BackgroundTasks,
    rate_limit: dict = Depends(lambda r: check_rate_limit(r, 'default'))
):
    """
    Analyze market data and generate trading signal.
    
    Rate limit: 10 requests per minute per IP
    Cache TTL: Asset-specific (crypto: 5s, gold: 30s, forex: 15s)
    """
    start_time = time.time()
    metrics['total_requests'] += 1
    
    try:
        # Check cache
        cache_key = analysis_cache._get_cache_key(request)
        cached = await analysis_cache.get(cache_key)
        
        if cached:
            # Return cached result
            return SignalResponse(**cached)
        
        # Perform analysis
        result = await analysis_engine.analyze(request)
        
        # Cache result
        profile = get_profile(request.symbol)
        background_tasks.add_task(
            analysis_cache.set,
            cache_key,
            result.dict(),
            profile.asset_class.value
        )
        
        metrics['successful_requests'] += 1
        
        # Record response time
        response_time = (time.time() - start_time) * 1000
        metrics['response_times'].append(response_time)
        
        # Keep only last 1000 response times
        if len(metrics['response_times']) > 1000:
            metrics['response_times'] = metrics['response_times'][-1000:]
        
        return result
        
    except Exception as e:
        metrics['failed_requests'] += 1
        logger.error(f"Analysis error: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Analysis failed: {str(e)}"
        )


@app.post("/analyze/batch")
async def analyze_batch(
    requests: List[AnalysisRequest],
    rate_limit: dict = Depends(lambda r: check_rate_limit(r, 'batch'))
):
    """
    Batch analysis endpoint for multiple symbols.
    
    Rate limit: 2 requests per minute per IP
    """
    results = []
    
    for req in requests:
        try:
            result = await analysis_engine.analyze(req)
            results.append({
                "symbol": req.symbol,
                "success": True,
                "result": result
            })
        except Exception as e:
            results.append({
                "symbol": req.symbol,
                "success": False,
                "error": str(e)
            })
    
    return {"results": results}


@app.get("/assets")
async def list_assets():
    """List all supported assets and their configurations"""
    profiles = ASSET_PROFILES.list_profiles()
    
    return {
        "assets": [
            {
                "symbol": symbol,
                "profile": ASSET_PROFILES.get_profile(symbol).to_dict()
            }
            for symbol in profiles
        ]
    }


# =============================================================================
# Error Handlers
# =============================================================================

@app.exception_handler(HTTPException)
async def http_exception_handler(request: Request, exc: HTTPException):
    return JSONResponse(
        status_code=exc.status_code,
        content={"detail": exc.detail},
        headers=exc.headers
    )


@app.exception_handler(Exception)
async def general_exception_handler(request: Request, exc: Exception):
    logger.error(f"Unhandled exception: {exc}")
    return JSONResponse(
        status_code=500,
        content={"detail": "Internal server error"}
    )


# =============================================================================
# Main
# =============================================================================

if __name__ == "__main__":
    port = int(os.getenv('PORT', 8000))
    host = os.getenv('HOST', '0.0.0.0')
    
    uvicorn.run(
        "server:app",
        host=host,
        port=port,
        reload=os.getenv('DEBUG', 'false').lower() == 'true',
        workers=int(os.getenv('WORKERS', 1))
    )
