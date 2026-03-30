//+------------------------------------------------------------------+
//| AssetProfile.mqh - Asset-Aware Configuration System v4.1.0      |
//+------------------------------------------------------------------+
//| Description: Centralized asset profile management for multi-    |
//|              asset trading systems. Handles point multipliers,   |
//|              spread thresholds, and asset-specific parameters.   |
//+------------------------------------------------------------------+
#ifndef ASSET_PROFILE_MQH
#define ASSET_PROFILE_MQH

#include <Object.mqh>

//+------------------------------------------------------------------+
//| Asset Class Enumeration                                          |
//+------------------------------------------------------------------+
enum ENUM_ASSET_CLASS
{
   ASSET_CLASS_FOREX,      // Standard forex pairs (EURUSD, GBPUSD)
   ASSET_CLASS_GOLD,       // Gold/XAUUSD (1 pip = 10 points = $0.01)
   ASSET_CLASS_SILVER,     // Silver/XAGUSD
   ASSET_CLASS_CRYPTO,     // Cryptocurrency (BTCUSD, ETHUSD - 1 pip = 100 points)
   ASSET_CLASS_INDICES,    // Stock indices (US30, NAS100)
   ASSET_CLASS_ENERGIES    // Oil, Gas (XTIUSD, XNGUSD)
};

//+------------------------------------------------------------------+
//| Volatility Regime Enumeration                                    |
//+------------------------------------------------------------------+
enum ENUM_VOLATILITY_REGIME
{
   VOL_REGIME_LOW,
   VOL_REGIME_NORMAL,
   VOL_REGIME_HIGH,
   VOL_REGIME_BREAKOUT,
   VOL_REGIME_EXTREME
};

//+------------------------------------------------------------------+
//| Asset Profile Structure                                          |
//+------------------------------------------------------------------+
struct AssetProfile
{
   // Identification
   string symbol;
   ENUM_ASSET_CLASS assetClass;
   
   // Point & Spread Configuration (CRITICAL FIX)
   int pointMultiplier;              // 10 for FX/Gold, 100 for Crypto
   double spreadThresholdPips;       // Normalized pip threshold
   double spreadEmergencyPips;       // Emergency cutoff (3x threshold)
   int digits;                       // Price digits
   
   // Volatility Thresholds (% of price)
   double volLowThreshold;           // Below = low vol
   double volNormalThreshold;        // Normal volatility
   double volHighThreshold;          // High volatility
   double volBreakoutThreshold;      // Breakout detection
   
   // Pyramiding Parameters
   int pyramidMaxTrades;             // Maximum pyramid positions
   double pyramidDistanceATR;        // ATR multiplier for adding
   double pyramidLotMultiplier;      // Lot size scaling
   bool pyramidRequireProfit;        // Only add to winners
   
   // Market Hours
   bool is24HourMarket;              // True for crypto
   int highVolumeHours[];            // Hours with highest liquidity
   int lowVolumeHours[];             // Hours with lowest liquidity
   
   // Session Quality
   double entryPrecisionThreshold;   // Minimum score to enter
   int momentumLookback;             // Bars for momentum calc
   double minImpulseRatio;           // Minimum impulse strength
   
   // API & Caching
   int contextCacheSeconds;          // Context refresh interval
   int signalCacheSeconds;           // Signal refresh interval
   int maxCacheAgeFallback;          // Extended cache in fallback mode
   
   // Volume Reliability
   bool volumeReliable;              // True if real volume available
   string volumeMethod;              // "tick", "real", "synthetic"
   
   // Risk Parameters
   double maxSpreadPctOfATR;         // Spread as % of ATR limit
   double slMultiplier;              // ATR multiplier for SL
   double tpMultiplier;              // ATR multiplier for TP
   double maxDailyVolatility;        // Pause trading above this
   
   // Constructor with defaults
   AssetProfile()
   {
      // Initialize arrays
      ArrayResize(highVolumeHours, 0);
      ArrayResize(lowVolumeHours, 0);
      
      // Defaults (Forex)
      assetClass = ASSET_CLASS_FOREX;
      pointMultiplier = 10;
      spreadThresholdPips = 2.0;
      spreadEmergencyPips = 6.0;
      digits = 5;
      
      volLowThreshold = 0.1;
      volNormalThreshold = 0.3;
      volHighThreshold = 0.6;
      volBreakoutThreshold = 1.0;
      
      pyramidMaxTrades = 3;
      pyramidDistanceATR = 0.5;
      pyramidLotMultiplier = 1.0;
      pyramidRequireProfit = true;
      
      is24HourMarket = false;
      entryPrecisionThreshold = 0.65;
      momentumLookback = 10;
      minImpulseRatio = 1.2;
      
      contextCacheSeconds = 60;
      signalCacheSeconds = 30;
      maxCacheAgeFallback = 300;
      
      volumeReliable = true;
      volumeMethod = "tick";
      
      maxSpreadPctOfATR = 10.0;
      slMultiplier = 1.2;
      tpMultiplier = 2.0;
      maxDailyVolatility = 2.0;
   }
};

//+------------------------------------------------------------------+
//| Asset Profile Registry Class                                     |
//+------------------------------------------------------------------+
class CAssetProfileRegistry : public CObject
{
private:
   AssetProfile m_profiles[];
   string m_profileNames[];
   int m_profileCount;
   
public:
   CAssetProfileRegistry(void);
   ~CAssetProfileRegistry(void);
   
   // Registration methods
   void InitializeDefaultProfiles(void);
   bool RegisterProfile(const string symbol, const AssetProfile &profile);
   bool GetProfile(const string symbol, AssetProfile &outProfile);
   bool ProfileExists(const string symbol);
   
   // Helper methods
   int GetPointMultiplier(const string symbol);
   double GetSpreadThreshold(const string symbol);
   ENUM_ASSET_CLASS GetAssetClass(const string symbol);
   
   // Display/debug
   void LogProfileDetails(const string symbol);
   string AssetClassToString(ENUM_ASSET_CLASS cls);
};

//+------------------------------------------------------------------+
//| Constructor                                                        |
//+------------------------------------------------------------------+
CAssetProfileRegistry::CAssetProfileRegistry(void)
{
   m_profileCount = 0;
   ArrayResize(m_profiles, 0);
   ArrayResize(m_profileNames, 0);
   InitializeDefaultProfiles();
}

//+------------------------------------------------------------------+
//| Destructor                                                         |
//+------------------------------------------------------------------+
CAssetProfileRegistry::~CAssetProfileRegistry(void)
{
   ArrayResize(m_profiles, 0);
   ArrayResize(m_profileNames, 0);
}

//+------------------------------------------------------------------+
//| Initialize Default Profiles                                        |
//+------------------------------------------------------------------+
void CAssetProfileRegistry::InitializeDefaultProfiles(void)
{
   //--- XAUUSD (Gold) Profile
   AssetProfile gold;
   gold.symbol = "XAUUSD";
   gold.assetClass = ASSET_CLASS_GOLD;
   gold.pointMultiplier = 10;                    // 1 pip = 10 points = $0.01
   gold.spreadThresholdPips = 5.0;               // 5 pips = $5 (acceptable)
   gold.spreadEmergencyPips = 15.0;              // Emergency cutoff
   gold.digits = 2;
   
   gold.volLowThreshold = 0.3;                   // 0.3% daily = low
   gold.volNormalThreshold = 0.5;                // 0.5% daily = normal
   gold.volHighThreshold = 0.8;                  // 0.8% daily = high
   gold.volBreakoutThreshold = 1.5;              // 1.5%+ = breakout
   
   gold.pyramidMaxTrades = 3;
   gold.pyramidDistanceATR = 0.5;
   gold.pyramidLotMultiplier = 1.0;
   gold.pyramidRequireProfit = true;
   
   gold.is24HourMarket = false;
   gold.entryPrecisionThreshold = 0.65;
   gold.momentumLookback = 10;
   gold.minImpulseRatio = 1.2;
   
   gold.contextCacheSeconds = 120;               // 2 minutes for context
   gold.signalCacheSeconds = 60;                 // 1 minute for signals
   gold.maxCacheAgeFallback = 600;               // 10 min fallback
   
   gold.volumeReliable = true;
   gold.volumeMethod = "tick";
   
   gold.maxSpreadPctOfATR = 10.0;
   gold.slMultiplier = 1.5;
   gold.tpMultiplier = 2.5;
   gold.maxDailyVolatility = 2.0;
   
   // Gold market hours (UTC) - London/NY overlap best
   ArrayResize(gold.highVolumeHours, 8);
   gold.highVolumeHours[0] = 8;   // London open
   gold.highVolumeHours[1] = 9;
   gold.highVolumeHours[2] = 10;
   gold.highVolumeHours[3] = 11;
   gold.highVolumeHours[4] = 12;
   gold.highVolumeHours[5] = 13;  // NY open
   gold.highVolumeHours[6] = 14;
   gold.highVolumeHours[7] = 15;  // London/NY overlap
   
   ArrayResize(gold.lowVolumeHours, 5);
   gold.lowVolumeHours[0] = 22;
   gold.lowVolumeHours[1] = 23;
   gold.lowVolumeHours[2] = 0;
   gold.lowVolumeHours[3] = 1;
   gold.lowVolumeHours[4] = 2;
   
   RegisterProfile("XAUUSD", gold);
   RegisterProfile("GOLD", gold);  // Alias
   
   //--- BTCUSD (Bitcoin) Profile
   AssetProfile btc;
   btc.symbol = "BTCUSD";
   btc.assetClass = ASSET_CLASS_CRYPTO;
   btc.pointMultiplier = 100;                    // CRITICAL: 1 pip = 100 points = $1.00
   btc.spreadThresholdPips = 50.0;               // 50 pips = ~$50 (NORMAL for BTC!)
   btc.spreadEmergencyPips = 150.0;              // Emergency: $150 spread
   btc.digits = 2;
   
   btc.volLowThreshold = 1.0;                    // 1% daily = low for BTC
   btc.volNormalThreshold = 2.5;                 // 2.5% daily = normal
   btc.volHighThreshold = 5.0;                   // 5% daily = high
   btc.volBreakoutThreshold = 8.0;               // 8%+ = breakout
   
   btc.pyramidMaxTrades = 5;                     // More pyramiding for crypto
   btc.pyramidDistanceATR = 0.3;                 // Tighter spacing
   btc.pyramidLotMultiplier = 0.8;               // Reduce size on adds
   btc.pyramidRequireProfit = true;
   
   btc.is24HourMarket = true;                    // 24/7 trading
   btc.entryPrecisionThreshold = 0.70;           // Higher threshold (more noise)
   btc.momentumLookback = 6;                     // Faster momentum
   btc.minImpulseRatio = 1.5;
   
   btc.contextCacheSeconds = 30;                 // Faster updates (30s)
   btc.signalCacheSeconds = 15;                  // Very fast signals (15s)
   btc.maxCacheAgeFallback = 150;                // 2.5 min fallback
   
   btc.volumeReliable = false;                   // Synthetic volume only
   btc.volumeMethod = "synthetic";
   
   btc.maxSpreadPctOfATR = 15.0;                 // Allow wider spread %
   btc.slMultiplier = 2.0;                       // Wider stops
   btc.tpMultiplier = 3.0;                       // Larger targets
   btc.maxDailyVolatility = 15.0;                // Pause above 15%
   
   // Crypto high volume: Asia open (0-4 UTC) and US/EU overlap (13-17 UTC)
   ArrayResize(btc.highVolumeHours, 9);
   btc.highVolumeHours[0] = 0;
   btc.highVolumeHours[1] = 1;
   btc.highVolumeHours[2] = 2;
   btc.highVolumeHours[3] = 3;
   btc.highVolumeHours[4] = 13;
   btc.highVolumeHours[5] = 14;
   btc.highVolumeHours[6] = 15;
   btc.highVolumeHours[7] = 16;
   btc.highVolumeHours[8] = 17;
   
   ArrayResize(btc.lowVolumeHours, 3);
   btc.lowVolumeHours[0] = 21;
   btc.lowVolumeHours[1] = 22;
   btc.lowVolumeHours[2] = 23;
   
   RegisterProfile("BTCUSD", btc);
   RegisterProfile("BTCUSDT", btc);  // Alternative naming
   
   //--- ETHUSD (Ethereum) Profile
   AssetProfile eth;
   eth = btc;  // Copy BTC base
   eth.symbol = "ETHUSD";
   eth.spreadThresholdPips = 6.0;                // Tighter than BTC
   eth.spreadEmergencyPips = 20.0;
   eth.volLowThreshold = 1.5;
   eth.volNormalThreshold = 3.0;
   eth.volHighThreshold = 6.0;
   eth.volBreakoutThreshold = 10.0;
   eth.pyramidMaxTrades = 4;
   eth.maxDailyVolatility = 12.0;
   
   RegisterProfile("ETHUSD", eth);
   RegisterProfile("ETHUSDT", eth);
   
   //--- EURUSD Profile (Forex baseline)
   AssetProfile eurusd;
   eurusd.symbol = "EURUSD";
   eurusd.assetClass = ASSET_CLASS_FOREX;
   eurusd.pointMultiplier = 10;                  // 1 pip = 10 points
   eurusd.spreadThresholdPips = 2.0;
   eurusd.spreadEmergencyPips = 5.0;
   eurusd.digits = 5;
   
   eurusd.volLowThreshold = 0.05;
   eurusd.volNormalThreshold = 0.15;
   eurusd.volHighThreshold = 0.30;
   eurusd.volBreakoutThreshold = 0.50;
   
   eurusd.contextCacheSeconds = 60;
   eurusd.signalCacheSeconds = 30;
   
   ArrayResize(eurusd.highVolumeHours, 8);
   eurusd.highVolumeHours[0] = 8;
   eurusd.highVolumeHours[1] = 9;
   eurusd.highVolumeHours[2] = 10;
   eurusd.highVolumeHours[3] = 11;
   eurusd.highVolumeHours[4] = 12;
   eurusd.highVolumeHours[5] = 13;
   eurusd.highVolumeHours[6] = 14;
   eurusd.highVolumeHours[7] = 15;
   
   RegisterProfile("EURUSD", eurusd);
   
   Print("AssetProfileRegistry: Initialized ", m_profileCount, " default profiles");
}

//+------------------------------------------------------------------+
//| Register Profile                                                   |
//+------------------------------------------------------------------+
bool CAssetProfileRegistry::RegisterProfile(const string symbol, const AssetProfile &profile)
{
   int idx = m_profileCount;
   m_profileCount++;
   
   ArrayResize(m_profiles, m_profileCount);
   ArrayResize(m_profileNames, m_profileCount);
   
   m_profiles[idx] = profile;
   m_profileNames[idx] = symbol;
   
   return true;
}

//+------------------------------------------------------------------+
//| Get Profile                                                        |
//+------------------------------------------------------------------+
bool CAssetProfileRegistry::GetProfile(const string symbol, AssetProfile &outProfile)
{
   // Direct match
   for(int i = 0; i < m_profileCount; i++)
   {
      if(m_profileNames[i] == symbol)
      {
         outProfile = m_profiles[i];
         return true;
      }
   }
   
   // Try without suffix (e.g., XAUUSD.r -> XAUUSD)
   string base = symbol;
   int pos = StringFind(symbol, ".");
   if(pos != -1)
   {
      base = StringSubstr(symbol, 0, pos);
      for(int i = 0; i < m_profileCount; i++)
      {
         if(m_profileNames[i] == base)
         {
            outProfile = m_profiles[i];
            return true;
         }
      }
   }
   
   // Try with common suffixes
   string variants[];
   ArrayResize(variants, 4);
   variants[0] = symbol + ".r";      // RAW
   variants[1] = symbol + ".ecn";    // ECN
   variants[2] = symbol + ".pro";    // PRO
   variants[3] = symbol + ".std";    // Standard
   
   for(int v = 0; v < ArraySize(variants); v++)
   {
      for(int i = 0; i < m_profileCount; i++)
      {
         if(m_profileNames[i] == variants[v])
         {
            outProfile = m_profiles[i];
            return true;
         }
      }
   }
   
   // Return default if not found
   Print("AssetProfileRegistry: No profile found for ", symbol, ", using FOREX defaults");
   outProfile = AssetProfile();  // Default constructor (Forex)
   outProfile.symbol = symbol;
   return false;
}

//+------------------------------------------------------------------+
//| Profile Exists                                                     |
//+------------------------------------------------------------------+
bool CAssetProfileRegistry::ProfileExists(const string symbol)
{
   for(int i = 0; i < m_profileCount; i++)
   {
      if(m_profileNames[i] == symbol)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Get Point Multiplier                                               |
//+------------------------------------------------------------------+
int CAssetProfileRegistry::GetPointMultiplier(const string symbol)
{
   AssetProfile prof;
   if(GetProfile(symbol, prof))
      return prof.pointMultiplier;
   return 10;  // Default to Forex
}

//+------------------------------------------------------------------+
//| Get Spread Threshold                                               |
//+------------------------------------------------------------------+
double CAssetProfileRegistry::GetSpreadThreshold(const string symbol)
{
   AssetProfile prof;
   if(GetProfile(symbol, prof))
      return prof.spreadThresholdPips;
   return 2.0;  // Default
}

//+------------------------------------------------------------------+
//| Get Asset Class                                                    |
//+------------------------------------------------------------------+
ENUM_ASSET_CLASS CAssetProfileRegistry::GetAssetClass(const string symbol)
{
   AssetProfile prof;
   if(GetProfile(symbol, prof))
      return prof.assetClass;
   return ASSET_CLASS_FOREX;
}

//+------------------------------------------------------------------+
//| Asset Class to String                                              |
//+------------------------------------------------------------------+
string CAssetProfileRegistry::AssetClassToString(ENUM_ASSET_CLASS cls)
{
   switch(cls)
   {
      case ASSET_CLASS_FOREX:    return "FOREX";
      case ASSET_CLASS_GOLD:     return "GOLD";
      case ASSET_CLASS_SILVER:   return "SILVER";
      case ASSET_CLASS_CRYPTO:   return "CRYPTO";
      case ASSET_CLASS_INDICES:  return "INDICES";
      case ASSET_CLASS_ENERGIES: return "ENERGIES";
      default:                   return "UNKNOWN";
   }
}

//+------------------------------------------------------------------+
//| Log Profile Details                                                |
//+------------------------------------------------------------------+
void CAssetProfileRegistry::LogProfileDetails(const string symbol)
{
   AssetProfile prof;
   if(!GetProfile(symbol, prof))
   {
      Print("AssetProfile: No profile for ", symbol);
      return;
   }
   
   Print("=== Asset Profile: ", symbol, " ===");
   Print("  Class: ", AssetClassToString(prof.assetClass));
   Print("  Point Multiplier: ", prof.pointMultiplier);
   Print("  Spread Threshold: ", prof.spreadThresholdPips, " pips");
   Print("  Emergency Spread: ", prof.spreadEmergencyPips, " pips");
   Print("  24h Market: ", prof.is24HourMarket ? "YES" : "NO");
   Print("  Volume Method: ", prof.volumeMethod);
   Print("  Context TTL: ", prof.contextCacheSeconds, "s");
   Print("  Signal TTL: ", prof.signalCacheSeconds, "s");
}

//+------------------------------------------------------------------+
//| Global Registry Instance                                           |
//+------------------------------------------------------------------+
CAssetProfileRegistry AssetProfileRegistry;

#endif // ASSET_PROFILE_MQH
