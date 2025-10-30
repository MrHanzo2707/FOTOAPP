//+------------------------------------------------------------------+
//|                                DiagonalTrendFinder_v2.4.2.mq5 |
//|                        (BUGFIXES: ATR, Touch-Counting, Bounds)   |
//+------------------------------------------------------------------+
//| CHANGELOG v2.4.2:                                                |
//| ✓ FIX #1: ATR-Array-Indexierung korrigiert                      |
//|   - CopyBuffer() ohne ArraySetAsSeries liefert Index 0 = alt   |
//|   - Direkter Zugriff atrBuffer[bar] nun korrekt                 |
//|                                                                   |
//| ✓ FIX #2: Touch-Counting verbessert                             |
//|   - Neuer Parameter: InpMinBarsBetweenTouches                   |
//|   - Verhindert Überzählung konsekutiver Berührungen            |
//|                                                                   |
//| ✓ FIX #3: Array-Bounds-Checks hinzugefügt                       |
//|   - Prüfung: ArraySize(atrBuffer) > 0                           |
//|   - Prüfung: bar >= 0 && bar < ArraySize(atrBuffer)            |
//|                                                                   |
//| ✓ FIX #4: Division-by-Zero Schutz                               |
//|   - Check: bar1 == bar2 vor Slope-Berechnung                   |
//|   - Return 0 touches bei ungültigen Bar-Paaren                 |
//+------------------------------------------------------------------+
#property copyright "Custom Indicator - ATR Adaptive (v2.4.2 BUGFIX by CODINGMASTER+)"
#property version   "2.42"
#property indicator_chart_window
#property indicator_plots 0

//============================================================================
// INPUT PARAMETERS
//============================================================================
input group "=== Diagonal Line Settings ==="
input bool     InpDiagonalMode      = true;          // Enable Diagonal Mode
input int      InpLookback          = 200;           // Lookback Bars
input int      InpMaxLinesToShow    = 10;            // Max Lines to Display
input int      InpMinTouches        = 3;             // Minimum Touches Required

input group "=== Touch Detection (v2.4.2 - FIXED) ==="
input bool     InpUseATR            = true;          // Use ATR-Based Adaptive Tolerance
input int      InpATR_Period        = 14;            // ATR Period
input double   InpATR_Multiplier    = 1.5;           // ATR Tolerance Multiplier
input double   InpTouchTolerancePips = 5.0;          // Touch Tolerance (Pips) - if ATR OFF
input bool     InpUseWickTouches    = true;          // Count Wick Touches (if false, uses Close)
input int      InpMinBarsBetween    = 3;             // Min Bars Between Pivots
input int      InpMinBarsBetweenTouches = 2;         // Min Bars Between Touches (NEW FIX)

input group "=== Overlap Filter ==="
input bool     InpEnableOverlapFilter = true;        // Enable Overlap Filter
input double   InpMinAngleDiff       = 5.0;          // Min Angle Difference (Degrees)
input int      InpMinDistancePips    = 50;           // Min Distance (Pips)
input double   InpMaxOverlapPercent  = 50.0;         // Max Time Overlap (%)

input group "=== Ebenen ==="
input int      InpLineWidth         = 2;             // Line Width
input bool     InpShowLabels        = true;          // Show Touch Labels
input int      InpExtendBars        = 50;            // Bars to extend label (cosmetic)

input color    InpResistanceColor   = clrRed;        // Resistance Color
input color    InpSupportColor      = clrLimeGreen;  // Support Color

//============================================================================
// STRUCTURES
//============================================================================
struct STrendLine
{
   int      bar1;
   double   price1;
   int      bar2;
   double   price2;
   int      touches;
   bool     isResistance;
   double   slope;
   double   intercept;
   double   angle;
   string   objectName;
   bool     filtered;

   STrendLine() : bar1(0), price1(0), bar2(0), price2(0),
                  touches(0), isResistance(false), slope(0),
                  intercept(0), angle(0), objectName(""), filtered(false) {}
};

//============================================================================
// GLOBAL VARIABLES
//============================================================================
STrendLine g_lines[];
int        g_totalLines = 0;
datetime   g_lastBarTime = 0;
double     g_pipValue = 0;
int        g_atrHandle = INVALID_HANDLE;

//============================================================================
// INITIALIZATION
//============================================================================
int OnInit()
{
   if(InpLookback < 10)
   {
      Print("ERROR: Lookback must be >= 10");
      return(INIT_PARAMETERS_INCORRECT);
   }

   if(InpMinTouches < 2)
   {
      Print("ERROR: MinTouches must be >= 2");
      return(INIT_PARAMETERS_INCORRECT);
   }

   if(InpMaxLinesToShow < 1)
   {
      Print("ERROR: MaxLinesToShow must be >= 1");
      return(INIT_PARAMETERS_INCORRECT);
   }

   if(InpMinBarsBetween < 1)
   {
      Print("ERROR: MinBarsBetween must be >= 1");
      return(INIT_PARAMETERS_INCORRECT);
   }

   // v2.4.2 - Neue Validierung
   if(InpMinBarsBetweenTouches < 0)
   {
      Print("ERROR: MinBarsBetweenTouches must be >= 0");
      return(INIT_PARAMETERS_INCORRECT);
   }

   // v2.4 - ATR Validierung
   if(InpUseATR)
   {
      if(InpATR_Period < 1)
      {
         Print("ERROR: ATR Period must be >= 1");
         return(INIT_PARAMETERS_INCORRECT);
      }

      if(InpATR_Multiplier <= 0)
      {
         Print("ERROR: ATR Multiplier must be > 0");
         return(INIT_PARAMETERS_INCORRECT);
      }

      g_atrHandle = iATR(_Symbol, _Period, InpATR_Period);
      if(g_atrHandle == INVALID_HANDLE)
      {
         Print("ERROR: Failed to create ATR indicator handle");
         return(INIT_FAILED);
      }

      Print("ATR-based adaptive tolerance ENABLED (Period: ", InpATR_Period,
            ", Multiplier: ", InpATR_Multiplier, ")");
   }
   else
   {
      Print("Fixed pip-based tolerance (", InpTouchTolerancePips, " pips)");
   }

   if(!InpDiagonalMode)
   {
      Print("Diagonal Mode disabled");
      return(INIT_SUCCEEDED);
   }

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   g_pipValue = (digits == 3 || digits == 5) ? _Point * 10 : _Point;

   Print("DiagonalTrendFinder v2.4.2 (BUGFIX) initialized - Pip value: ", g_pipValue);

   CleanupAllObjects();
   return(INIT_SUCCEEDED);
}

//============================================================================
// DEINITIALIZATION
//============================================================================
void OnDeinit(const int reason)
{
   CleanupAllObjects();
   ArrayFree(g_lines);

   if(g_atrHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_atrHandle);
      g_atrHandle = INVALID_HANDLE;
   }
}

//============================================================================
// MAIN CALCULATION
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
   if(!InpDiagonalMode) return(rates_total);
   if(rates_total < 20) return(rates_total);

   if(rates_total > 0 && time[rates_total-1] != g_lastBarTime)
   {
      g_lastBarTime = time[rates_total-1];
      PerformFullScan(rates_total, time, high, low, close);
   }

   return(rates_total);
}

//============================================================================
// CORE SCANNING LOGIC
//============================================================================
void PerformFullScan(const int rates_total,
                     const datetime &time[],
                     const double &high[],
                     const double &low[],
                     const double &close[])
{
   CleanupAllObjects();
   ArrayResize(g_lines, 0);
   g_totalLines = 0;

   int lookbackBars = MathMin(InpLookback, rates_total - 1);
   int startBar = rates_total - lookbackBars;

   if(lookbackBars < 10)
   {
      Print("Not enough bars for analysis");
      return;
   }

   int resistancePivots[];
   int supportPivots[];
   FindPivotPoints(startBar, rates_total, high, low, resistancePivots, supportPivots);

   ScanLinesBetweenPivots(resistancePivots, high, low, close, rates_total, startBar, true);
   ScanLinesBetweenPivots(supportPivots, low, high, close, rates_total, startBar, false);

   SortLinesByQuality();

   if(InpEnableOverlapFilter)
   {
      FilterSimilarLines();
   }

   DrawTopLines(time, rates_total);

   int displayedLines = 0;
   for(int i = 0; i < g_totalLines; i++)
   {
      if(!g_lines[i].filtered) displayedLines++;
   }

   Print("Scan completed: ", g_totalLines, " lines found, ", displayedLines, " displayed after filter");
}

//============================================================================
// PIVOT POINT DETECTION
//============================================================================
void FindPivotPoints(const int startBar, const int endBar,
                     const double &high[], const double &low[],
                     int &resistancePivots[], int &supportPivots[])
{
   ArrayResize(resistancePivots, 0);
   ArrayResize(supportPivots, 0);

   int minBars = InpMinBarsBetween;

   for(int i = startBar + minBars; i < endBar - minBars; i++)
   {
      bool isResistancePivot = true;
      for(int j = 1; j <= minBars; j++)
      {
         if(high[i] <= high[i-j] || high[i] <= high[i+j])
         {
            isResistancePivot = false;
            break;
         }
      }

      if(isResistancePivot)
      {
         int size = ArraySize(resistancePivots);
         ArrayResize(resistancePivots, size + 1);
         resistancePivots[size] = i;
      }

      bool isSupportPivot = true;
      for(int j = 1; j <= minBars; j++)
      {
         if(low[i] >= low[i-j] || low[i] >= low[i+j])
         {
            isSupportPivot = false;
            break;
         }
      }

      if(isSupportPivot)
      {
         int size = ArraySize(supportPivots);
         ArrayResize(supportPivots, size + 1);
         supportPivots[size] = i;
      }
   }
}

//============================================================================
// SCAN LINES BETWEEN PIVOT POINTS
//============================================================================
void ScanLinesBetweenPivots(const int &pivots[],
                            const double &mainPrices[],
                            const double &oppositePrices[],
                            const double &bodyPrices[],
                            const int rates_total,
                            const int startBar,
                            const bool isResistance)
{
   int pivotCount = ArraySize(pivots);
   if(pivotCount < 2) return;

   for(int i = 0; i < pivotCount - 1; i++)
   {
      for(int j = i + 1; j < pivotCount; j++)
      {
         int bar1 = pivots[i];
         int bar2 = pivots[j];

         // v2.4.2 FIX: Division-by-Zero Schutz
         if(bar1 == bar2) continue;

         double price1 = mainPrices[bar1];
         double price2 = mainPrices[bar2];

         if(MathAbs(price1 - price2) < g_pipValue * 2) continue;

         int touches = CountLineTouches(bar1, price1, bar2, price2,
                                       mainPrices, oppositePrices, bodyPrices,
                                       rates_total, startBar, isResistance);

         if(touches >= InpMinTouches)
         {
            AddLine(bar1, price1, bar2, price2, touches, isResistance);
         }
      }
   }
}

//============================================================================
// COUNT TOUCHES (v2.4.2 - BUGFIXES ANGEWENDET)
//============================================================================
int CountLineTouches(const int bar1, const double price1,
                     const int bar2, const double price2,
                     const double &mainPrices[],
                     const double &oppositePrices[],
                     const double &bodyPrices[],
                     const int rates_total,
                     const int startBar,
                     const bool isResistance)
{
   int touches = 0;

   // v2.4.2 FIX: Division-by-Zero Schutz
   if(bar2 == bar1)
   {
      Print("WARNING: bar1 == bar2, cannot calculate slope");
      return 0;
   }

   double m = (price2 - price1) / (double)(bar2 - bar1);
   double b = price1 - m * bar1;

   // v2.4.2 FIX #1: ATR Buffer korrekt behandeln
   double atrBuffer[];
   bool useATR = InpUseATR && (g_atrHandle != INVALID_HANDLE);

   if(useATR)
   {
      int copied = CopyBuffer(g_atrHandle, 0, 0, rates_total, atrBuffer);

      // v2.4.2 FIX: Array-Bounds Check
      if(copied < rates_total || ArraySize(atrBuffer) == 0)
      {
         Print("WARNING: Failed to copy full ATR buffer (copied: ", copied,
               " of ", rates_total, "), using fixed tolerance");
         useATR = false;
      }
      // KEIN ArraySetAsSeries - wir indizieren manuell
   }

   int checkBars = MathMin(bar2 + 100, rates_total - 1);
   int loopStart = MathMax(bar1, startBar);

   // v2.4.2 FIX #2: Touch-Counting mit MinBarsBetween
   int lastTouchBar = -999;  // Initialisierung weit in der Vergangenheit

   for(int bar = loopStart; bar < checkBars; bar++)
   {
      double expectedPrice = m * bar + b;

      // v2.4.2: Dynamische Toleranz berechnen
      double tolerance;
      if(useATR)
      {
         // v2.4.2 FIX #1 KRITISCH: Korrekte ATR-Indexierung
         // CopyBuffer ohne ArraySetAsSeries: Index 0 = älteste Bar
         // Chart-Index 'bar' läuft von 0 (alt) bis rates_total-1 (neu)
         // atrBuffer ist gleichlaufend indiziert → direkter Zugriff

         // v2.4.2 FIX: Bounds-Check
         if(bar >= 0 && bar < ArraySize(atrBuffer))
         {
            tolerance = atrBuffer[bar] * InpATR_Multiplier;

            // Sicherheitscheck: ATR = 0 (Datenlücke/stiller Markt)
            if(tolerance <= 0)
            {
               tolerance = g_pipValue * InpTouchTolerancePips;
            }
         }
         else
         {
            tolerance = g_pipValue * InpTouchTolerancePips;
         }
      }
      else
      {
         tolerance = g_pipValue * InpTouchTolerancePips;
      }

      double priceToCheck = InpUseWickTouches ? mainPrices[bar] : bodyPrices[bar];
      bool touched = (MathAbs(priceToCheck - expectedPrice) <= tolerance);

      // v2.4.2 FIX #2: Nur isolierte Touches zählen
      if(touched && (bar - lastTouchBar > InpMinBarsBetweenTouches))
      {
         touches++;
         lastTouchBar = bar;
      }
   }

   return touches;
}

//============================================================================
// ADD LINE TO ARRAY
//============================================================================
void AddLine(const int bar1, const double price1,
             const int bar2, const double price2,
             const int touches, const bool isResistance)
{
   g_totalLines++;
   ArrayResize(g_lines, g_totalLines);

   int idx = g_totalLines - 1;

   g_lines[idx].bar1 = bar1;
   g_lines[idx].price1 = price1;
   g_lines[idx].bar2 = bar2;
   g_lines[idx].price2 = price2;
   g_lines[idx].touches = touches;
   g_lines[idx].isResistance = isResistance;

   g_lines[idx].slope = (price2 - price1) / (bar2 - bar1);
   g_lines[idx].intercept = price1 - g_lines[idx].slope * bar1;
   g_lines[idx].angle = MathArctan(g_lines[idx].slope) * 180.0 / M_PI;

   g_lines[idx].objectName = "DiagTrend_" + IntegerToString(idx);
   g_lines[idx].filtered = false;
}

//============================================================================
// SORT LINES BY QUALITY
//============================================================================
void SortLinesByQuality()
{
   if(g_totalLines <= 1) return;

   for(int i = 0; i < g_totalLines - 1; i++)
   {
      int maxIdx = i;
      for(int j = i + 1; j < g_totalLines; j++)
      {
         if(g_lines[j].touches > g_lines[maxIdx].touches)
         {
            maxIdx = j;
         }
      }

      if(maxIdx != i)
      {
         STrendLine temp = g_lines[i];
         g_lines[i] = g_lines[maxIdx];
         g_lines[maxIdx] = temp;
      }
   }
}

//============================================================================
// FILTER SIMILAR LINES
//============================================================================
void FilterSimilarLines()
{
   int acceptedCount = 0;

   for(int i = 0; i < g_totalLines; i++)
   {
      if(g_lines[i].filtered) continue;

      bool isSimilar = false;

      for(int j = 0; j < i; j++)
      {
         if(g_lines[j].filtered) continue;

         if(AreLinesSimilar(g_lines[i], g_lines[j]))
         {
            isSimilar = true;
            break;
         }
      }

      if(isSimilar)
      {
         g_lines[i].filtered = true;
      }
      else
      {
         acceptedCount++;
         if(acceptedCount >= InpMaxLinesToShow)
         {
            for(int k = i + 1; k < g_totalLines; k++)
            {
               g_lines[k].filtered = true;
            }
            break;
         }
      }
   }
}

//============================================================================
// CHECK IF TWO LINES ARE SIMILAR
//============================================================================
bool AreLinesSimilar(STrendLine &line1, STrendLine &line2)
{
   double angleDiff = MathAbs(line1.angle - line2.angle);

   if(angleDiff >= InpMinAngleDiff)
      return false;

   int midBar1 = (line1.bar1 + line1.bar2) / 2;
   int midBar2 = (line2.bar1 + line2.bar2) / 2;
   int midBar = (midBar1 + midBar2) / 2;

   double price1_at_mid = line1.slope * midBar + line1.intercept;
   double price2_at_mid = line2.slope * midBar + line2.intercept;

   double distance = MathAbs(price1_at_mid - price2_at_mid);

   if(distance >= InpMinDistancePips * g_pipValue)
      return false;

   int overlap_start = MathMax(line1.bar1, line2.bar1);
   int overlap_end = MathMin(line1.bar2, line2.bar2);

   if(overlap_end <= overlap_start)
      return false;

   int overlap_bars = overlap_end - overlap_start;
   int range1 = line1.bar2 - line1.bar1;
   int range2 = line2.bar2 - line2.bar2;
   double avg_range = (range1 + range2) / 2.0;

   if(avg_range == 0) return true;

   double overlap_percent = (overlap_bars / avg_range) * 100.0;

   if(overlap_percent < InpMaxOverlapPercent)
      return false;

   return true;
}

//============================================================================
// DRAW TOP LINES ON CHART
//============================================================================
void DrawTopLines(const datetime &time[], const int rates_total)
{
   int linesDrawn = 0;

   for(int i = 0; i < g_totalLines; i++)
   {
      if(!g_lines[i].filtered)
      {
         DrawSingleLine(g_lines[i], time, rates_total);
         linesDrawn++;
      }
   }

   ChartRedraw();
}

//============================================================================
// DRAW SINGLE TRENDLINE
//============================================================================
void DrawSingleLine(STrendLine &line, const datetime &time[], const int rates_total)
{
   string objName = line.objectName;

   if(line.bar1 < 0 || line.bar2 < 0 || line.bar1 >= rates_total || line.bar2 >= rates_total)
   {
      Print("Invalid bar indices for line: ", objName);
      return;
   }

   datetime t1 = time[line.bar1];
   datetime t2 = time[line.bar2];

   if(!ObjectCreate(0, objName, OBJ_TREND, 0, t1, line.price1, t2, line.price2))
   {
      int error = GetLastError();
      if(error != 4200)
         Print("ObjectCreate failed: ", error, " for ", objName);

      ObjectSetInteger(0, objName, OBJPROP_TIME, 0, t1);
      ObjectSetDouble(0, objName, OBJPROP_PRICE, 0, line.price1);
      ObjectSetInteger(0, objName, OBJPROP_TIME, 1, t2);
      ObjectSetDouble(0, objName, OBJPROP_PRICE, 1, line.price2);
   }

   ObjectSetInteger(0, objName, OBJPROP_COLOR,
                    line.isResistance ? InpResistanceColor : InpSupportColor);
   ObjectSetInteger(0, objName, OBJPROP_WIDTH, InpLineWidth);
   ObjectSetInteger(0, objName, OBJPROP_BACK, true);
   ObjectSetInteger(0, objName, OBJPROP_RAY_RIGHT, true);
   ObjectSetInteger(0, objName, OBJPROP_SELECTABLE, true);

   if(InpShowLabels)
   {
      datetime labelTime = t2 + PeriodSeconds(_Period) * InpExtendBars;
      double labelPrice = line.price2 + line.slope * InpExtendBars;
      DrawLineLabel(line, labelTime, labelPrice);
   }
}

//============================================================================
// DRAW LABEL FOR LINE
//============================================================================
void DrawLineLabel(STrendLine &line, const datetime labelTime, double labelPrice)
{
   string labelName = line.objectName + "_Label";

   labelPrice += (line.isResistance ? g_pipValue * 20 : -g_pipValue * 20);

   if(!ObjectCreate(0, labelName, OBJ_TEXT, 0, labelTime, labelPrice))
   {
      ObjectSetInteger(0, labelName, OBJPROP_TIME, 0, labelTime);
      ObjectSetDouble(0, labelName, OBJPROP_PRICE, 0, labelPrice);
   }

   ObjectSetString(0, labelName, OBJPROP_TEXT, "T:" + IntegerToString(line.touches));
   ObjectSetInteger(0, labelName, OBJPROP_COLOR,
                    line.isResistance ? InpResistanceColor : InpSupportColor);
   ObjectSetInteger(0, labelName, OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, labelName, OBJPROP_BACK, true);
   ObjectSetInteger(0, labelName, OBJPROP_ANCHOR, ANCHOR_LEFT);
}

//============================================================================
// CLEANUP ALL OBJECTS
//============================================================================
void CleanupAllObjects()
{
   ObjectsDeleteAll(0, -1, OBJ_TREND);
   ObjectsDeleteAll(0, -1, OBJ_TEXT);
   ChartRedraw();
}
//+------------------------------------------------------------------+
