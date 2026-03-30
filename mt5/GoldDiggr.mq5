//+------------------------------------------------------------------+
//| GoldDiggr_v4_1_Fixed.mq5 - XAUUSD Expert Advisor v4.2         |
//+------------------------------------------------------------------+
//| Description: Fixed version with proper JSON handling for FastAPI |
//+------------------------------------------------------------------+
#property copyright "CrosSstrux v4.1"
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

input group "=== Pyramiding ==="
input bool   InpEnablePyramiding = true;
input double InpPyramidDistanceATR = 0.5;
input double InpPyramidLotMultiplier = 1.0;

input group "=== Session Filters ==="
input bool   InpUseSessionFilter = true;
input bool   InpAvoidLowVolumeHours = true;

input group "=== Logging ==="
input bool   InpVerboseLogging = true;
input int    InpLogFrequency = 20;

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
int g_tickCount = 0;
datetime g_startTime = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   Print("=== GoldDiggr v4.1.1 (FIXED) Initializing ===");
   
   g_state.symbol = Symbol();
   
   if(!g_spreadManager.Initialize(g_state.symbol))
   {
      Print("ERROR: Failed to initialize SpreadManager");
      return INIT_FAILED;
   }
   
   if(!g_profileRegistry.GetProfile(g_state.symbol, g_state.profile))
   {
      Print("WARNING: Using default profile for ", g_state.symbol);
   }
   
   if(!g_refreshManager.Initialize(g_state.symbol, &g_spreadManager))
   {
      Print("ERROR: Failed to initialize ContextRefreshManager");
      return INIT_FAILED;
   }
   
   g_trade.SetExpertMagicNumber(42002);
   g_trade.SetDeviationInPoints(10);
   g_trade.SetTypeFilling(ORDER_FILLING_IOC);
   g_trade.SetAsyncMode(false);
   
   g_profileRegistry.LogProfileDetails(g_state.symbol);
   g_spreadManager.LogSpreadStatus();
   
   g_startTime = TimeCurrent();
   g_state.tradingDay = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   
   Print("GoldDiggr initialized successfully for ", g_state.symbol);
   Print("API Endpoint: ", InpApiUrl);
   
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
   
   if(InpVerboseLogging && g_tickCount % InpLogFrequency == 0)
   {
      g_spreadManager.UpdateStatistics();
      g_spreadManager.LogSpreadStatus();
   }
   
   UpdatePositionState();
   CheckDailyReset();
   
   if(InpUseEquityCurveProtection && CheckEquityProtection())
   {
      if(g_tickCount % 100 == 0)
         Print("Equity protection active");
      return;
   }
   
   g_spreadManager.UpdateStatistics();
   if(!g_spreadManager.IsSpreadAcceptable())
   {
      if(g_tickCount % 100 == 0)
         Print("Spread filter: ", g_spreadManager.GetRejectionReason());
      return;
   }
   
   if(InpUseSessionFilter && !IsTradeSessionValid())
      return;
   
   g_refreshManager.UpdateAdaptiveIntervals();
   
   if(g_refreshManager.ShouldRefreshContext())
   {
      if(g_refreshManager.ShouldCallAPI())
         RefreshContextFromAPI();
   }
   
   if(g_refreshManager.ShouldRefreshSignal())
   {
      if(g_refreshManager.ShouldCallAPI())
         RefreshSignalFromAPI();
   }
   
   ExecuteTradingLogic();
   ManageOpenPositions();
}

//+------------------------------------------------------------------+
bool IsTradeSessionValid(void)
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int hour = dt.hour;
   
   if(InpAvoidLowVolumeHours)
   {
      for(int i = 0; i < ArraySize(g_state.profile.lowVolumeHours); i++)
      {
         if(g_state.profile.lowVolumeHours[i] == hour)
         {
            if(g_tickCount % 300 == 0)
               Print("Low volume hour - reduced activity");
            return false;
         }
      }
   }
   return true;
}

//+------------------------------------------------------------------+
//| FIXED: Refresh Context from API with null-byte fix                 |
//+------------------------------------------------------------------+
void RefreshContextFromAPI(void)
{
   string jsonRequest = BuildAnalysisRequest();
   
   // Validate request
   if(StringLen(jsonRequest) == 0)
   {
      Print("ERROR: Empty JSON request, skipping API call");
      g_refreshManager.RecordApiFailure("Empty request data");
      return;
   }
   
   string headers;
   StringAdd(headers, "Content-Type: application/json\r\n");
   if(StringLen(InpApiKey) > 0)
      StringAdd(headers, "Authorization: Bearer " + InpApiKey + "\r\n");
   
   char data[], result[];
   string url = InpApiUrl;
   int res;
   
   // Convert to char array
   int strLen = StringToCharArray(jsonRequest, data);
   
   // === CRITICAL FIX: Remove null terminator that causes HTTP 422 ===
   if(strLen > 0)
      ArrayResize(data, strLen);
   
   datetime callStart = TimeLocal();
   res = WebRequest("POST", url, headers, InpApiTimeoutMs, data, result, headers);
   
   if(res != 200)
   {
      Print("API Error: HTTP ", res);
      if(res == 422)
         Print("JSON Sent: ", jsonRequest); // Debug info
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
   
   g_refreshManager.RecordApiSuccess((double)(TimeLocal() - callStart));
   g_state.lastContextUpdate = TimeCurrent();
   
   if(InpVerboseLogging)
   {
      Print("Context updated: Regime=", g_state.volatilityRegime, 
            " TrendAlign=", DoubleToString(g_state.trendAlignment, 2));
   }
}

//+------------------------------------------------------------------+
void RefreshSignalFromAPI(void)
{
   if(StringLen(g_state.lastApiResponse) == 0)
   {
      RefreshContextFromAPI();
      return;
   }
   
   CJAVal json;
   if(!json.Deserialize(g_state.lastApiResponse))
   {
      RefreshContextFromAPI();
      return;
   }
   
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
//| FIXED: Build Analysis Request with validation                      |
//+------------------------------------------------------------------+
string BuildAnalysisRequest(void)
{
   MqlRates ratesM1[], ratesM5[], ratesM15[], ratesH1[], ratesD1[];
   
   ArraySetAsSeries(ratesM1, true);
   ArraySetAsSeries(ratesM5, true);
   ArraySetAsSeries(ratesM15, true);
   ArraySetAsSeries(ratesH1, true);
   ArraySetAsSeries(ratesD1, true);
   
   // Copy rates with error checking
   int copied1 = CopyRates(g_state.symbol, PERIOD_M1, 0, 10, ratesM1);
   int copied5 = CopyRates(g_state.symbol, PERIOD_M5, 0, 10, ratesM5);
   int copied15 = CopyRates(g_state.symbol, PERIOD_M15, 0, 10, ratesM15);
   int copiedH1 = CopyRates(g_state.symbol, PERIOD_H1, 0, 10, ratesH1);
   int copiedD1 = CopyRates(g_state.symbol, PERIOD_D1, 0, 10, ratesD1);
   
   // Validate all timeframes have data
   if(copied1 <= 0 || copied5 <= 0 || copied15 <= 0 || copiedH1 <= 0 || copiedD1 <= 0)
   {
      Print("ERROR: Failed to copy rates. M1:", copied1, " M5:", copied5, 
            " M15:", copied15, " H1:", copiedH1, " D1:", copiedD1);
      return "";
   }
   
   // Build JSON
   string json = "{";
   json += "\"symbol\": \"" + g_state.symbol + "\",";
   json += "\"asset_class\": \"gold\",";
   json += "\"timeframes\": {";
   
   // M1
   json += "\"M1\": {";
   json += "\"open\": " + DoubleToString(ratesM1[0].open, g_state.profile.digits) + ",";
   json += "\"high\": " + DoubleToString(ratesM1[0].high, g_state.profile.digits) + ",";
   json += "\"low\": " + DoubleToString(ratesM1[0].low, g_state.profile.digits) + ",";
   json += "\"close\": " + DoubleToString(ratesM1[0].close, g_state.profile.digits) + ",";
   json += "\"tick_volume\": " + IntegerToString((int)ratesM1[0].tick_volume) + ",";
   json += "\"real_volume\": " + IntegerToString((int)ratesM1[0].real_volume);
   json += "},";
   
   // M5
   json += "\"M5\": {";
   json += "\"close\": " + DoubleToString(ratesM5[0].close, g_state.profile.digits) + ",";
   json += "\"atr\": " + DoubleToString(CalculateATR(PERIOD_M5, 14), g_state.profile.digits);
   json += "},";
   
   // M15
   json += "\"M15\": {";
   json += "\"close\": " + DoubleToString(ratesM15[0].close, g_state.profile.digits) + ",";
   json += "\"ema20\": " + DoubleToString(CalculateEMA(PERIOD_M15, 20), g_state.profile.digits);
   json += "},";
   
   // H1
   json += "\"H1\": {";
   json += "\"close\": " + DoubleToString(ratesH1[0].close, g_state.profile.digits) + ",";
   json += "\"ema50\": " + DoubleToString(CalculateEMA(PERIOD_H1, 50), g_state.profile.digits);
   json += "},";
   
   // D1
   json += "\"D1\": {";
   json += "\"close\": " + DoubleToString(ratesD1[0].close, g_state.profile.digits) + ",";
   json += "\"atr\": " + DoubleToString(CalculateATR(PERIOD_D1, 14), g_state.profile.digits);
   json += "}";
   
   json += "},";
   
   // Account
   json += "\"account\": {";
   json += "\"balance\": " + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2) + ",";
   json += "\"equity\": " + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2);
   json += "},";
   
   // Spread
   json += "\"spread_pips\": " + DoubleToString(g_spreadManager.GetSpreadPips(), 1);
   json += "}";
   
   return json;
}

//+------------------------------------------------------------------+
void ExecuteTradingLogic(void)
{
   if(g_state.signalConfidence < InpMinSignalConfidence)
      return;
   
   if(g_state.entryPrecision < g_state.profile.entryPrecisionThreshold)
      return;
   
   if(InpRequireTrendAlignment && g_state.trendAlignment < 0.6)
      return;
   
   if(g_state.openPositions >= InpMaxPositions)
      return;
   
   if(g_state.dailyTrades >= 15)
      return;
   
   if(g_state.openPositions > 0 && g_state.pyramidCount >= g_state.profile.pyramidMaxTrades)
      return;
   
   if(g_state.signalDirection == 1 && CanOpenLong())
      OpenPosition(ORDER_TYPE_BUY);
   else if(g_state.signalDirection == -1 && CanOpenShort())
      OpenPosition(ORDER_TYPE_SELL);
}

//+------------------------------------------------------------------+
void OpenPosition(ENUM_ORDER_TYPE orderType)
{
   double lots = CalculateLotSize();
   if(lots <= 0)
   {
      Print("Invalid lot size calculated");
      return;
   }
   
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
   
   double tickSize = SymbolInfoDouble(g_state.symbol, SYMBOL_TRADE_TICK_SIZE);
   sl = NormalizeDouble(MathRound(sl / tickSize) * tickSize, g_state.profile.digits);
   tp = NormalizeDouble(MathRound(tp / tickSize) * tickSize, g_state.profile.digits);
   
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
      Print("Opened ", dir, " | Lots: ", DoubleToString(lots, 2));
      
      SendNotification(StringFormat("GoldDiggr %s: %s %s lots", 
         g_state.symbol, dir, DoubleToString(lots, 2)));
   }
   else
   {
      Print("Trade failed: ", GetLastError());
   }
}

//+------------------------------------------------------------------+
double CalculateLotSize(void)
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * InpRiskPercent / 100.0;
   
   if(g_state.openPositions > 0)
      riskAmount *= InpPyramidLotMultiplier;
   
   double atr = CalculateATR(PERIOD_M5, 14);
   double slDistance = atr * g_state.profile.slMultiplier;
   
   if(slDistance <= 0)
      return 0;
   
   double tickValue = SymbolInfoDouble(g_state.symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(g_state.symbol, SYMBOL_TRADE_TICK_SIZE);
   
   if(tickValue <= 0 || tickSize <= 0)
      return 0;
   
   double lots = riskAmount / (slDistance * tickValue / tickSize);
   
   double lotStep = SymbolInfoDouble(g_state.symbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(g_state.symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(g_state.symbol, SYMBOL_VOLUME_MAX);
   
   lots = MathFloor(lots / lotStep) * lotStep;
   lots = MathMax(minLot, MathMin(maxLot, lots));
   
   return lots;
}

//+------------------------------------------------------------------+
void ManageOpenPositions(void)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) != g_state.symbol)
         continue;
      
      if(PositionGetInteger(POSITION_MAGIC) != 42002)
         continue;
      
      long posType = PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      
      MqlTick tick;
      SymbolInfoTick(g_state.symbol, tick);
      
      double atr = CalculateATR(PERIOD_M5, 14);
      double trailDistance = atr * 1.5;
      
      double newSL = currentSL;
      
      if(posType == POSITION_TYPE_BUY)
      {
         double potentialSL = tick.bid - trailDistance;
         if(potentialSL > openPrice && potentialSL > currentSL)
            newSL = potentialSL;
      }
      else
      {
         double potentialSL = tick.ask + trailDistance;
         if(potentialSL < openPrice && potentialSL < currentSL)
            newSL = potentialSL;
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
      
      if(PositionGetInteger(POSITION_MAGIC) != 42002)
         continue;
      
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
      Print("Previous day PnL: ", DoubleToString(g_state.dailyPnL, 2));
      
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
   
   if(equity < balance * (1 - InpMaxDailyRisk / 100.0))
      return true;
   
   return false;
}

//+------------------------------------------------------------------+
bool CanOpenLong(void)
{
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(PositionGetSymbol(i) != g_state.symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != 42002) continue;
      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL)
         return false;
   }
   return true;
}

//+------------------------------------------------------------------+
bool CanOpenShort(void)
{
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(PositionGetSymbol(i) != g_state.symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != 42002) continue;
      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
         return false;
   }
   return true;
}

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
//+------------------------------------------------------------------+