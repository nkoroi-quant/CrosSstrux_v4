//+------------------------------------------------------------------+
//| HashDiggr.mq5 - BTCUSD Expert Advisor v4.1.0                      |
//+------------------------------------------------------------------+
//| Description: Cryptocurrency trading EA with asset-aware spread   |
//|              normalization, adaptive API caching, and synthetic  |
//|              volume handling. Production-ready for BTCUSD CFDs.    |
//+------------------------------------------------------------------+
#property copyright "CrosSstrux v4.1"
#property link      "https://github.com/nkoroi-quant/CrosSstrux_v4"
#property version   "4.1"
#property strict

#include <Trade\Trade.mqh>
#include <JAson.mqh>  // JSON library
#include "Include/AssetProfile.mqh"
#include "Include/SpreadManager.mqh"
#include "Include/ContextRefreshManager.mqh"

//--- Input Parameters
input group "=== API Configuration ==="
input string InpApiUrl = "http://localhost:8000/analyze";
input string InpApiKey = "";
input int    InpApiTimeoutMs = 5000;

input group "=== Risk Management ==="
input double InpRiskPercent = 1.0;           // Risk per trade (%)
input double InpMaxDailyRisk = 3.0;          // Max daily risk (%)
input int    InpMaxPositions = 5;            // Max concurrent positions
input bool   InpUseEquityCurveProtection = true;

input group "=== Entry Parameters ==="
input double InpMinSignalConfidence = 0.65;  // Minimum signal confidence
input bool   InpRequireTrendAlignment = true;
input int    InpMaxPyramidTrades = 5;        // Override profile default

input group "=== Pyramiding ==="
input bool   InpEnablePyramiding = true;
input double InpPyramidDistanceATR = 0.3;    // ATR multiplier
input double InpPyramidLotMultiplier = 0.8;  // Reduce size on adds

input group "=== Logging ==="
input bool   InpVerboseLogging = true;
input int    InpLogFrequency = 10;           // Log every N ticks

//--- Global Objects
CTrade      g_trade;
CAssetProfileRegistry g_profileRegistry;
CSpreadManager g_spreadManager;
CContextRefreshManager g_refreshManager;

//--- Trading State
struct TradingState
{
   string symbol;
   AssetProfile profile;
   
   // API Data Cache
   string lastApiResponse;
   datetime lastContextUpdate;
   datetime lastSignalUpdate;
   
   // Signal Data
   double signalDirection;       // -1, 0, 1
   double signalConfidence;      // 0.0 - 1.0
   double entryPrecision;        // 0.0 - 1.0
   string volatilityRegime;      // LOW, NORMAL, HIGH, BREAKOUT
   double trendAlignment;        // 0.0 - 1.0
   
   // Position Tracking
   int openPositions;
   double totalLots;
   double avgEntryPrice;
   double unrealizedPnL;
   datetime lastTradeTime;
   int pyramidCount;
   
   // Daily Tracking
   double dailyPnL;
   int dailyTrades;
   datetime tradingDay;
   
   void Reset()
   {
      symbol = "";
      lastApiResponse = "";
      lastContextUpdate = 0;
      lastSignalUpdate = 0;
      signalDirection = 0;
      signalConfidence = 0;
      entryPrecision = 0;
      volatilityRegime = "UNKNOWN";
      trendAlignment = 0;
      openPositions = 0;
      totalLots = 0;
      avgEntryPrice = 0;
      unrealizedPnL = 0;
      lastTradeTime = 0;
      pyramidCount = 0;
      dailyPnL = 0;
      dailyTrades = 0;
      tradingDay = 0;
   }
};

TradingState g_state;

//--- Metrics
int g_tickCount = 0;
datetime g_startTime = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("=== HashDiggr v4.1.0 Initializing ===");
   
   // Set symbol
   g_state.symbol = Symbol();
   
   // Initialize profile registry (auto-loads defaults)
   
   // Initialize spread manager
   if(!g_spreadManager.Initialize(g_state.symbol))
   {
      Print("ERROR: Failed to initialize SpreadManager");
      return INIT_FAILED;
   }
   
   // Get asset profile
   if(!g_profileRegistry.GetProfile(g_state.symbol, g_state.profile))
   {
      Print("WARNING: Using default profile for ", g_state.symbol);
   }
   
   // Initialize refresh manager
   if(!g_refreshManager.Initialize(g_state.symbol, &g_spreadManager))
   {
      Print("ERROR: Failed to initialize ContextRefreshManager");
      return INIT_FAILED;
   }
   
   // Setup trading
   g_trade.SetExpertMagicNumber(42001);  // HashDiggr magic
   g_trade.SetDeviationInPoints(50);     // Slippage tolerance
   g_trade.SetTypeFilling(ORDER_FILLING_IOC);
   g_trade.SetAsyncMode(false);
   
   // Log profile details
   g_profileRegistry.LogProfileDetails(g_state.symbol);
   g_spreadManager.LogSpreadStatus();
   
   // Initialize state
   g_startTime = TimeCurrent();
   g_state.tradingDay = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   
   Print("HashDiggr initialized successfully for ", g_state.symbol);
   Print("Asset Class: ", g_profileRegistry.AssetClassToString(g_state.profile.assetClass));
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("=== HashDiggr Shutting Down ===");
   Print("Runtime: ", (TimeCurrent() - g_startTime) / 3600, " hours");
   Print("Total API calls: ", g_refreshManager.GetStatistics().totalRequests);
   Print("API success rate: ", g_refreshManager.GetStatistics().GetSuccessRate(), "%");
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   g_tickCount++;
   
   // Periodic logging
   if(InpVerboseLogging && g_tickCount % InpLogFrequency == 0)
   {
      g_spreadManager.UpdateStatistics();
      g_spreadManager.LogSpreadStatus();
   }
   
   // Update position tracking
   UpdatePositionState();
   
   // Check daily reset
   CheckDailyReset();
   
   // Check equity protection
   if(InpUseEquityCurveProtection && CheckEquityProtection())
   {
      if(g_tickCount % 100 == 0)
         Print("Equity protection active - no new trades");
      return;
   }
   
   // Check spread
   g_spreadManager.UpdateStatistics();
   if(!g_spreadManager.IsSpreadAcceptable())
   {
      if(g_tickCount % 100 == 0)
         Print("Spread filter: ", g_spreadManager.GetRejectionReason());
      return;
   }
   
   // Update adaptive intervals
   g_refreshManager.UpdateAdaptiveIntervals();
   
   // Refresh context if needed
   if(g_refreshManager.ShouldRefreshContext())
   {
      if(g_refreshManager.ShouldCallAPI())
      {
         RefreshContextFromAPI();
      }
   }
   
   // Refresh signal if needed
   if(g_refreshManager.ShouldRefreshSignal())
   {
      if(g_refreshManager.ShouldCallAPI())
      {
         RefreshSignalFromAPI();
      }
   }
   
   // Execute trading logic
   ExecuteTradingLogic();
   
   // Manage open positions
   ManageOpenPositions();
}

//+------------------------------------------------------------------+
//| Refresh Context from API                                           |
//+------------------------------------------------------------------+
void RefreshContextFromAPI()
{
   // Build multi-timeframe request
   string jsonRequest = BuildAnalysisRequest();
   
   string headers;
   StringAdd(headers, "Content-Type: application/json\\r\\n");
   if(StringLen(InpApiKey) > 0)
   {
      StringAdd(headers, "Authorization: Bearer " + InpApiKey + "\\r\\n");
   }
   
   char data[], result[];
   string url = InpApiUrl;
   int res;
   
   StringToCharArray(jsonRequest, data);
   
   datetime callStart = TimeLocal();
   res = WebRequest("POST", url, headers, InpApiTimeoutMs, data, result, headers);
   double responseTime = (double)(TimeLocal() - callStart);
   
   if(res != 200)
   {
      Print("API Error: HTTP ", res);
      g_refreshManager.RecordApiFailure("HTTP " + IntegerToString(res));
      return;
   }
   
   string response = CharArrayToString(result);
   g_state.lastApiResponse = response;
   
   // Parse response
   CJAVal json;
   if(!json.Deserialize(response))
   {
      Print("JSON Parse Error");
      g_refreshManager.RecordApiFailure("JSON parse error");
      return;
   }
   
   // Extract context data
   g_state.volatilityRegime = json["regime"].ToStr();
   g_state.trendAlignment = json["trend_alignment"].ToDbl();
   
   g_refreshManager.RecordApiSuccess(responseTime);
   g_state.lastContextUpdate = TimeCurrent();
   
   if(InpVerboseLogging)
   {
      Print("Context updated: Regime=", g_state.volatilityRegime, 
            " TrendAlign=", DoubleToString(g_state.trendAlignment, 2));
   }
}

//+------------------------------------------------------------------+
//| Refresh Signal from API                                            |
//+------------------------------------------------------------------+
void RefreshSignalFromAPI()
{
   // Use cached context if available
   if(StringLen(g_state.lastApiResponse) == 0)
   {
      RefreshContextFromAPI();
      return;
   }
   
   // Parse cached response for signal
   CJAVal json;
   if(!json.Deserialize(g_state.lastApiResponse))
   {
      RefreshContextFromAPI();
      return;
   }
   
   // Extract signal
   string signal = json["signal"].ToStr();
   g_state.signalConfidence = json["confidence"].ToDbl();
   g_state.entryPrecision = json["entry_precision"].ToDbl();
   
   if(signal == "BUY")
      g_state.signalDirection = 1;
   else if(signal == "SELL")
      g_state.signalDirection = -1;
   else
      g_state.signalDirection = 0;
   
   g_state.lastSignalUpdate = TimeCurrent();
   
   if(InpVerboseLogging)
   {
      Print("Signal: ", signal, " Conf=", DoubleToString(g_state.signalConfidence, 2),
            " Prec=", DoubleToString(g_state.entryPrecision, 2));
   }
}

//+------------------------------------------------------------------+
//| Build Analysis Request                                             |
//+------------------------------------------------------------------+
string BuildAnalysisRequest(void)
{
   // Gather multi-timeframe data
   MqlRates ratesM1[], ratesM5[], ratesM15[], ratesH1[], ratesD1[];
   ArraySetAsSeries(ratesM1, true);
   ArraySetAsSeries(ratesM5, true);
   ArraySetAsSeries(ratesM15, true);
   ArraySetAsSeries(ratesH1, true);
   ArraySetAsSeries(ratesD1, true);

   CopyRates(g_state.symbol, PERIOD_M1, 0, 100, ratesM1);
   CopyRates(g_state.symbol, PERIOD_M5, 0, 100, ratesM5);
   CopyRates(g_state.symbol, PERIOD_M15, 0, 50, ratesM15);
   CopyRates(g_state.symbol, PERIOD_H1, 0, 50, ratesH1);
   CopyRates(g_state.symbol, PERIOD_D1, 0, 20, ratesD1);

   // Build JSON with proper escaping
   string json = "{";
   json += "\"symbol\": \"" + g_state.symbol + "\",";
   json += "\"asset_class\": \"cryptocurrency\",";
   json += "\"timeframes\": {";

   // Add M1 data
   json += "\"M1\": {";
   json += "\"open\": " + DoubleToString(ratesM1[0].open, g_state.profile.digits) + ",";
   json += "\"high\": " + DoubleToString(ratesM1[0].high, g_state.profile.digits) + ",";
   json += "\"low\": " + DoubleToString(ratesM1[0].low, g_state.profile.digits) + ",";
   json += "\"close\": " + DoubleToString(ratesM1[0].close, g_state.profile.digits) + ",";
   json += "\"tick_volume\": " + IntegerToString(ratesM1[0].tick_volume) + ",";
   json += "\"real_volume\": " + IntegerToString(ratesM1[0].real_volume);
   json += "},";

   // Add M5 data
   json += "\"M5\": {";
   json += "\"close\": " + DoubleToString(ratesM5[0].close, g_state.profile.digits) + ",";
   json += "\"atr\": " + DoubleToString(CalculateATR(PERIOD_M5, 14), g_state.profile.digits);
   json += "},";

   // Add M15 data
   json += "\"M15\": {";
   json += "\"close\": " + DoubleToString(ratesM15[0].close, g_state.profile.digits) + ",";
   json += "\"ema20\": " + DoubleToString(CalculateEMA(PERIOD_M15, 20), g_state.profile.digits);
   json += "},";

   // Add H1 data
   json += "\"H1\": {";
   json += "\"close\": " + DoubleToString(ratesH1[0].close, g_state.profile.digits) + ",";
   json += "\"ema50\": " + DoubleToString(CalculateEMA(PERIOD_H1, 50), g_state.profile.digits);
   json += "},";

   // Add D1 data
   json += "\"D1\": {";
   json += "\"close\": " + DoubleToString(ratesD1[0].close, g_state.profile.digits) + ",";
   json += "\"atr\": " + DoubleToString(CalculateATR(PERIOD_D1, 14), g_state.profile.digits);
   json += "}";

   json += "},"; // close timeframes
   json += "\"account\": {";
   json += "\"balance\": " + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2) + ",";
   json += "\"equity\": " + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2);
   json += "},";

   json += "\"spread_pips\": " + DoubleToString(g_spreadManager.GetSpreadPips(), 1);
   json += "}";

   return json;
}


//+------------------------------------------------------------------+
//| Execute Trading Logic                                              |
//+------------------------------------------------------------------+
void ExecuteTradingLogic(void)
{
   // Check minimum conditions
   if(g_state.signalConfidence < InpMinSignalConfidence)
      return;
   
   if(g_state.entryPrecision < g_state.profile.entryPrecisionThreshold)
      return;
   
   if(InpRequireTrendAlignment && g_state.trendAlignment < 0.6)
      return;
   
   // Check position limits
   if(g_state.openPositions >= InpMaxPositions)
      return;
   
   // Check daily trade limit
   if(g_state.dailyTrades >= 20)  // Max 20 trades per day
      return;
   
   // Check pyramid limits
   if(g_state.openPositions > 0 && g_state.pyramidCount >= g_state.profile.pyramidMaxTrades)
      return;
   
   // Execute based on signal
   if(g_state.signalDirection == 1 && CanOpenLong())
   {
      OpenPosition(ORDER_TYPE_BUY);
   }
   else if(g_state.signalDirection == -1 && CanOpenShort())
   {
      OpenPosition(ORDER_TYPE_SELL);
   }
}

//+------------------------------------------------------------------+
//| Open Position                                                      |
//+------------------------------------------------------------------+
void OpenPosition(ENUM_ORDER_TYPE orderType)
{
   // Calculate lot size
   double lots = CalculateLotSize();
   if(lots <= 0)
   {
      Print("Invalid lot size calculated");
      return;
   }
   
   // Calculate SL/TP
   double atr = CalculateATR(PERIOD_M5, 14);
   double slDistance = atr * g_state.profile.slMultiplier;
   double tpDistance = atr * g_state.profile.tpMultiplier;
   
   MqlTick tick;
   if(!SymbolInfoTick(g_state.symbol, tick))
   {
      Print("Failed to get tick data");
      return;
   }
   
   double price = (orderType == ORDER_TYPE_BUY) ? tick.ask : tick.bid;
   double sl = (orderType == ORDER_TYPE_BUY) ? price - slDistance : price + slDistance;
   double tp = (orderType == ORDER_TYPE_BUY) ? price + tpDistance : price - tpDistance;
   
   // Normalize prices
   double tickSize = SymbolInfoDouble(g_state.symbol, SYMBOL_TRADE_TICK_SIZE);
   sl = NormalizeDouble(MathRound(sl / tickSize) * tickSize, g_state.profile.digits);
   tp = NormalizeDouble(MathRound(tp / tickSize) * tickSize, g_state.profile.digits);
   
   // Execute
   bool success = false;
   if(orderType == ORDER_TYPE_BUY)
      success = g_trade.Buy(lots, g_state.symbol, price, sl, tp);
   else
      success = g_trade.Sell(lots, g_state.symbol, price, sl, tp);
   
   if(success)
   {
      g_state.lastTradeTime = TimeCurrent();
      g_state.dailyTrades++;
      g_state.pyramidCount++;
      
      string dir = (orderType == ORDER_TYPE_BUY) ? "BUY" : "SELL";
      Print("Opened ", dir, " | Lots: ", DoubleToString(lots, 2), 
            " | SL: ", DoubleToString(sl, g_state.profile.digits),
            " | TP: ", DoubleToString(tp, g_state.profile.digits));
      
      SendNotification(StringFormat("HashDiggr %s: %s %s lots @ %s", 
         g_state.symbol, dir, DoubleToString(lots, 2), DoubleToString(price, g_state.profile.digits)));
   }
   else
   {
      Print("Trade failed: ", GetLastError());
   }
}

//+------------------------------------------------------------------+
//| Calculate Lot Size                                                 |
//+------------------------------------------------------------------+
double CalculateLotSize(void)
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * InpRiskPercent / 100.0;
   
   // Adjust for pyramiding
   if(g_state.openPositions > 0)
   {
      riskAmount *= InpPyramidLotMultiplier;
   }
   
   // Calculate based on ATR
   double atr = CalculateATR(PERIOD_M5, 14);
   double slDistance = atr * g_state.profile.slMultiplier;
   
   if(slDistance <= 0)
      return 0;
   
   double tickValue = SymbolInfoDouble(g_state.symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(g_state.symbol, SYMBOL_TRADE_TICK_SIZE);
   
   if(tickValue <= 0 || tickSize <= 0)
      return 0;
   
   double lots = riskAmount / (slDistance * tickValue / tickSize);
   
   // Normalize to lot step
   double lotStep = SymbolInfoDouble(g_state.symbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(g_state.symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(g_state.symbol, SYMBOL_VOLUME_MAX);
   
   lots = MathFloor(lots / lotStep) * lotStep;
   lots = MathMax(minLot, MathMin(maxLot, lots));
   
   return lots;
}

//+------------------------------------------------------------------+
//| Manage Open Positions                                              |
//+------------------------------------------------------------------+
void ManageOpenPositions(void)
{
   // Trailing stop logic
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) != g_state.symbol)
         continue;
      
      if(PositionGetInteger(POSITION_MAGIC) != 42001)
         continue;
      
      long posType = PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      
      MqlTick tick;
      SymbolInfoTick(g_state.symbol, tick);
      
      double atr = CalculateATR(PERIOD_M5, 14);
      double trailDistance = atr * 1.5;  // Trail at 1.5x ATR
      
      double newSL = currentSL;
      
      if(posType == POSITION_TYPE_BUY)
      {
         double potentialSL = tick.bid - trailDistance;
         if(potentialSL > openPrice && potentialSL > currentSL)
         {
            newSL = potentialSL;
         }
      }
      else
      {
         double potentialSL = tick.ask + trailDistance;
         if(potentialSL < openPrice && potentialSL < currentSL)
         {
            newSL = potentialSL;
         }
      }
      
      if(newSL != currentSL)
      {
         double tickSize = SymbolInfoDouble(g_state.symbol, SYMBOL_TRADE_TICK_SIZE);
         newSL = NormalizeDouble(MathRound(newSL / tickSize) * tickSize, g_state.profile.digits);
         
         g_trade.PositionModify(PositionGetInteger(POSITION_TICKET), newSL, currentTP);
      }
   }
}

//+------------------------------------------------------------------+
//| Update Position State                                              |
//+------------------------------------------------------------------+
void UpdatePositionState(void)
{
   g_state.openPositions = 0;
   g_state.totalLots = 0;
   g_state.unrealizedPnL = 0;
   
   double totalWeightedPrice = 0;
   
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(PositionGetSymbol(i) != g_state.symbol)
         continue;
      
      if(PositionGetInteger(POSITION_MAGIC) != 42001)
         continue;
      
      g_state.openPositions++;
      double lots = PositionGetDouble(POSITION_VOLUME);
      double price = PositionGetDouble(POSITION_PRICE_OPEN);
      g_state.totalLots += lots;
      totalWeightedPrice += price * lots;
      g_state.unrealizedPnL += PositionGetDouble(POSITION_PROFIT);
   }
   
   if(g_state.totalLots > 0)
   {
      g_state.avgEntryPrice = totalWeightedPrice / g_state.totalLots;
   }
   else
   {
      g_state.avgEntryPrice = 0;
      g_state.pyramidCount = 0;
   }
}

//+------------------------------------------------------------------+
//| Check Daily Reset                                                  |
//+------------------------------------------------------------------+
void CheckDailyReset(void)
{
   datetime currentDay = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   
   if(currentDay != g_state.tradingDay)
   {
      Print("=== New Trading Day ===");
      Print("Previous day PnL: ", DoubleToString(g_state.dailyPnL, 2));
      Print("Previous day trades: ", g_state.dailyTrades);
      
      g_state.dailyPnL = 0;
      g_state.dailyTrades = 0;
      g_state.tradingDay = currentDay;
   }
}

//+------------------------------------------------------------------+
//| Check Equity Protection                                            |
//+------------------------------------------------------------------+
bool CheckEquityProtection(void)
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double dailyRisk = InpMaxDailyRisk / 100.0;
   
   // Check daily drawdown
   if(equity < balance * (1 - dailyRisk))
   {
      return true;  // Protection triggered
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Can Open Long                                                      |
//+------------------------------------------------------------------+
bool CanOpenLong(void)
{
   // Check for existing shorts
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(PositionGetSymbol(i) != g_state.symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != 42001) continue;
      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL)
         return false;  // No hedging
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| Can Open Short                                                     |
//+------------------------------------------------------------------+
bool CanOpenShort(void)
{
   // Check for existing longs
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(PositionGetSymbol(i) != g_state.symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != 42001) continue;
      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
         return false;  // No hedging
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| Calculate ATR                                                      |
//+------------------------------------------------------------------+
double CalculateATR(ENUM_TIMEFRAMES tf, int period)
{
   int handle = iATR(g_state.symbol, tf, period);
   if(handle == INVALID_HANDLE)
      return 0;
   
   double atr[];
   ArraySetAsSeries(atr, true);
   
   if(CopyBuffer(handle, 0, 0, 1, atr) < 1)
   {
      IndicatorRelease(handle);
      return 0;
   }
   
   IndicatorRelease(handle);
   return atr[0];
}

//+------------------------------------------------------------------+
//| Calculate EMA                                                      |
//+------------------------------------------------------------------+
double CalculateEMA(ENUM_TIMEFRAMES tf, int period)
{
   int handle = iMA(g_state.symbol, tf, period, 0, MODE_EMA, PRICE_CLOSE);
   if(handle == INVALID_HANDLE)
      return 0;
   
   double ema[];
   ArraySetAsSeries(ema, true);
   
   if(CopyBuffer(handle, 0, 0, 1, ema) < 1)
   {
      IndicatorRelease(handle);
      return 0;
   }
   
   IndicatorRelease(handle);
   return ema[0];
}
