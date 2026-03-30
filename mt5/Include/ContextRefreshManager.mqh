//+------------------------------------------------------------------+
//| ContextRefreshManager.mqh - Adaptive API Caching v4.1.0          |
//+------------------------------------------------------------------+
//| Description: Manages adaptive refresh intervals based on market  |
//|              regime, volatility, and API availability. Includes |
//|              fallback mode for API failures.                      |
//+------------------------------------------------------------------+
#ifndef CONTEXT_REFRESH_MANAGER_MQH
#define CONTEXT_REFRESH_MANAGER_MQH

#include "AssetProfile.mqh"
#include "SpreadManager.mqh"
#include <Object.mqh>

//+------------------------------------------------------------------+
//| API Status Enumeration                                             |
//+------------------------------------------------------------------+
enum ENUM_API_STATUS
{
   API_STATUS_OK,           // Normal operation
   API_STATUS_DEGRADED,     // Slow responses
   API_STATUS_FALLBACK,     // Using cached data
   API_STATUS_OFFLINE       // No connectivity
};

//+------------------------------------------------------------------+
//| Refresh Context Structure                                          |
//+------------------------------------------------------------------+
struct RefreshContext
{
   datetime lastContextRefresh;
   datetime lastSignalRefresh;
   datetime lastSuccessfulApiCall;
   datetime fallbackModeStart;
   
   int consecutiveFailures;
   int totalRequests;
   int successfulRequests;
   double avgResponseTime;
   
   bool inFallbackMode;
   ENUM_API_STATUS apiStatus;
   
   void Reset()
   {
      lastContextRefresh = 0;
      lastSignalRefresh = 0;
      lastSuccessfulApiCall = 0;
      fallbackModeStart = 0;
      consecutiveFailures = 0;
      totalRequests = 0;
      successfulRequests = 0;
      avgResponseTime = 0;
      inFallbackMode = false;
      apiStatus = API_STATUS_OK;
   }
   
   double GetSuccessRate()
   {
      if(totalRequests == 0) return 100.0;
      return (double)successfulRequests / totalRequests * 100.0;
   }
};

//+------------------------------------------------------------------+
//| Context Refresh Manager Class                                      |
//+------------------------------------------------------------------+
class CContextRefreshManager : public CObject
{
private:
   string m_symbol;
   AssetProfile m_profile;
   CSpreadManager* m_spreadManager;
   
   RefreshContext m_context;
   
   // Timing
   int m_baseContextInterval;
   int m_baseSignalInterval;
   int m_currentContextInterval;
   int m_currentSignalInterval;
   
   // Retry logic
   int m_retryDelays[];
   int m_currentRetryIndex;
   datetime m_nextAllowedCall;
   
   // Adaptive multipliers by regime
   double m_regimeMultipliers[5];  // Indexed by ENUM_VOLATILITY_REGIME
   
   // Session tracking
   int m_lastHour;
   bool m_isHighVolumeHour;
   
public:
   CContextRefreshManager(void);
   ~CContextRefreshManager(void);
   
   // Initialization
   bool Initialize(const string symbol, CSpreadManager* spreadMgr);
   
   // Core refresh decisions
   bool ShouldRefreshContext(void);
   bool ShouldRefreshSignal(void);
   bool ShouldCallAPI(void);
   
   // API result recording
   void RecordApiSuccess(double responseTimeMs);
   void RecordApiFailure(string reason);
   void RecordApiTimeout(void);
   
   // Fallback mode
   bool IsInFallbackMode(void) { return m_context.inFallbackMode; }
   void EnterFallbackMode(void);
   void ExitFallbackMode(void);
   bool IsCacheValid(bool isContext);
   int GetCacheAge(bool isContext);
   
   // Adaptive updates
   void UpdateAdaptiveIntervals(void);
   void SetRegimeMultiplier(ENUM_VOLATILITY_REGIME regime, double multiplier);
   
   // Status queries
   ENUM_API_STATUS GetApiStatus(void) { return m_context.apiStatus; }
   RefreshContext GetStatistics(void) { return m_context; }
   int GetCurrentContextInterval(void) { return m_currentContextInterval; }
   int GetCurrentSignalInterval(void) { return m_currentSignalInterval; }
   
   // Logging
   void LogStatus(void);
   string GetStatusString(void);
   
private:
   bool IsHighVolumeHour(void);
   void UpdateSessionStatus(void);
   int GetRetryDelay(void);
   void ResetRetryBackoff(void);
};

//+------------------------------------------------------------------+
//| Constructor                                                        |
//+------------------------------------------------------------------+
CContextRefreshManager::CContextRefreshManager(void)
{
   m_symbol = "";
   m_spreadManager = NULL;
   m_context.Reset();
   
   m_baseContextInterval = 60;
   m_baseSignalInterval = 30;
   m_currentContextInterval = 60;
   m_currentSignalInterval = 30;
   
   // Initialize retry delays (exponential backoff)
   ArrayResize(m_retryDelays, 6);
   m_retryDelays[0] = 2;    // 2 seconds
   m_retryDelays[1] = 4;    // 4 seconds
   m_retryDelays[2] = 8;    // 8 seconds
   m_retryDelays[3] = 16;   // 16 seconds
   m_retryDelays[4] = 32;   // 32 seconds
   m_retryDelays[5] = 60;   // 60 seconds max
   
   m_currentRetryIndex = 0;
   m_nextAllowedCall = 0;
   m_lastHour = -1;
   m_isHighVolumeHour = false;
   
   // Default regime multipliers
   // Low vol: slower (save API calls)
   // High vol: faster (be responsive)
   m_regimeMultipliers[VOL_REGIME_LOW] = 2.0;       // 2x slower
   m_regimeMultipliers[VOL_REGIME_NORMAL] = 1.0;    // Base
   m_regimeMultipliers[VOL_REGIME_HIGH] = 0.5;      // 2x faster
   m_regimeMultipliers[VOL_REGIME_BREAKOUT] = 0.25; // 4x faster
   m_regimeMultipliers[VOL_REGIME_EXTREME] = 0.5;   // 2x faster (but careful)
}

//+------------------------------------------------------------------+
//| Destructor                                                         |
//+------------------------------------------------------------------+
CContextRefreshManager::~CContextRefreshManager(void)
{
   ArrayResize(m_retryDelays, 0);
}

//+------------------------------------------------------------------+
//| Initialize                                                         |
//+------------------------------------------------------------------+
bool CContextRefreshManager::Initialize(const string symbol, CSpreadManager* spreadMgr)
{
   m_symbol = symbol;
   m_spreadManager = spreadMgr;
   
   // Load profile
   if(!AssetProfileRegistry.GetProfile(symbol, m_profile))
   {
      Print("ContextRefreshManager: Using default profile for ", symbol);
      m_profile = AssetProfile();
   }
   
   // Set base intervals from profile
   m_baseContextInterval = m_profile.contextCacheSeconds;
   m_baseSignalInterval = m_profile.signalCacheSeconds;
   m_currentContextInterval = m_baseContextInterval;
   m_currentSignalInterval = m_baseSignalInterval;
   
   Print("ContextRefreshManager initialized for ", symbol);
   Print("  Base Context Interval: ", m_baseContextInterval, "s");
   Print("  Base Signal Interval: ", m_baseSignalInterval, "s");
   
   return true;
}

//+------------------------------------------------------------------+
//| Should Refresh Context                                             |
//+------------------------------------------------------------------+
bool CContextRefreshManager::ShouldRefreshContext(void)
{
   datetime now = TimeCurrent();
   int age = (int)(now - m_context.lastContextRefresh);
   
   // In fallback mode, use extended cache
   if(m_context.inFallbackMode)
   {
      int fallbackTTL = m_profile.maxCacheAgeFallback;
      if(age >= fallbackTTL)
      {
         Print("Fallback cache expired (", age, "s > ", fallbackTTL, "s), attempting refresh");
         return true;
      }
      return false;
   }
   
   // Normal operation
   if(age >= m_currentContextInterval)
      return true;
   
   // Force refresh if never refreshed
   if(m_context.lastContextRefresh == 0)
      return true;
   
   return false;
}

//+------------------------------------------------------------------+
//| Should Refresh Signal                                                |
//+------------------------------------------------------------------+
bool CContextRefreshManager::ShouldRefreshSignal(void)
{
   datetime now = TimeCurrent();
   int age = (int)(now - m_context.lastSignalRefresh);
   
   // In fallback mode, use extended cache
   if(m_context.inFallbackMode)
   {
      int fallbackTTL = m_profile.maxCacheAgeFallback / 2;  // Signals expire faster
      if(age >= fallbackTTL)
         return true;
      return false;
   }
   
   // Normal operation
   if(age >= m_currentSignalInterval)
      return true;
   
   // Force refresh if never refreshed
   if(m_context.lastSignalRefresh == 0)
      return true;
   
   return false;
}

//+------------------------------------------------------------------+
//| Should Call API (rate limiting & backoff)                          |
//+------------------------------------------------------------------+
bool CContextRefreshManager::ShouldCallAPI(void)
{
   datetime now = TimeCurrent();
   
   // Check rate limiting / backoff
   if(now < m_nextAllowedCall)
   {
      return false;
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| Record API Success                                                 |
//+------------------------------------------------------------------+
void CContextRefreshManager::RecordApiSuccess(double responseTimeMs)
{
   m_context.consecutiveFailures = 0;
   m_context.totalRequests++;
   m_context.successfulRequests++;
   m_context.lastSuccessfulApiCall = TimeCurrent();
   
   // Update running average
   if(m_context.avgResponseTime == 0)
      m_context.avgResponseTime = responseTimeMs;
   else
      m_context.avgResponseTime = m_context.avgResponseTime * 0.9 + responseTimeMs * 0.1;
   
   // Exit fallback mode if we were in it
   if(m_context.inFallbackMode)
   {
      ExitFallbackMode();
   }
   
   // Reset retry backoff
   ResetRetryBackoff();
   
   // Update API status
   if(responseTimeMs > 5000)  // >5s is slow
      m_context.apiStatus = API_STATUS_DEGRADED;
   else
      m_context.apiStatus = API_STATUS_OK;
   
   // Update refresh timestamps
   m_context.lastContextRefresh = TimeCurrent();
   m_context.lastSignalRefresh = TimeCurrent();
}

//+------------------------------------------------------------------+
//| Record API Failure                                                 |
//+------------------------------------------------------------------+
void CContextRefreshManager::RecordApiFailure(string reason)
{
   m_context.consecutiveFailures++;
   m_context.totalRequests++;
   
   Print("API Failure #", m_context.consecutiveFailures, ": ", reason);
   
   // Apply retry backoff
   int delay = GetRetryDelay();
   m_nextAllowedCall = TimeCurrent() + delay;
   
   Print("Retry backoff: next call allowed in ", delay, " seconds");
   
   // Check for fallback mode trigger (3 consecutive failures)
   if(m_context.consecutiveFailures >= 3 && !m_context.inFallbackMode)
   {
      EnterFallbackMode();
   }
   
   // Update API status
   if(m_context.consecutiveFailures >= 2)
      m_context.apiStatus = API_STATUS_DEGRADED;
   if(m_context.consecutiveFailures >= 5)
      m_context.apiStatus = API_STATUS_OFFLINE;
}

//+------------------------------------------------------------------+
//| Record API Timeout                                                 |
//+------------------------------------------------------------------+
void CContextRefreshManager::RecordApiTimeout(void)
{
   RecordApiFailure("Timeout");
}

//+------------------------------------------------------------------+
//| Enter Fallback Mode                                                |
//+------------------------------------------------------------------+
void CContextRefreshManager::EnterFallbackMode(void)
{
   if(!m_context.inFallbackMode)
   {
      m_context.inFallbackMode = true;
      m_context.fallbackModeStart = TimeCurrent();
      m_context.apiStatus = API_STATUS_FALLBACK;
      
      Print("=== ENTERING FALLBACK MODE ===");
      Print("API unavailable, using extended cache (", m_profile.maxCacheAgeFallback, "s)");
      
      // Notify user
      SendNotification(StringFormat("%s: API Fallback Mode - using cached data", m_symbol));
   }
}

//+------------------------------------------------------------------+
//| Exit Fallback Mode                                                 |
//+------------------------------------------------------------------+
void CContextRefreshManager::ExitFallbackMode(void)
{
   if(m_context.inFallbackMode)
   {
      int duration = (int)(TimeCurrent() - m_context.fallbackModeStart);
      Print("=== EXITING FALLBACK MODE ===");
      Print("Duration: ", duration, " seconds");
      
      m_context.inFallbackMode = false;
      m_context.fallbackModeStart = 0;
      m_context.consecutiveFailures = 0;
      
      SendNotification(StringFormat("%s: API Restored - normal operation", m_symbol));
   }
}

//+------------------------------------------------------------------+
//| Is Cache Valid                                                     |
//+------------------------------------------------------------------+
bool CContextRefreshManager::IsCacheValid(bool isContext)
{
   int age = GetCacheAge(isContext);
   
   if(m_context.inFallbackMode)
   {
      return age < m_profile.maxCacheAgeFallback;
   }
   
   int ttl = isContext ? m_currentContextInterval : m_currentSignalInterval;
   return age < ttl;
}

//+------------------------------------------------------------------+
//| Get Cache Age                                                      |
//+------------------------------------------------------------------+
int CContextRefreshManager::GetCacheAge(bool isContext)
{
   datetime lastRefresh = isContext ? m_context.lastContextRefresh : m_context.lastSignalRefresh;
   return (int)(TimeCurrent() - lastRefresh);
}

//+------------------------------------------------------------------+
//| Update Adaptive Intervals                                            |
//+------------------------------------------------------------------+
void CContextRefreshManager::UpdateAdaptiveIntervals(void)
{
   if(m_spreadManager == NULL)
      return;
   
   // Get current volatility regime from spread manager
   ENUM_VOLATILITY_REGIME regime = m_spreadManager.GetCurrentRegime();
   
   // Get multiplier for this regime
   double multiplier = m_regimeMultipliers[regime];
   
   // Adjust for high volume hours
   UpdateSessionStatus();
   if(m_isHighVolumeHour)
   {
      multiplier *= 0.8;  // 20% faster during high volume
   }
   
   // Calculate new intervals
   m_currentContextInterval = (int)(m_baseContextInterval * multiplier);
   m_currentSignalInterval = (int)(m_baseSignalInterval * multiplier);
   
   // Enforce minimums
   if(m_currentContextInterval < 10) m_currentContextInterval = 10;
   if(m_currentSignalInterval < 5) m_currentSignalInterval = 5;
   
   // Enforce maximums (don't go too slow)
   if(m_currentContextInterval > 300) m_currentContextInterval = 300;
   if(m_currentSignalInterval > 120) m_currentSignalInterval = 120;
}

//+------------------------------------------------------------------+
//| Set Regime Multiplier                                              |
//+------------------------------------------------------------------+
void CContextRefreshManager::SetRegimeMultiplier(ENUM_VOLATILITY_REGIME regime, double multiplier)
{
   if(regime >= VOL_REGIME_LOW && regime <= VOL_REGIME_EXTREME)
   {
      m_regimeMultipliers[regime] = multiplier;
   }
}

//+------------------------------------------------------------------+
//| Is High Volume Hour                                                |
//+------------------------------------------------------------------+
bool CContextRefreshManager::IsHighVolumeHour(void)
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int hour = dt.hour;
   
   for(int i = 0; i < ArraySize(m_profile.highVolumeHours); i++)
   {
      if(m_profile.highVolumeHours[i] == hour)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Update Session Status                                              |
//+------------------------------------------------------------------+
void CContextRefreshManager::UpdateSessionStatus(void)
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   
   if(dt.hour != m_lastHour)
   {
      m_lastHour = dt.hour;
      m_isHighVolumeHour = IsHighVolumeHour();
   }
}

//+------------------------------------------------------------------+
//| Get Retry Delay                                                    |
//+------------------------------------------------------------------+
int CContextRefreshManager::GetRetryDelay(void)
{
   int delay = m_retryDelays[m_currentRetryIndex];
   
   // Advance index (capped at max)
   if(m_currentRetryIndex < ArraySize(m_retryDelays) - 1)
      m_currentRetryIndex++;
   
   return delay;
}

//+------------------------------------------------------------------+
//| Reset Retry Backoff                                                |
//+------------------------------------------------------------------+
void CContextRefreshManager::ResetRetryBackoff(void)
{
   m_currentRetryIndex = 0;
   m_nextAllowedCall = 0;
}

//+------------------------------------------------------------------+
//| Log Status                                                         |
//+------------------------------------------------------------------+
void CContextRefreshManager::LogStatus(void)
{
   Print(GetStatusString());
}

//+------------------------------------------------------------------+
//| Get Status String                                                  |
//+------------------------------------------------------------------+
string CContextRefreshManager::GetStatusString(void)
{
   string status;
   
   if(m_context.inFallbackMode)
   {
      int fallbackAge = (int)(TimeCurrent() - m_context.fallbackModeStart);
      status = StringFormat(
         "[FALLBACK] Age:%dm | Cache:%ds/%ds | Success:%.0f%%",
         fallbackAge / 60,
         GetCacheAge(true),
         m_profile.maxCacheAgeFallback,
         m_context.GetSuccessRate()
      );
   }
   else
   {
      string apiStr;
      switch(m_context.apiStatus)
      {
         case API_STATUS_OK:       apiStr = "OK"; break;
         case API_STATUS_DEGRADED: apiStr = "DEGRADED"; break;
         case API_STATUS_FALLBACK: apiStr = "FALLBACK"; break;
         case API_STATUS_OFFLINE:  apiStr = "OFFLINE"; break;
         default:                  apiStr = "UNKNOWN";
      }
      
      status = StringFormat(
         "[%s] Ctx:%ds/%ds | Sig:%ds/%ds | Success:%.0f%% | AvgRT:%.0fms",
         apiStr,
         GetCacheAge(true),
         m_currentContextInterval,
         GetCacheAge(false),
         m_currentSignalInterval,
         m_context.GetSuccessRate(),
         m_context.avgResponseTime
      );
   }
   
   return status;
}

#endif // CONTEXT_REFRESH_MANAGER_MQH
