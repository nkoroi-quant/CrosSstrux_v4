//+------------------------------------------------------------------+
//| GoldDiggr_v4_2_RollingWindow.mq5 - Sends 30-candle windows       |
//+------------------------------------------------------------------+
#property copyright "CrosSstrux v4.2"
#property link      "https://github.com/nkoroi-quant/CrosSstrux_v4"
#property version   "4.2"
#property strict

#include <Trade/Trade.mqh>
#include <JAson.mqh>
#include "Include/AssetProfile.mqh"
#include "Include/SpreadManager.mqh"
#include "Include/ContextRefreshManager.mqh"

//--- Input Parameters
input group "=== API Configuration ==="
input string InpApiUrl = "http://127.0.0.1:8000/analyze";
input string InpApiKey = "";
input int    InpApiTimeoutMs = 5000;

input group "=== Risk Management ==="
input double InpRiskPercent = 1.0;
input double InpMaxDailyRisk = 3.0;
input int    InpMaxPositions = 3;
input bool   InpUseEquityCurveProtection = true;

input group "=== Entry Parameters ==="
input double InpMinSignalConfidence = 0.65;
input bool   InpRequireTrendAlignment = true;
input int    InpMaxPyramidTrades = 3;

input group "=== Window Settings ==="
input int    InpContextWindowSize = 30;  // H1 and M15 candles
input int    InpExecutionWindowSize = 30; // M5 and M1 candles

//--- Global Objects
CTrade      g_trade;
CAssetProfileRegistry g_profileRegistry;
CSpreadManager g_spreadManager;
CContextRefreshManager g_refreshManager;

struct TradingState
{
   string symbol;
   AssetProfile profile;
   string lastApiResponse;
   datetime lastContextUpdate;
   datetime lastSignalUpdate;
   double signalDirection;
   double signalConfidence;
   double entryPrecision;
   string volatilityRegime;
   double trendAlignment;
   int openPositions;
   double totalLots;
   double avgEntryPrice;
   double unrealizedPnL;
   datetime lastTradeTime;
   int pyramidCount;
   double dailyPnL;
   int dailyTrades;
   datetime tradingDay;
   
   void Reset()
   {
      symbol = ""; lastApiResponse = ""; lastContextUpdate = 0; lastSignalUpdate = 0;
      signalDirection = 0; signalConfidence = 0; entryPrecision = 0;
      volatilityRegime = "UNKNOWN"; trendAlignment = 0; openPositions = 0;
      totalLots = 0; avgEntryPrice = 0; unrealizedPnL = 0; lastTradeTime = 0;
      pyramidCount = 0; dailyPnL = 0; dailyTrades = 0; tradingDay = 0;
   }
};

TradingState g_state;
int g_tickCount = 0;
datetime g_startTime = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   Print("=== GoldDiggr v4.2.0 (Rolling Window) Initializing ===");
   g_state.symbol = Symbol();
   
   if(!g_spreadManager.Initialize(g_state.symbol))
      return INIT_FAILED;
   
   if(!g_profileRegistry.GetProfile(g_state.symbol, g_state.profile))
      Print("WARNING: Using default profile for ", g_state.symbol);
   
   if(!g_refreshManager.Initialize(g_state.symbol, &g_spreadManager))
      return INIT_FAILED;
   
   g_trade.SetExpertMagicNumber(42002);
   g_trade.SetDeviationInPoints(10);
   g_trade.SetTypeFilling(ORDER_FILLING_IOC);
   g_trade.SetAsyncMode(false);
   
   g_profileRegistry.LogProfileDetails(g_state.symbol);
   g_spreadManager.LogSpreadStatus();
   
   g_startTime = TimeCurrent();
   g_state.tradingDay = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   
   Print("GoldDiggr initialized. Context: ", InpContextWindowSize, " candles | Execution: ", InpExecutionWindowSize, " candles");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("=== GoldDiggr Shutting Down ===");
   Print("Runtime: ", (TimeCurrent() - g_startTime) / 3600, " hours");
   Print("API success rate: ", g_refreshManager.GetStatistics().GetSuccessRate(), "%");
}

//+------------------------------------------------------------------+
void OnTick()
{
   g_tickCount++;
   
   if(g_tickCount % 20 == 0)
   {
      g_spreadManager.UpdateStatistics();
      g_spreadManager.LogSpreadStatus();
   }
   
   UpdatePositionState();
   CheckDailyReset();
   
   if(InpUseEquityCurveProtection && CheckEquityProtection())
      return;
   
   if(!g_spreadManager.IsSpreadAcceptable())
      return;
   
   g_refreshManager.UpdateAdaptiveIntervals();
   
   if(g_refreshManager.ShouldRefreshContext())
      RefreshContextFromAPI();
   
   if(g_refreshManager.ShouldRefreshSignal())
      RefreshSignalFromAPI();
   
   ExecuteTradingLogic();
   ManageOpenPositions();
}

//+------------------------------------------------------------------+
void RefreshContextFromAPI(void)
{
   static datetime lastApiCallTime = 0;
   
   // Rate limit protection - enforce minimum 500ms between calls
   if(TimeCurrent() - lastApiCallTime < 1) 
      Sleep(500);
   
   string jsonRequest = BuildAnalysisRequest();
   
   if(StringLen(jsonRequest) == 0)
   {
      Print("ERROR: Empty JSON request");
      g_refreshManager.RecordApiFailure("Empty request");
      return;
   }
   
   string headers;
   StringAdd(headers, "Content-Type: application/json\r\n");
   StringAdd(headers, "Connection: close\r\n");  // Force new connection (prevents 1003)
   if(StringLen(InpApiKey) > 0)
      StringAdd(headers, "Authorization: Bearer " + InpApiKey + "\r\n");
   
   char data[], result[];
   int strLen = StringToCharArray(jsonRequest, data);
   if(strLen > 0) ArrayResize(data, strLen);
   
   // Retry loop with exponential backoff
   int maxRetries = 3;
   int res = -1;
   
   for(int attempt = 0; attempt < maxRetries; attempt++)
   {
      res = WebRequest("POST", InpApiUrl, headers, InpApiTimeoutMs, data, result, headers);
      
      if(res == 200) break;  // Success
      
      if(res == 1003)  // Connection error - wait and retry
      {
         Print("API Warning: HTTP 1003 on attempt ", attempt + 1, ", retrying...");
         Sleep(500 * (attempt + 1));  // 500ms, 1000ms, 1500ms
         continue;
      }
      
      // Other errors - fail immediately
      break;
   }
   
   lastApiCallTime = TimeCurrent();
   
   if(res != 200)
   {
      Print("API Error: HTTP ", res);
      g_refreshManager.RecordApiFailure("HTTP " + IntegerToString(res));
      return;
   }
   
   string response = CharArrayToString(result);
   g_state.lastApiResponse = response;
   
   CJAVal json;
   if(!json.Deserialize(response))
   {
      Print("JSON Parse Error");
      g_refreshManager.RecordApiFailure("JSON parse error");
      return;
   }
   
   g_state.volatilityRegime = json["regime"].ToStr();
   g_state.trendAlignment = json["trend_alignment"].ToDbl();
   g_state.signalConfidence = json["confidence"].ToDbl();
   g_state.entryPrecision = json["entry_precision"].ToDbl();
   
   string signal = json["signal"].ToStr();
   if(signal == "BUY") g_state.signalDirection = 1;
   else if(signal == "SELL") g_state.signalDirection = -1;
   else g_state.signalDirection = 0;
   
   g_refreshManager.RecordApiSuccess(0);
   g_state.lastContextUpdate = TimeCurrent();
   g_state.lastSignalUpdate = TimeCurrent();
   
   Print("Context updated: Signal=", signal, " Regime=", g_state.volatilityRegime, 
         " Conf=", DoubleToString(g_state.signalConfidence, 2));
}

//+------------------------------------------------------------------+
void RefreshSignalFromAPI(void)
{
   // Context refresh already gets signal, just update timing
   if(TimeCurrent() - g_state.lastSignalUpdate > 60)
      RefreshContextFromAPI();
}

//+------------------------------------------------------------------+
//| Build Rolling Window JSON Request                                  |
//+------------------------------------------------------------------+
string BuildAnalysisRequest(void)
{
   MqlRates ratesH1[], ratesM15[], ratesM5[], ratesM1[];
   
   ArraySetAsSeries(ratesH1, true);
   ArraySetAsSeries(ratesM15, true);
   ArraySetAsSeries(ratesM5, true);
   ArraySetAsSeries(ratesM1, true);
   
   // CRITICAL FIX: Synchronize all timeframes to the same end time
   // This ensures temporal alignment for the Python fusion engine
   datetime end_time = TimeCurrent() - 1; // -1 sec to ensure complete candles
   
   // Calculate start times so all windows cover the same time period
   datetime startH1  = end_time - (InpContextWindowSize * PeriodSeconds(PERIOD_H1));
   datetime startM15 = end_time - (InpContextWindowSize * PeriodSeconds(PERIOD_M15));
   datetime startM5  = end_time - (InpExecutionWindowSize * PeriodSeconds(PERIOD_M5));
   datetime startM1  = end_time - (InpExecutionWindowSize * PeriodSeconds(PERIOD_M1));
   
   // Copy synchronized rolling windows (aligned to end_time)
   int copiedH1  = CopyRates(g_state.symbol, PERIOD_H1, startH1, InpContextWindowSize, ratesH1);
   int copiedM15 = CopyRates(g_state.symbol, PERIOD_M15, startM15, InpContextWindowSize, ratesM15);
   int copiedM5  = CopyRates(g_state.symbol, PERIOD_M5, startM5, InpExecutionWindowSize, ratesM5);
   int copiedM1  = CopyRates(g_state.symbol, PERIOD_M1, startM1, InpExecutionWindowSize, ratesM1);
   
   // Validate
   if(copiedH1 < InpContextWindowSize || copiedM15 < InpContextWindowSize ||
      copiedM5 < InpExecutionWindowSize || copiedM1 < InpExecutionWindowSize)
   {
      Print("ERROR: Insufficient history. H1:", copiedH1, " M15:", copiedM15, 
            " M5:", copiedM5, " M1:", copiedM1);
      return "";
   }
   
   // Debug: Verify temporal alignment
   Print("Time sync check - H1 newest:", TimeToString(ratesH1[0].time), 
         " oldest:", TimeToString(ratesH1[copiedH1-1].time));
   Print("Time sync check - M15 newest:", TimeToString(ratesM15[0].time), 
         " oldest:", TimeToString(ratesM15[copiedM15-1].time));
   Print("Time sync check - M5 newest:", TimeToString(ratesM5[0].time), 
         " oldest:", TimeToString(ratesM5[copiedM5-1].time));
   Print("Time sync check - M1 newest:", TimeToString(ratesM1[0].time), 
         " oldest:", TimeToString(ratesM1[copiedM1-1].time));
   
   string json = "{";
   json += "\"symbol\": \"" + g_state.symbol + "\",";
   json += "\"asset_class\": \"gold\",";
   
   // Context Windows (Regime Detection)
   json += "\"context_h1\": " + TimeframeWindowToJson(ratesH1, copiedH1) + ",";
   json += "\"context_m15\": " + TimeframeWindowToJson(ratesM15, copiedM15) + ",";
   
   // Execution Windows (Entry Precision)
   json += "\"execution_m5\": " + TimeframeWindowToJson(ratesM5, copiedM5) + ",";
   json += "\"execution_m1\": " + TimeframeWindowToJson(ratesM1, copiedM1) + ",";
   
   // Account info
   json += "\"account\": {";
   json += "\"balance\": " + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2) + ",";
   json += "\"equity\": " + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2);
   json += "},";
   
   json += "\"spread_pips\": " + DoubleToString(g_spreadManager.GetSpreadPips(), 1);
   json += "}";
   
   Print("JSON Length: ", StringLen(json));
   Print("M15 candles count: ", copiedM15);
   Print("M1 candles count: ", copiedM1);
   
   return json;
}

//+------------------------------------------------------------------+
//| Convert MqlRates array to JSON window                              |
//+------------------------------------------------------------------+
string TimeframeWindowToJson(MqlRates &rates[], int count)
{
   string window = "{";
   
   // Calculate ATR from the window (simplified)
   double atr = CalculateATRFromRates(rates, count);
   window += "\"atr\": " + DoubleToString(atr, 5) + ",";
   
   // Add candles array
   window += "\"candles\": [";
   
   for(int i = count - 1; i >= 0; i--) // Send oldest first (chronological)
   {
      if(i < count - 1) window += ",";
      
      window += "{";
      window += "\"time\": " + IntegerToString((int)rates[i].time) + ",";
      window += "\"open\": " + DoubleToString(rates[i].open, g_state.profile.digits) + ",";
      window += "\"high\": " + DoubleToString(rates[i].high, g_state.profile.digits) + ",";
      window += "\"low\": " + DoubleToString(rates[i].low, g_state.profile.digits) + ",";
      window += "\"close\": " + DoubleToString(rates[i].close, g_state.profile.digits) + ",";
      window += "\"tick_volume\": " + IntegerToString((int)rates[i].tick_volume) + ",";
      window += "\"real_volume\": " + IntegerToString((int)rates[i].real_volume);
      window += "}";
   }
   
   window += "]}";
   return window;
}

//+------------------------------------------------------------------+
double CalculateATRFromRates(MqlRates &rates[], int count)
{
   if(count < 2) return 0;
   double sum = 0;
   for(int i = 1; i < count; i++)
   {
      double high_low = rates[i].high - rates[i].low;
      double high_close = MathAbs(rates[i].high - rates[i-1].close);
      double low_close = MathAbs(rates[i].low - rates[i-1].close);
      sum += MathMax(high_low, MathMax(high_close, low_close));
   }
   return sum / (count - 1);
}

//+------------------------------------------------------------------+
void ExecuteTradingLogic(void)
{
   if(g_state.signalConfidence < InpMinSignalConfidence) return;
   if(g_state.entryPrecision < 0.5) return; // Minimum precision
   if(InpRequireTrendAlignment && g_state.trendAlignment < 0.6) return;
   if(g_state.openPositions >= InpMaxPositions) return;
   if(g_state.dailyTrades >= 15) return;
   
   if(g_state.signalDirection == 1 && CanOpenLong())
      OpenPosition(ORDER_TYPE_BUY);
   else if(g_state.signalDirection == -1 && CanOpenShort())
      OpenPosition(ORDER_TYPE_SELL);
}

//+------------------------------------------------------------------+
void OpenPosition(ENUM_ORDER_TYPE orderType)
{
   double lots = CalculateLotSize();
   if(lots <= 0) return;
   
   double atr = CalculateATR(PERIOD_M5, 14);
   double slDistance = atr * g_state.profile.slMultiplier;
   double tpDistance = atr * g_state.profile.tpMultiplier;
   
   MqlTick tick;
   if(!SymbolInfoTick(g_state.symbol, tick)) return;
   
   double price = (orderType == ORDER_TYPE_BUY) ? tick.ask : tick.bid;
   double sl = (orderType == ORDER_TYPE_BUY) ? price - slDistance : price + slDistance;
   double tp = (orderType == ORDER_TYPE_BUY) ? price + tpDistance : price - tpDistance;
   
   double tickSize = SymbolInfoDouble(g_state.symbol, SYMBOL_TRADE_TICK_SIZE);
   sl = NormalizeDouble(MathRound(sl / tickSize) * tickSize, g_state.profile.digits);
   tp = NormalizeDouble(MathRound(tp / tickSize) * tickSize, g_state.profile.digits);
   
   bool success = (orderType == ORDER_TYPE_BUY) ? 
      g_trade.Buy(lots, g_state.symbol, price, sl, tp) :
      g_trade.Sell(lots, g_state.symbol, price, sl, tp);
   
   if(success)
   {
      g_state.lastTradeTime = TimeCurrent();
      g_state.dailyTrades++;
      g_state.pyramidCount++;
      Print("Opened ", (orderType == ORDER_TYPE_BUY ? "BUY" : "SELL"), " | Lots: ", DoubleToString(lots, 2));
   }
}

//+------------------------------------------------------------------+
double CalculateLotSize(void)
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * InpRiskPercent / 100.0;
   if(g_state.openPositions > 0) riskAmount *= 1.0; // No pyramid multiplier for now
   
   double atr = CalculateATR(PERIOD_M5, 14);
   double slDistance = atr * g_state.profile.slMultiplier;
   if(slDistance <= 0) return 0;
   
   double tickValue = SymbolInfoDouble(g_state.symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(g_state.symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0 || tickSize <= 0) return 0;
   
   double lots = riskAmount / (slDistance * tickValue / tickSize);
   double lotStep = SymbolInfoDouble(g_state.symbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(g_state.symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(g_state.symbol, SYMBOL_VOLUME_MAX);
   
   lots = MathFloor(lots / lotStep) * lotStep;
   return MathMax(minLot, MathMin(maxLot, lots));
}

//+------------------------------------------------------------------+
void ManageOpenPositions(void)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) != g_state.symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != 42002) continue;
      
      long posType = PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      
      MqlTick tick;
      SymbolInfoTick(g_state.symbol, tick);
      
      double atr = CalculateATR(PERIOD_M5, 14);
      double trailDistance = atr * 1.5;
      double newSL = currentSL;
      
      if(posType == POSITION_TYPE_BUY)
      {
         double potentialSL = tick.bid - trailDistance;
         if(potentialSL > openPrice && potentialSL > currentSL) newSL = potentialSL;
      }
      else
      {
         double potentialSL = tick.ask + trailDistance;
         if(potentialSL < openPrice && potentialSL < currentSL) newSL = potentialSL;
      }
      
      if(newSL != currentSL)
      {
         double tickSize = SymbolInfoDouble(g_state.symbol, SYMBOL_TRADE_TICK_SIZE);
         newSL = NormalizeDouble(MathRound(newSL / tickSize) * tickSize, g_state.profile.digits);
         g_trade.PositionModify(PositionGetInteger(POSITION_TICKET), newSL, PositionGetDouble(POSITION_TP));
      }
   }
}

//+------------------------------------------------------------------+
void UpdatePositionState(void)
{
   g_state.openPositions = 0;
   g_state.totalLots = 0;
   g_state.unrealizedPnL = 0;
   double totalWeightedPrice = 0;
   
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(PositionGetSymbol(i) != g_state.symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != 42002) continue;
      
      g_state.openPositions++;
      double lots = PositionGetDouble(POSITION_VOLUME);
      double price = PositionGetDouble(POSITION_PRICE_OPEN);
      g_state.totalLots += lots;
      totalWeightedPrice += price * lots;
      g_state.unrealizedPnL += PositionGetDouble(POSITION_PROFIT);
   }
   
   if(g_state.totalLots > 0)
      g_state.avgEntryPrice = totalWeightedPrice / g_state.totalLots;
   else
   {
      g_state.avgEntryPrice = 0;
      g_state.pyramidCount = 0;
   }
}

//+------------------------------------------------------------------+
void CheckDailyReset(void)
{
   datetime currentDay = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   if(currentDay != g_state.tradingDay)
   {
      Print("=== New Trading Day ===");
      Print("Previous PnL: ", DoubleToString(g_state.dailyPnL, 2));
      g_state.dailyPnL = 0;
      g_state.dailyTrades = 0;
      g_state.tradingDay = currentDay;
   }
}

//+------------------------------------------------------------------+
bool CheckEquityProtection(void)
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   return equity < balance * (1 - InpMaxDailyRisk / 100.0);
}

//+------------------------------------------------------------------+
bool CanOpenLong(void)
{
   for(int i = 0; i < PositionsTotal(); i++)
      if(PositionGetSymbol(i) == g_state.symbol && 
         PositionGetInteger(POSITION_MAGIC) == 42002 &&
         PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL)
         return false;
   return true;
}

//+------------------------------------------------------------------+
bool CanOpenShort(void)
{
   for(int i = 0; i < PositionsTotal(); i++)
      if(PositionGetSymbol(i) == g_state.symbol && 
         PositionGetInteger(POSITION_MAGIC) == 42002 &&
         PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
         return false;
   return true;
}

//+------------------------------------------------------------------+
double CalculateATR(ENUM_TIMEFRAMES tf, int period)
{
   int handle = iATR(g_state.symbol, tf, period);
   if(handle == INVALID_HANDLE) return 0;
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