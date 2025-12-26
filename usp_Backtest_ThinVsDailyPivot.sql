CREATE PROC usp_Backtest_ThinVsDailyPivot
    @days_back   int = 30,
    @bucket_mins int = 15
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @start_dt datetime, @end_dt datetime;
    SET @start_dt = DATEADD(day, -@days_back, GETDATE());
    SET @end_dt   = GETDATE();

    /* 1) Pull candidate alerts (thin / low volume) */
    ;WITH a AS (
        SELECT
            aa.Stock,
            aa.AlertTime,
            aa.Price,
            CAST(aa.RSI AS float) AS RSI,
            aa.Setup,
            DATEADD(minute, (DATEDIFF(minute,0,aa.AlertTime)/@bucket_mins)*@bucket_mins, 0) AS TimeBucket,
            CAST(aa.AlertTime AS date) AS TradeDate
        FROM risk..alertsarchive2 aa
        WHERE aa.AlertTime >= @start_dt
          AND aa.AlertTime <  @end_dt
          AND (aa.Setup LIKE '%thin%' OR aa.Setup LIKE '%low volume%')
          AND aa.Stock IN ('Ger30','NAS100','SPX500','US2000','US30','USOIL','xAUusd')
    ),

    /* 2) Build daily OHLC from alertsarchive2 itself (approximation):
          Open = first price of day, Close = last price of day,
          High/Low = max/min of day.
          NOTE: this is "alert-print OHLC", not perfect market OHLC, but works for backtesting your alert stream.
    */
    daily AS (
        SELECT
            aa.Stock,
            CAST(aa.AlertTime AS date) AS TradeDate,
            MIN(aa.Price) AS DayLow,
            MAX(aa.Price) AS DayHigh
        FROM risk..alertsarchive2 aa
        WHERE aa.AlertTime >= DATEADD(day, -(@days_back+2), @start_dt)
          AND aa.AlertTime <  @end_dt
          AND aa.Stock IN ('Ger30','NAS100','SPX500','US2000','US30','USOIL','xAUusd')
        GROUP BY aa.Stock, CAST(aa.AlertTime AS date)
    ),

    /* 3) Open/Close using APPLY (SQL 2008-friendly) */
    daily_oc AS (
        SELECT
            d.Stock,
            d.TradeDate,
            d.DayHigh,
            d.DayLow,
            o.OpenPx,
            c.ClosePx
        FROM daily d
        OUTER APPLY (
            SELECT TOP 1 aa.Price AS OpenPx
            FROM risk..alertsarchive2 aa
            WHERE aa.Stock = d.Stock
              AND CAST(aa.AlertTime AS date) = d.TradeDate
            ORDER BY aa.AlertTime ASC
        ) o
        OUTER APPLY (
            SELECT TOP 1 aa.Price AS ClosePx
            FROM risk..alertsarchive2 aa
            WHERE aa.Stock = d.Stock
              AND CAST(aa.AlertTime AS date) = d.TradeDate
            ORDER BY aa.AlertTime DESC
        ) c
    ),

    /* 4) Prior-day pivots for each alert day */
    piv AS (
        SELECT
            cur.Stock,
            cur.TradeDate,
            prev.DayHigh AS PrevHigh,
            prev.DayLow  AS PrevLow,
            prev.ClosePx AS PrevClose,

            /* Classic pivots from prior day */
            (prev.DayHigh + prev.DayLow + prev.ClosePx) / 3.0 AS DP,
            (2.0 * ((prev.DayHigh + prev.DayLow + prev.ClosePx) / 3.0)) - prev.DayLow  AS R1,
            (2.0 * ((prev.DayHigh + prev.DayLow + prev.ClosePx) / 3.0)) - prev.DayHigh AS S1
        FROM (SELECT DISTINCT Stock, TradeDate FROM a) cur
        OUTER APPLY (
            SELECT TOP 1 *
            FROM daily_oc d2
            WHERE d2.Stock = cur.Stock
              AND d2.TradeDate < cur.TradeDate
            ORDER BY d2.TradeDate DESC
        ) prev
    )

    /* 5) Final backtest-friendly output: alert vs pivot distance + side of pivot */
    SELECT
        a.Stock,
        a.AlertTime,
        a.TimeBucket,
        a.Price,
        a.RSI,
        a.Setup,

        p.DP,
        p.R1,
        p.S1,

        (a.Price - p.DP) AS DistToDP_Pts,
        CASE
            WHEN p.DP IS NULL THEN NULL
            WHEN a.Price > p.DP THEN 'AboveDP'
            WHEN a.Price < p.DP THEN 'BelowDP'
            ELSE 'AtDP'
        END AS PxVsDP

    FROM a
    LEFT JOIN piv p
      ON p.Stock = a.Stock
     AND p.TradeDate = a.TradeDate

    ORDER BY a.Stock, a.AlertTime;
END
GO
