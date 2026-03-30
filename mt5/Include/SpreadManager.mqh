//+------------------------------------------------------------------+
//| SpreadManager.mqh - Asset-Aware Spread Management v4.1.0          |
//+------------------------------------------------------------------+
//| Description: Normalizes spread calculations across different asset |
//|              classes using point multipliers. Prevents false     |
//|              rejections due to asset-specific point structures.  |
//+------------------------------------------------------------------+
#ifndef SPREAD_MANAGER_MQH
#define SPREAD_MANAGER_MQH

#include "AssetProfile.mqh"
#include </Math/Stat/Stat.mqh>

//+------------------------------------------------------------------+
//| Spread Statistics Structure                                        |
//+------------------------------------------------------------------+
struct SpreadStatistics
{
   double currentSpreadPips;
   double currentSpreadPoints;
   double averageSpreadPips;
   double minSpreadPips;
   double maxSpreadPips;
   double spreadPercentile;       // Current vs history (0-100)
   int sampleCount;
   datetime lastUpdate;
   
   void Reset()
   {
      currentSpreadPips = 0;
      currentSpreadPoints = 0;
      averageSpreadPips = 0;
      minSpreadPips = 999999;
      maxSpreadPips = 0;
      spreadPercentile = 50;
      sampleCount = 0;
      lastUpdate = 0;
   }
};

//+------------------------------------------------------------------+
//| Spread Manager Class                                               |
//+------------------------------------------------------------------+
class CSpreadManager : public CObject
{
private:
   string m_symbol;
   AssetProfile m_profile;
   bool m_profileLoaded;
   
   // Spread tracking
   double m_spreadHistory[];
   int m_historySize;
   int m_historyIndex;
   
   // Current state
   SpreadStatistics m_stats;
   ENUM_VOLATILITY_REGIME m_currentRegime;
   
   // Thresholds
   double m_adaptiveThreshold;
   bool m_emergencyMode;
   datetime m_emergencyStart;
   
public:
   CSpreadManager(void);
   ~CSpreadManager(void);
   
   // Initialization
   bool Initialize(const string symbol);
   bool IsInitialized(void) { return m_profileLoaded; }
   
   // Core spread calculation (CRITICAL FIX)
   double GetSpreadPoints(void);
   double GetSpreadPips(void);           // NORMALIZED
   double GetSpreadMoney(void);          // Monetary value
   double GetSpreadPercentOfPrice(void); // As % of price
   
   // Validation
   bool IsSpreadAcceptable(void);        // Primary check
   bool IsSpreadEmergency(void);          // Emergency cutoff
   string GetRejectionReason(void);       // Why rejected
   
   // Adaptive thresholds
   void UpdateAdaptiveThreshold(void);
   double GetCurrentThreshold(void);
   
   // Statistics
   void UpdateStatistics(void);
   SpreadStatistics GetStatistics(void) { return m_stats; }
   double GetAverageSpread(void) { return m_stats.averageSpreadPips; }
   
   // Volatility regime
   void DetectVolatilityRegime(void);
   ENUM_VOLATILITY_REGIME GetCurrentRegime(void) { return m_currentRegime; }
   string GetRegimeString(void);
   
   // Logging
   void LogSpreadStatus(void);
   string FormatSpreadInfo(void);
   
   // Emergency handling
   bool IsEmergencyMode(void) { return m_emergencyMode; }
   void ClearEmergencyMode(void);
   
private:
   void AddToHistory(double spreadPips);
   double CalculatePercentile(double value);
};

//+------------------------------------------------------------------+
//| Constructor                                                        |
//+------------------------------------------------------------------+
CSpreadManager::CSpreadManager(void)
{
   m_symbol = "";
   m_profileLoaded = false;
   m_historySize = 100;
   ArrayResize(m_spreadHistory, m_historySize);
   ArrayInitialize(m_spreadHistory, 0);
   m_historyIndex = 0;
   m_stats.Reset();
   m_currentRegime = VOL_REGIME_NORMAL;
   m_adaptiveThreshold = 0;
   m_emergencyMode = false;
   m_emergencyStart = 0;
}

//+------------------------------------------------------------------+
//| Destructor                                                         |
//+------------------------------------------------------------------+
CSpreadManager::~CSpreadManager(void)
{
   ArrayResize(m_spreadHistory, 0);
}

//+------------------------------------------------------------------+
//| Initialize                                                         |
//+------------------------------------------------------------------+
bool CSpreadManager::Initialize(const string symbol)
{
   m_symbol = symbol;
   
   // Load asset profile
   m_profileLoaded = AssetProfileRegistry.GetProfile(symbol, m_profile);
   
   if(!m_profileLoaded)
   {
      Print("SpreadManager: WARNING - Using default profile for ", symbol);
      m_profile = AssetProfile();  // Default
      m_profile.symbol = symbol;
      m_profileLoaded = true;
   }
   
   // Log initialization
   Print("SpreadManager initialized for ", symbol);
   Print("  Point Multiplier: ", m_profile.pointMultiplier);
   Print("  Spread Threshold: ", m_profile.spreadThresholdPips, " pips");
   Print("  Emergency Threshold: ", m_profile.spreadEmergencyPips, " pips");
   
   // Initial spread reading
   UpdateStatistics();
   m_adaptiveThreshold = m_profile.spreadThresholdPips;
   
   return true;
}

//+------------------------------------------------------------------+
//| Get Spread in Points (Raw)                                         |
//+------------------------------------------------------------------+
double CSpreadManager::GetSpreadPoints(void)
{
   if(!SymbolSelect(m_symbol, true))
      return 0;
      
   MqlTick tick;
   if(!SymbolInfoTick(m_symbol, tick))
      return 0;
   
   double point = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
   if(point == 0) return 0;
   
   return (tick.ask - tick.bid) / point;
}

//+------------------------------------------------------------------+
//| Get Spread in Pips (NORMALIZED - CRITICAL FIX)                     |
//+------------------------------------------------------------------+
double CSpreadManager::GetSpreadPips(void)
{
   double spreadPoints = GetSpreadPoints();
   
   // CRITICAL FIX: Normalize using asset-specific point multiplier
   // BTCUSD: 5000 points / 100 = 50 pips (NORMAL!)
   // XAUUSD: 50 points / 10 = 5 pips (NORMAL!)
   // EURUSD: 2 points / 10 = 0.2 pips (NORMAL!)
   
   double spreadPips = spreadPoints / m_profile.pointMultiplier;
   
   return spreadPips;
}

//+------------------------------------------------------------------+
//| Get Spread in Money                                                |
//+------------------------------------------------------------------+
double CSpreadManager::GetSpreadMoney(void)
{
   MqlTick tick;
   if(!SymbolInfoTick(m_symbol, tick))
      return 0;
   
   return tick.ask - tick.bid;
}

//+------------------------------------------------------------------+
//| Get Spread as % of Price                                           |
//+------------------------------------------------------------------+
double CSpreadManager::GetSpreadPercentOfPrice(void)
{
   MqlTick tick;
   if(!SymbolInfoTick(m_symbol, tick))
      return 0;
   
   double mid = (tick.ask + tick.bid) / 2.0;
   if(mid == 0) return 0;
   
   return ((tick.ask - tick.bid) / mid) * 100.0;
}

//+------------------------------------------------------------------+
//| Is Spread Acceptable                                               |
//+------------------------------------------------------------------+
bool CSpreadManager::IsSpreadAcceptable(void)
{
   double spreadPips = GetSpreadPips();
   double threshold = GetCurrentThreshold();
   
   // Check emergency mode first
   if(m_emergencyMode)
   {
      // Emergency mode lasts 5 minutes or until spread normalizes
      if(TimeCurrent() - m_emergencyStart > 300)
      {
         ClearEmergencyMode();
      }
      else if(spreadPips > m_profile.spreadEmergencyPips)
      {
         return false;  // Still in emergency
      }
   }
   
   // Check against adaptive threshold
   if(spreadPips > threshold)
   {
      // Check if this is a temporary spike
      if(spreadPips > m_profile.spreadEmergencyPips)
      {
         m_emergencyMode = true;
         m_emergencyStart = TimeCurrent();
         Print("SPREAD EMERGENCY: ", spreadPips, " pips exceeds emergency threshold ", 
               m_profile.spreadEmergencyPips);
         return false;
      }
      
      // If above threshold but not emergency, check percentile
      if(m_stats.sampleCount > 20)
      {
         double percentile = CalculatePercentile(spreadPips);
         if(percentile > 95)
         {
            // 95th percentile spike - likely news/event
            Print("High spread percentile: ", percentile, "% - possible news event");
            return false;
         }
      }
      
      return false;
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| Get Rejection Reason                                               |
//+------------------------------------------------------------------+
string CSpreadManager::GetRejectionReason(void)
{
   double spreadPips = GetSpreadPips();
   double threshold = GetCurrentThreshold();
   
   if(m_emergencyMode)
      return "EMERGENCY MODE: Spread spike detected";
   
   if(spreadPips > m_profile.spreadEmergencyPips)
      return StringFormat("Emergency spread: %.1f pips (max %.1f)", 
                         spreadPips, m_profile.spreadEmergencyPips);
   
   if(spreadPips > threshold)
      return StringFormat("Spread too high: %.1f pips (threshold %.1f)", 
                         spreadPips, threshold);
   
   return "Spread acceptable";
}

//+------------------------------------------------------------------+
//| Is Spread Emergency                                                |
//+------------------------------------------------------------------+
bool CSpreadManager::IsSpreadEmergency(void)
{
   double spreadPips = GetSpreadPips();
   return (spreadPips > m_profile.spreadEmergencyPips);
}

//+------------------------------------------------------------------+
//| Update Adaptive Threshold                                          |
//+------------------------------------------------------------------+
void CSpreadManager::UpdateAdaptiveThreshold(void)
{
   if(m_stats.sampleCount < 20)
   {
      m_adaptiveThreshold = m_profile.spreadThresholdPips;
      return;
   }
   
   // Adaptive threshold based on recent average + buffer
   double baseThreshold = m_profile.spreadThresholdPips;
   double recentAvg = m_stats.averageSpreadPips;
   
   // If average is significantly higher than base, adapt up
   if(recentAvg > baseThreshold * 0.8)
   {
      m_adaptiveThreshold = MathMin(recentAvg * 1.5, m_profile.spreadEmergencyPips * 0.8);
   }
   else
   {
      m_adaptiveThreshold = baseThreshold;
   }
   
   // Regime adjustment
   switch(m_currentRegime)
   {
      case VOL_REGIME_LOW:
         m_adaptiveThreshold *= 0.9;  // Tighter in low vol
         break;
      case VOL_REGIME_HIGH:
         m_adaptiveThreshold *= 1.2;  // Looser in high vol
         break;
      case VOL_REGIME_BREAKOUT:
      case VOL_REGIME_EXTREME:
         m_adaptiveThreshold *= 1.5;  // Much looser in extreme vol
         break;
      default:
         break;
   }
}

//+------------------------------------------------------------------+
//| Get Current Threshold                                              |
//+------------------------------------------------------------------+
double CSpreadManager::GetCurrentThreshold(void)
{
   return m_adaptiveThreshold > 0 ? m_adaptiveThreshold : m_profile.spreadThresholdPips;
}

//+------------------------------------------------------------------+
//| Update Statistics                                                  |
//+------------------------------------------------------------------+
void CSpreadManager::UpdateStatistics(void)
{
   double spreadPips = GetSpreadPips();
   double spreadPoints = GetSpreadPoints();
   
   m_stats.currentSpreadPips = spreadPips;
   m_stats.currentSpreadPoints = spreadPoints;
   m_stats.lastUpdate = TimeCurrent();
   
   // Add to history
   AddToHistory(spreadPips);
   
   // Calculate statistics
   if(m_stats.sampleCount > 0)
   {
      double sum = 0;
      double minVal = 999999;
      double maxVal = 0;
      
      for(int i = 0; i < MathMin(m_stats.sampleCount, m_historySize); i++)
      {
         double val = m_spreadHistory[i];
         sum += val;
         if(val < minVal) minVal = val;
         if(val > maxVal) maxVal = val;
      }
      
      m_stats.averageSpreadPips = sum / MathMin(m_stats.sampleCount, m_historySize);
      m_stats.minSpreadPips = minVal;
      m_stats.maxSpreadPips = maxVal;
      m_stats.spreadPercentile = CalculatePercentile(spreadPips);
   }
   
   m_stats.sampleCount++;
   
   // Update adaptive threshold periodically
   if(m_stats.sampleCount % 10 == 0)
      UpdateAdaptiveThreshold();
}

//+------------------------------------------------------------------+
//| Add to History                                                     |
//+------------------------------------------------------------------+
void CSpreadManager::AddToHistory(double spreadPips)
{
   m_spreadHistory[m_historyIndex] = spreadPips;
   m_historyIndex = (m_historyIndex + 1) % m_historySize;
}

//+------------------------------------------------------------------+
//| Calculate Percentile                                               |
//+------------------------------------------------------------------+
double CSpreadManager::CalculatePercentile(double value)
{
   if(m_stats.sampleCount < 10) return 50.0;
   
   int count = MathMin(m_stats.sampleCount, m_historySize);
   int below = 0;
   
   for(int i = 0; i < count; i++)
   {
      if(m_spreadHistory[i] < value)
         below++;
   }
   
   return (double)below / count * 100.0;
}

//+------------------------------------------------------------------+
//| Detect Volatility Regime                                           |
//+------------------------------------------------------------------+
void CSpreadManager::DetectVolatilityRegime(void)
{
   // Use ATR-based volatility detection
   int handle = iATR(m_symbol, PERIOD_CURRENT, 14);
   if(handle == INVALID_HANDLE)
   {
      m_currentRegime = VOL_REGIME_NORMAL;
      return;
   }
   
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(handle, 0, 0, 1, atr) < 1)
   {
      IndicatorRelease(handle);
      m_currentRegime = VOL_REGIME_NORMAL;
      return;
   }
   
   IndicatorRelease(handle);
   
   MqlTick tick;
   if(!SymbolInfoTick(m_symbol, tick))
   {
      m_currentRegime = VOL_REGIME_NORMAL;
      return;
   }
   
   double price = tick.bid;
   if(price == 0)
   {
      m_currentRegime = VOL_REGIME_NORMAL;
      return;
   }
   
   double atrPct = (atr[0] / price) * 100.0;
   
   // Classify regime based on ATR %
   if(atrPct < m_profile.volLowThreshold)
      m_currentRegime = VOL_REGIME_LOW;
   else if(atrPct < m_profile.volNormalThreshold)
      m_currentRegime = VOL_REGIME_NORMAL;
   else if(atrPct < m_profile.volHighThreshold)
      m_currentRegime = VOL_REGIME_HIGH;
   else if(atrPct < m_profile.volBreakoutThreshold)
      m_currentRegime = VOL_REGIME_BREAKOUT;
   else
      m_currentRegime = VOL_REGIME_EXTREME;
}

//+------------------------------------------------------------------+
//| Get Regime String                                                  |
//+------------------------------------------------------------------+
string CSpreadManager::GetRegimeString(void)
{
   switch(m_currentRegime)
   {
      case VOL_REGIME_LOW:      return "LOW";
      case VOL_REGIME_NORMAL:   return "NORMAL";
      case VOL_REGIME_HIGH:     return "HIGH";
      case VOL_REGIME_BREAKOUT: return "BREAKOUT";
      case VOL_REGIME_EXTREME:  return "EXTREME";
      default:                  return "UNKNOWN";
   }
}

//+------------------------------------------------------------------+
//| Log Spread Status                                                  |
//+------------------------------------------------------------------+
void CSpreadManager::LogSpreadStatus(void)
{
   string msg = FormatSpreadInfo();
   Print(msg);
}

//+------------------------------------------------------------------+
//| Format Spread Info                                                 |
//+------------------------------------------------------------------+
string CSpreadManager::FormatSpreadInfo(void)
{
   string symbolShort = m_symbol;
   if(StringLen(symbolShort) > 6)
      symbolShort = StringSubstr(symbolShort, 0, 6);
   
   return StringFormat(
      "Spread[%s]: %.1fpips (%.0fpts) | Avg:%.1f | Min:%.1f | Max:%.1f | Thresh:%.1f | Regime:%s",
      symbolShort,
      m_stats.currentSpreadPips,
      m_stats.currentSpreadPoints,
      m_stats.averageSpreadPips,
      m_stats.minSpreadPips,
      m_stats.maxSpreadPips,
      GetCurrentThreshold(),
      GetRegimeString()
   );
}

//+------------------------------------------------------------------+
//| Clear Emergency Mode                                               |
//+------------------------------------------------------------------+
void CSpreadManager::ClearEmergencyMode(void)
{
   if(m_emergencyMode)
   {
      Print("SpreadManager: Clearing emergency mode for ", m_symbol);
      m_emergencyMode = false;
      m_emergencyStart = 0;
   }
}

#endif // SPREAD_MANAGER_MQH
