//+------------------------------------------------------------------+
//|                                   ProfessionalVolumeProfile.mq5  |
//|                          (c) CODINGMASTER+ / Institutionell      |
//|                                  VPVR - Visible Range            |
//|                                  VERSION 3.06 - CRITICAL FIXES   |
//+------------------------------------------------------------------+
#property copyright "CODINGMASTER+"
#property version   "3.06"
#property description "Volume Profile Visible Range - Performance & Bug Fixes"
#property indicator_chart_window
#property indicator_plots 0

//--- ENUM für die Volumenquelle
enum EVolumeSource
{
   VOL_TICK, // Tick-Volumen (Standard)
   VOL_REAL  // Echtes Volumen (falls verfügbar)
};

//============================================================================
// INPUT PARAMETERS
//============================================================================

input group "=== Profile Settings ==="
input int             InpNumberOfRows    = 300;  // Anzahl Preis-Zeilen (Auflösung)
input double          InpValueAreaPct    = 70.0; // Value Area (Standard 70%)
input EVolumeSource   InpVolumeSource    = VOL_TICK; // Volumen-Quelle (Tick oder Real)

input group "=== Visualization ==="
input int             InpHistogramWidth  = 80;   // Breite des Profils (in Bars)
input color           InpColorProfile    = clrGray;    // Farbe Profil
input color           InpColorValueArea  = clrSteelBlue; // Farbe Value Area (VA)
input color           InpColorPOC        = clrOrange;  // Farbe Point of Control (POC)
input int             InpPOCWidth        = 3;    // Breite POC-Linie (1-5)

input group "=== Value Area Lines ==="
input bool            InpShowVALines     = true;  // Zeige VA High/Low Linien
input color           InpColorVAH        = clrLimeGreen;  // Farbe Value Area High
input color           InpColorVAL        = clrRed;        // Farbe Value Area Low
input int             InpVALineWidth     = 2;    // Breite VA-Linien (1-5)

input group "=== Advanced ==="
input bool            InpDebugMode       = false; // Debug-Modus aktivieren

//============================================================================
// CONSTANTS
//============================================================================
const int MAX_ROWS = 2000;
const int MIN_ROWS = 10;

//============================================================================
// STRUCTURES
//============================================================================
struct SPriceBucket
{
   double   price;
   long     volume;
   bool     inValueArea;
};

struct SVisibleRange
{
   int      firstBar;
   int      lastBar;
   double   minPrice;
   double   maxPrice;
};

//============================================================================
// GLOBAL VARIABLES
//============================================================================
SPriceBucket g_buckets[];
int          g_totalBuckets = 0;
double       g_rowHeight = 0;
string       g_objPrefix = "";
SVisibleRange g_lastRange;

//============================================================================
// DEBUG MACRO
//============================================================================
#define DEBUG_PRINT(msg) if(InpDebugMode) Print(msg)

//============================================================================
// INITIALIZATION
//============================================================================
int OnInit()
{
   if(InpNumberOfRows < MIN_ROWS || InpNumberOfRows > MAX_ROWS)
   {
      Print("FEHLER: Anzahl Zeilen muss zwischen ", MIN_ROWS, " und ", MAX_ROWS, " sein");
      return(INIT_PARAMETERS_INCORRECT);
   }

   if(InpHistogramWidth <= 0)
   {
      Print("FEHLER: Breite muss positiv sein");
      return(INIT_PARAMETERS_INCORRECT);
   }

   //--- ✅ FIX #3: Validiere echtes Volumen
   if(InpVolumeSource == VOL_REAL)
   {
      MqlRates testRates[];
      ArraySetAsSeries(testRates, false);

      if(CopyRates(_Symbol, _Period, 0, 10, testRates) > 0)
      {
         bool hasRealVolume = false;
         for(int i = 0; i < ArraySize(testRates); i++)
         {
            if(testRates[i].real_volume > 0)
            {
               hasRealVolume = true;
               break;
            }
         }

         if(!hasRealVolume)
         {
            Print("FEHLER: Symbol liefert kein echtes Volumen!");
            Print("Bitte 'Tick-Volumen' in den Einstellungen wählen.");
            return(INIT_PARAMETERS_INCORRECT);
         }
      }
      else
      {
         Print("WARNUNG: Konnte Volumen nicht prüfen, Error: ", GetLastError());
      }
   }

   g_objPrefix = "VolProfile_" + IntegerToString(ChartID()) + "_";

   g_lastRange.firstBar = -1;
   g_lastRange.lastBar = -1;
   g_lastRange.minPrice = 0;
   g_lastRange.maxPrice = 0;

   Print("Professional Volume Profile v3.06 initialisiert");
   Print("  Symbol: ", _Symbol);
   Print("  Zeilen: ", InpNumberOfRows);
   Print("  Debug: ", InpDebugMode ? "EIN" : "AUS");

   return(INIT_SUCCEEDED);
}

//============================================================================
// DEINITIALIZATION
//============================================================================
void OnDeinit(const int reason)
{
   CleanupObjects();
   ArrayFree(g_buckets);
   Print("VPVR v3.06 beendet");
}

//============================================================================
// CHART EVENT HANDLING - HAUPTLOGIK HIER!
//============================================================================
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   //--- Bei Chart-Änderungen sofort neu berechnen
   if(id == CHARTEVENT_CHART_CHANGE)
   {
      CalculateAndDrawProfile();
   }
}

//============================================================================
// MAIN CALCULATION - Minimal, nur für neue Bars
//============================================================================
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
{
   //--- Bei neuen Bars: neu berechnen
   static datetime lastBarTime = 0;
   if(rates_total > 0 && time[rates_total-1] != lastBarTime)
   {
      lastBarTime = time[rates_total-1];
      CalculateAndDrawProfile();
   }

   return(rates_total);
}

//============================================================================
// HAUPTBERECHNUNGSLOGIK - Wird von OnChartEvent UND OnCalculate aufgerufen
//============================================================================
void CalculateAndDrawProfile()
{
   //--- 1. Ermittle sichtbaren Bereich ZUERST (für optimierte CopyRates)
   int firstVisible = (int)ChartGetInteger(0, CHART_FIRST_VISIBLE_BAR);
   int visibleBars = (int)ChartGetInteger(0, CHART_VISIBLE_BARS);
   int totalBars = Bars(_Symbol, _Period);

   if(totalBars <= 0 || visibleBars <= 0 || firstVisible < 0)
   {
      DEBUG_PRINT("DEBUG: Ungültige Chart-Parameter");
      return;
   }

   DEBUG_PRINT("DEBUG: CHART_FIRST_VISIBLE_BAR=" + IntegerToString(firstVisible) +
               " CHART_VISIBLE_BARS=" + IntegerToString(visibleBars));

   //--- ✅ FIX #1: Kopiere nur benötigte Bars (nicht alle!)
   // Margin für Sicherheit: max(100 Bars, HistogramWidth + 50)
   int margin = MathMax(100, InpHistogramWidth + 50);
   int barsNeeded = MathMin(totalBars, visibleBars + margin);

   MqlRates rates[];
   ArraySetAsSeries(rates, false);
   int copied = CopyRates(_Symbol, _Period, 0, barsNeeded, rates);

   if(copied <= 0)
   {
      Print("FEHLER: CopyRates fehlgeschlagen, Error: ", GetLastError());
      return;
   }

   DEBUG_PRINT("DEBUG: " + IntegerToString(copied) + " Bars kopiert (optimiert von " +
               IntegerToString(totalBars) + ")");

   //--- 2. Sichtbaren Bereich im kopierten Array ermitteln
   SVisibleRange currentRange;
   if(!GetVisibleRange(copied, totalBars, firstVisible, visibleBars, currentRange))
   {
      DEBUG_PRINT("DEBUG: GetVisibleRange fehlgeschlagen");
      return;
   }

   DEBUG_PRINT("DEBUG: Sichtbarer Bereich: firstBar=" + IntegerToString(currentRange.firstBar) +
               " lastBar=" + IntegerToString(currentRange.lastBar));

   //--- ✅ FIX #2: Preis-Spanne ZUERST finden (VOR Dirty-Check!)
   double minPrice, maxPrice;
   if(!FindPriceRange(currentRange.firstBar, currentRange.lastBar, rates, minPrice, maxPrice))
   {
      DEBUG_PRINT("DEBUG: FindPriceRange fehlgeschlagen");
      CleanupObjects();
      return;
   }

   currentRange.minPrice = minPrice;
   currentRange.maxPrice = maxPrice;

   DEBUG_PRINT("DEBUG: Preis-Spanne: min=" + DoubleToString(minPrice, _Digits) +
               " max=" + DoubleToString(maxPrice, _Digits));

   //--- 3. Dirty-Check (jetzt MIT korrekten Preisen)
   if(!HasRangeChanged(currentRange))
   {
      DEBUG_PRINT("DEBUG: Range hat sich nicht geändert, überspringe Neuberechnung");
      return;
   }

   //--- 4. Buckets initialisieren
   InitializeBuckets(minPrice, maxPrice);
   if(g_totalBuckets == 0)
   {
      DEBUG_PRINT("DEBUG: Keine Buckets initialisiert");
      CleanupObjects();
      return;
   }

   DEBUG_PRINT("DEBUG: " + IntegerToString(g_totalBuckets) + " Buckets initialisiert, rowHeight=" +
               DoubleToString(g_rowHeight, _Digits));

   //--- 5. Volumen akkumulieren
   long totalVolume = AccumulateVolume(currentRange.firstBar, currentRange.lastBar, rates, minPrice);
   if(totalVolume == 0)
   {
      DEBUG_PRINT("DEBUG: Kein Volumen akkumuliert");
      CleanupObjects();
      return;
   }

   DEBUG_PRINT("DEBUG: Total Volumen=" + IntegerToString(totalVolume));

   //--- 6. POC und Value Area finden
   double pocPrice = 0;
   long maxVolume = FindPocAndValueArea(totalVolume, pocPrice);

   if(maxVolume == 0)
   {
      DEBUG_PRINT("DEBUG: POC nicht gefunden");
      CleanupObjects();
      return;
   }

   DEBUG_PRINT("DEBUG: POC Preis=" + DoubleToString(pocPrice, _Digits) +
               " maxVolume=" + IntegerToString(maxVolume));

   //--- 7. Profil zeichnen
   DrawProfile(rates, maxVolume, pocPrice, currentRange.lastBar);

   //--- 8. Bereich speichern
   g_lastRange = currentRange;

   DEBUG_PRINT("DEBUG: Profil erfolgreich gezeichnet");
   ChartRedraw(0);
}

//============================================================================
// HILFSFUNKTIONEN
//============================================================================
bool GetVisibleRange(int copiedBars, int totalBars, int firstVisible, int visibleBars,
                     SVisibleRange &outRange)
{
   int newestBarIndex = totalBars - 1;
   int leftmostVisibleIndex = newestBarIndex - firstVisible;
   int rightmostVisibleIndex = leftmostVisibleIndex + visibleBars - 1;

   // Begrenze auf tatsächlich kopierte Bars
   if(leftmostVisibleIndex >= copiedBars) leftmostVisibleIndex = copiedBars - 1;
   if(rightmostVisibleIndex >= copiedBars) rightmostVisibleIndex = copiedBars - 1;
   if(leftmostVisibleIndex < 0) leftmostVisibleIndex = 0;
   if(rightmostVisibleIndex < 0) rightmostVisibleIndex = 0;

   if(leftmostVisibleIndex > rightmostVisibleIndex)
   {
      DEBUG_PRINT("DEBUG: leftmost > rightmost");
      return false;
   }

   outRange.firstBar = leftmostVisibleIndex;
   outRange.lastBar = rightmostVisibleIndex;

   return true;
}

bool HasRangeChanged(const SVisibleRange &newRange)
{
   if(g_lastRange.firstBar != newRange.firstBar) return true;
   if(g_lastRange.lastBar != newRange.lastBar) return true;

   if(g_rowHeight <= 0) return true;

   double priceTolerance = g_rowHeight * 0.1;
   if(MathAbs(g_lastRange.minPrice - newRange.minPrice) > priceTolerance) return true;
   if(MathAbs(g_lastRange.maxPrice - newRange.maxPrice) > priceTolerance) return true;

   return false;
}

bool FindPriceRange(int startBar, int endBar, const MqlRates &rates[],
                    double &outMinPrice, double &outMaxPrice)
{
   if(startBar < 0 || endBar >= ArraySize(rates) || startBar > endBar)
   {
      DEBUG_PRINT("DEBUG: FindPriceRange ungültige Indizes: start=" + IntegerToString(startBar) +
                  " end=" + IntegerToString(endBar) + " arraySize=" + IntegerToString(ArraySize(rates)));
      return false;
   }

   outMaxPrice = rates[startBar].high;
   outMinPrice = rates[startBar].low;

   for(int i = startBar; i <= endBar; i++)
   {
      if(rates[i].high > outMaxPrice) outMaxPrice = rates[i].high;
      if(rates[i].low < outMinPrice) outMinPrice = rates[i].low;
   }

   if(outMaxPrice <= outMinPrice)
   {
      DEBUG_PRINT("DEBUG: Ungültige Preisspanne: max=" + DoubleToString(outMaxPrice, _Digits) +
                  " min=" + DoubleToString(outMinPrice, _Digits));
      return false;
   }

   return true;
}

void InitializeBuckets(double minPrice, double maxPrice)
{
   ArrayFree(g_buckets);

   double priceRange = maxPrice - minPrice;
   g_rowHeight = priceRange / InpNumberOfRows;

   if(g_rowHeight <= 0)
   {
      DEBUG_PRINT("DEBUG: Ungültige rowHeight=" + DoubleToString(g_rowHeight, _Digits));
      g_totalBuckets = 0;
      return;
   }

   g_totalBuckets = InpNumberOfRows;
   ArrayResize(g_buckets, g_totalBuckets);

   for(int i = 0; i < g_totalBuckets; i++)
   {
      g_buckets[i].price = minPrice + i * g_rowHeight;
      g_buckets[i].volume = 0;
      g_buckets[i].inValueArea = false;
   }
}

long AccumulateVolume(int startBar, int endBar, const MqlRates &rates[], double minPrice)
{
   if(startBar < 0 || endBar >= ArraySize(rates) || startBar > endBar)
   {
      DEBUG_PRINT("DEBUG: AccumulateVolume ungültige Indizes");
      return 0;
   }

   long totalVolume = 0;

   for(int bar = startBar; bar <= endBar; bar++)
   {
      long barVolume = (InpVolumeSource == VOL_TICK) ? rates[bar].tick_volume : rates[bar].real_volume;
      if(barVolume <= 0) continue;

      double barLow = rates[bar].low;
      double barHigh = rates[bar].high;

      int startBucket = (int)((barLow - minPrice) / g_rowHeight);
      int endBucket = (int)((barHigh - minPrice) / g_rowHeight);

      if(startBucket < 0) startBucket = 0;
      if(endBucket >= g_totalBuckets) endBucket = g_totalBuckets - 1;
      if(endBucket < startBucket) continue;

      int bucketsInBar = endBucket - startBucket + 1;
      long volPerBucket = barVolume / bucketsInBar;
      long remainder = barVolume % bucketsInBar;

      for(int b = startBucket; b <= endBucket; b++)
      {
         if(b < 0 || b >= g_totalBuckets) continue;

         long volToAdd = volPerBucket;
         if(b - startBucket < remainder)
            volToAdd++;

         g_buckets[b].volume += volToAdd;
         totalVolume += volToAdd;
      }
   }

   return totalVolume;
}

long FindPocAndValueArea(long totalVolume, double &outPocPrice)
{
   if(g_totalBuckets == 0 || totalVolume == 0)
      return 0;

   long maxVolume = 0;
   int pocIndex = -1;

   for(int i = 0; i < g_totalBuckets; i++)
   {
      if(g_buckets[i].volume > maxVolume)
      {
         maxVolume = g_buckets[i].volume;
         pocIndex = i;
      }
   }

   if(pocIndex == -1 || maxVolume == 0)
      return 0;

   // POC in der Mitte des Buckets
   outPocPrice = g_buckets[pocIndex].price + (g_rowHeight / 2.0);
   g_buckets[pocIndex].inValueArea = true;

   if(InpValueAreaPct <= 0)
      return maxVolume;

   long vaVolumeTarget = (long)(totalVolume * (InpValueAreaPct / 100.0));
   long currentVaVolume = maxVolume;

   int up = pocIndex + 1;
   int down = pocIndex - 1;

   while(currentVaVolume < vaVolumeTarget && (up < g_totalBuckets || down >= 0))
   {
      long volUp = (up < g_totalBuckets) ? g_buckets[up].volume : -1;
      long volDown = (down >= 0) ? g_buckets[down].volume : -1;

      if(volUp < 0 && volDown < 0)
         break;

      if(volUp >= volDown && volUp >= 0)
      {
         currentVaVolume += volUp;
         g_buckets[up].inValueArea = true;
         up++;
      }
      else if(volDown >= 0)
      {
         currentVaVolume += volDown;
         g_buckets[down].inValueArea = true;
         down--;
      }
   }

   return maxVolume;
}

void DrawProfile(const MqlRates &rates[], long maxVolume, double pocPrice, int rightmostVisibleBar)
{
   CleanupObjects();

   if(ArraySize(rates) == 0 || g_totalBuckets == 0 || maxVolume == 0)
   {
      DEBUG_PRINT("DEBUG: DrawProfile - ungültige Parameter");
      return;
   }

   if(rightmostVisibleBar < 0 || rightmostVisibleBar >= ArraySize(rates))
   {
      DEBUG_PRINT("DEBUG: DrawProfile - ungültiger rightmostVisibleBar=" +
                  IntegerToString(rightmostVisibleBar));
      return;
   }

   datetime rightEdge = rates[rightmostVisibleBar].time;
   long periodSecs = PeriodSeconds(_Period);

   datetime t2 = rightEdge;
   datetime t1 = (datetime)(t2 - periodSecs * InpHistogramWidth);

   DEBUG_PRINT("DEBUG: DrawProfile - t1=" + TimeToString(t1) + " t2=" + TimeToString(t2) +
               " rightmostBar=" + IntegerToString(rightmostVisibleBar));

   int objectsCreated = 0;

   //--- Alle Buckets als horizontale Balken zeichnen
   for(int i = 0; i < g_totalBuckets; i++)
   {
      if(g_buckets[i].volume == 0) continue;

      double p1 = g_buckets[i].price;
      double p2 = p1 + g_rowHeight;

      double volPercentage = (double)g_buckets[i].volume / maxVolume;
      datetime t_start = (datetime)(t2 - (long)(periodSecs * InpHistogramWidth * volPercentage));

      color barColor = g_buckets[i].inValueArea ? InpColorValueArea : InpColorProfile;

      DrawRectangle(g_objPrefix + "Bar_" + IntegerToString(i), t_start, p1, t2, p2, barColor);
      objectsCreated++;
   }

   //--- POC als horizontale Linie
   DrawHorizontalLine(g_objPrefix + "POC_Line", t1, t2, pocPrice, InpColorPOC, InpPOCWidth);
   objectsCreated++;

   //--- Value Area High/Low Linien
   if(InpShowVALines)
   {
      double vahPrice = 0;
      double valPrice = 0;

      for(int i = 0; i < g_totalBuckets; i++)
      {
         if(g_buckets[i].inValueArea)
         {
            // VAL: Unterkante des niedrigsten Buckets
            if(valPrice == 0 || g_buckets[i].price < valPrice)
               valPrice = g_buckets[i].price;

            // VAH: Oberkante des höchsten Buckets
            double bucketTop = g_buckets[i].price + g_rowHeight;
            if(vahPrice == 0 || bucketTop > vahPrice)
               vahPrice = bucketTop;
         }
      }

      if(vahPrice > 0)
      {
         DrawHorizontalLine(g_objPrefix + "VAH_Line", t1, t2, vahPrice, InpColorVAH, InpVALineWidth);
         objectsCreated++;
         DEBUG_PRINT("DEBUG: VAH gezeichnet bei " + DoubleToString(vahPrice, _Digits));
      }

      if(valPrice > 0)
      {
         DrawHorizontalLine(g_objPrefix + "VAL_Line", t1, t2, valPrice, InpColorVAL, InpVALineWidth);
         objectsCreated++;
         DEBUG_PRINT("DEBUG: VAL gezeichnet bei " + DoubleToString(valPrice, _Digits));
      }
   }

   DEBUG_PRINT("DEBUG: " + IntegerToString(objectsCreated) + " Objekte gezeichnet");
}

void DrawRectangle(string name, datetime t1, double p1, datetime t2, double p2, color clr)
{
   if(!ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, p1, t2, p2))
   {
      ObjectSetInteger(0, name, OBJPROP_TIME, 0, t1);
      ObjectSetDouble(0, name, OBJPROP_PRICE, 0, p1);
      ObjectSetInteger(0, name, OBJPROP_TIME, 1, t2);
      ObjectSetDouble(0, name, OBJPROP_PRICE, 1, p2);
   }

   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, name, OBJPROP_FILL, true);
}

void DrawHorizontalLine(string name, datetime t1, datetime t2, double price, color clr, int width)
{
   if(!ObjectCreate(0, name, OBJ_TREND, 0, t1, price, t2, price))
   {
      ObjectSetInteger(0, name, OBJPROP_TIME, 0, t1);
      ObjectSetDouble(0, name, OBJPROP_PRICE, 0, price);
      ObjectSetInteger(0, name, OBJPROP_TIME, 1, t2);
      ObjectSetDouble(0, name, OBJPROP_PRICE, 1, price);
   }

   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
}

void CleanupObjects()
{
   int deleted = ObjectsDeleteAll(0, g_objPrefix);
   if(deleted > 0)
      DEBUG_PRINT("DEBUG: " + IntegerToString(deleted) + " Objekte gelöscht");
}
//+------------------------------------------------------------------+
