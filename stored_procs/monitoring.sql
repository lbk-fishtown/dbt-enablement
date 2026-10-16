USE [Monitoring]
GO
 
 
SET ANSI_NULLS ON
GO
 
SET QUOTED_IDENTIFIER ON
GO
 
 
 
 
 
 
 
 
 
 
 
 
 
 
--------------------------------------------------------------------------
CREATE OR ALTER               PROCEDURE  [dbo].[sp_DataCurrencyHistory_Detailed]
 
(
@RebuildAllDays VARCHAR(3) = 'No',
@BuildMissingDate DATE = NULL
)
 
AS
 
BEGIN
 
 
-- Used for DataCurrencyTolerance - Number of hours before the expected run time used for the Data Currency check.
-- Records within @Tolerance_Verify are flagged for Verify; records outside it are flagged for Assess.
-- Records within @Tolerance_OK are flagged as OK
DECLARE @Tolerance_Verify INT = 3;  -- Hours
DECLARE @Tolerance_OK INT = 30; -- Minutes
 
 
/* Join the Data Currency table to the reference table to establish at approx what time data should be up to */
 
DROP TABLE IF EXISTS #DataCurrencyHistory_2;
 
 
    WITH DataCurrencyHistory_CTE AS (
 
    SELECT
               COALESCE(DCH.ServerName,DCRT.[Server]) AS ServerName
              ,DCRT.DbName
              ,DCRT.[Schema]
              ,DCRT.TableName
              ,DCRT.ColumnChecked AS ColumnName
              ,CASE WHEN DCH.DataAsAt IS NULL
                        THEN '1900-01-01 00:00:00.000'
                    WHEN DCRT.RequiresUTCAdjustment = 'Y' AND DCH.DataAsAt <> '1900-01-01 00:00:00.000' -- AND DCH.DataAsAt IS NOT NULL
                        THEN CAST(DCH.DataAsAt AT TIME ZONE 'UTC' AT TIME ZONE 'New Zealand Standard Time' AS DATETIME2(7))
                    ELSE DCH.DataAsAt
                    END AS  DataAsAt
              ,DCH.CheckedOn
              ,ISNULL(DCH.RowCounts,0)     AS RowCounts
              ,DCRT.RowCheck
              ,DCRT.ExptdRun_DaysPrior
              ,CASE WHEN DCRT.DataTiming LIKE '%Real%'
                        THEN DATETIMEFROMPARTS(1900, 1, 1,DATEPART(HOUR, DCH.CheckedOn),DATEPART(MINUTE, DCH.CheckedOn),0, 0)
                    ELSE DCRT.ExptdRun_LatestTime
                    END AS ExptdRun_LatestTime
 
 
-- Calculate the earliest acceptable expected run datetime
,DATEADD
(
    MINUTE,
 
    -- Subtract the acceptable lag (in minutes)
    -DATEDIFF(MINUTE, 0, DCRT.ExptdRun_AcceptableLagMins),
 
    -----------------------------------------------------------------------
    -- Build the expected run datetime
    -----------------------------------------------------------------------
                (
                    DATEADD
                    (
                        DAY,
 
                        -(
                            DCRT.ExptdRun_DaysPrior
 
                            + CASE
 
                                -- Business-hours data:
                                -- If no days-prior offset is configured, expect data
                                -- by 5pm on the previous day.
                                WHEN DCRT.DataEntryUsuallyBusHrs = 'Y'
                                     AND DCRT.ExptdRun_DaysPrior = 0
                                    THEN 1
 
                                -- Additional adjustment for Monday processing
                                -- when a job does not run on Sunday
                                WHEN DCRT.RunsSunday = 'N'
                                     AND DATEPART(dw, DCH.CheckedOn) = 2
                                     AND DCRT.DataTiming NOT LIKE '%Real%'
                                    THEN 1
 
                                ELSE 0
 
                              END
                        ),
 
                        -- CheckedOn date with time removed (00:00:00)
                        CONVERT(DATETIME, CONVERT(DATE, DCH.CheckedOn))
                    )
 
                    +
 
                    -------------------------------------------------------------------
                    -- Add the expected run time
                    -------------------------------------------------------------------
                    CAST
                    (
                        CASE
 
                            -- Business-hours data is expected by 5:00 PM
                            WHEN DCRT.DataEntryUsuallyBusHrs = 'Y'
                                THEN '17:00:00'
 
                            -- Real-time data uses the actual CheckedOn time
                            WHEN DCRT.DataTiming LIKE '%Real%'
                                THEN CAST(DCH.CheckedOn AS TIME)
 
                            -- Otherwise use the configured latest expected run time
                            ELSE CAST(DCRT.ExptdRun_LatestTime AS TIME)
 
                        END
                        AS DATETIME
                    )
                )
 
            ) AS ExptdRun_DateTimeMin
           
              ,DCRT.DataTiming      
              ,DCRT.RunsSunday
              ,DCRT.DataEntryUsuallyBusHrs
 
 
-----
        ,(
                DATEADD
                (
                    DAY,
 
                    -(
                        DCRT.ExptdRun_DaysPrior
 
                        + CASE
 
                            WHEN DCRT.RunsSunday = 'N'
                                    AND DATEPART(dw, DCH.CheckedOn) = 2
                                    AND DCRT.DataTiming NOT LIKE '%Real%'
                                THEN 1
 
                            ELSE 0
                            END
                    ),
 
                    CONVERT(DATETIME, CONVERT(DATE, DCH.CheckedOn))
                )
 
                +
 
                CAST
                (
                    CASE
                        WHEN DCRT.DataTiming LIKE '%Real%'
                            THEN CAST(DCH.CheckedOn AS TIME)
 
                        ELSE CAST(DCRT.ExptdRun_LatestTime AS TIME)
 
                    END
                    AS DATETIME
                )
            ) AS Job_1_ExptdRunStart_DateTime
 
--------------------
 
 
              ,DCRT.JobName_1
              ,DCRT.JobType_1
              ,DCRT.JobName_2
              ,DCRT.JobType_2
              ,DCRT.ExptdRun_AcceptableLagMins
 
        FROM dbo.DataCurrencyHistory DCH
        INNER JOIN reference.DataCurrencyReferenceTable DCRT ON DCH.DbName = DCRT.DbName
        AND  DCH.[Schema] = DCRT.[Schema]
        AND  DCH.TableName = DCRT.TableName
        WHERE CONVERT(DATE,DCH.CheckedOn) BETWEEN DCRT.ExptdRun_ScheduleStart AND DCRT.ExptdRun_ScheduleEnd
              AND
                (  --Rebuild the lot
                   @RebuildAllDays = 'Yes'
                   --Today
                OR
                CONVERT(DATE, DCH.CheckedOn) = CONVERT(DATE, GETDATE())
                   --Build a missing date
                OR (
                       @BuildMissingDate IS NOT NULL
                   AND CONVERT(DATE, DCH.CheckedOn) = @BuildMissingDate
                   )
            )
 
)
 
        SELECT DCH.ServerName
              ,DCH.DbName
              ,DCH.[Schema]
              ,DCH.TableName
              ,DCH.ColumnName
              ,DCH.DataAsAt
              ,DCH.CheckedOn
              ,CONVERT(DATE,DCH.DataAsAt)  AS DataAsAt_Date
              ,CONVERT(TIME,DCH.DataAsAt)  AS DataAsAt_Time
              ,CONVERT(DATE,DCH.CheckedOn) AS CheckedOn_Date
              ,CONVERT(TIME,DCH.CheckedOn) AS CheckedOn_Time
              ,ISNULL(DCH.RowCounts,0)     AS RowCounts
              ,DCH.RowCheck
              ,DCH.ExptdRun_DaysPrior
              ,DCH.ExptdRun_LatestTime
              ,DCH.ExptdRun_DateTimeMin
              ,DCH.DataTiming
              ,DCH.RunsSunday
              ,DCH.DataEntryUsuallyBusHrs
              ,DCH.Job_1_ExptdRunStart_DateTime
              ,DCH.JobName_1
              ,DCH.JobType_1
              ,DCH.JobName_2
              ,DCH.JobType_2
             -- ,CASE WHEN DCH.ExptdRun_DaysPrior = -100 OR DataAsAt = '1900-01-01 00:00:00.000' THEN 'DataAsAt Unavailable'
                --  WHEN DATEADD(HOUR, -@Tolerance_Verify, DCH.ExptdRun_DateTimeMin) > DCH.DataAsAt THEN 'DataAsAt > Tolerance'
                --  WHEN (DATEADD(HOUR, -@Tolerance_Verify, DCH.ExptdRun_DateTimeMin) <= DCH.DataAsAt ) AND
                --   (DCH.DataAsAt < DCH.ExptdRun_DateTimeMin ) THEN 'DataAsAt <= Tolerance'
                --  ELSE 'DataAsAt OK'
                --END AS DataCurrencyCheck
                ,CASE
                        WHEN DCH.ExptdRun_DaysPrior = -100
                             OR DataAsAt = '1900-01-01 00:00:00.000'
                            THEN 'DataAsAt Unavailable'
                       
                        -- Above Tolerance_Verify level
                        WHEN DATEADD(HOUR, -@Tolerance_Verify, DCH.ExptdRun_DateTimeMin) > DCH.DataAsAt
                            THEN 'DataAsAt > Tolerance'
 
                        -- Between Tolerance_Verify and @Tolerance_OK
                        WHEN DCH.DataAsAt <
                             DATEADD(MINUTE, -@Tolerance_OK, DCH.ExptdRun_DateTimeMin)
                            THEN 'DataAsAt <= Tolerance'
 
                        -- Within @Tolerance_OK
                        ELSE 'DataAsAt OK'
 
                     END AS DataCurrencyCheck
 
        INTO   #DataCurrencyHistory_2
 
        FROM DataCurrencyHistory_CTE DCH
 
 -------------------------------------------------------------------------------------------------------------------------------------------------------------------------
 
-------------------------------------------------------------------------------------------------------------------------------------------------------------------------
 
/* Find the maximum row count for the table, within the last 30 days*/
 
DROP TABLE IF EXISTS #DataCurrencyHistory_RowCount_1
   
        SELECT   DCH_2.DbName
                ,DCH_2.[Schema]
                ,DCH_2.TableName
                ,DCH_2.CheckedOn
                ,MAX(DCH.RowCounts) AS MaxRowCount_30Days
   
        INTO    #DataCurrencyHistory_RowCount_1
 
        FROM    DataCurrencyHistory DCH
                INNER JOIN #DataCurrencyHistory_2 DCH_2 ON DCH.DbName = DCH_2.DbName
                           AND DCH.[Schema] = DCH_2.[Schema]
                           AND  DCH.TableName = DCH_2.TableName
       
        WHERE   DATEDIFF(DAY,CONVERT(DATE,DCH.CheckedOn),DCH_2.CheckedOn_Date) < 30
                AND DCH.CheckedOn < DCH_2.CheckedOn  --Just previous days
                --AND CONVERT(DATE,DCH.CheckedOn) < DCH_2.CheckedOn_Date  --If re-run the same day, dont consider today
 
        GROUP BY   DCH_2.DbName
                  ,DCH_2.[Schema]
                  ,DCH_2.TableName
                  ,DCH_2.CheckedOn
 
 
--  SELECT * FROM #DataCurrencyHistory_RowCount_1
 
-------------------------------------------------------------------------------------------------------------------------------------------------------------------------
 
/* Find the date that the previous max row count occured, ensuring that if a similar value has occured after the CheckedOn_Date, the value prior to that date is returned */
       
DROP TABLE IF EXISTS #DataCurrencyHistory_RowCount_2
 
        SELECT     DCH_RC1.DbName
                  ,DCH_RC1.[Schema]
                  ,DCH_RC1.TableName
                  ,DCH_RC1.MaxRowCount_30Days
                  ,DCH_RC1.CheckedOn
                  ,MAX(DCH.CheckedOn) AS MaxRowCount_CheckedOn
                  --,MAX(CONVERT(DATE,DCH.CheckedOn)) AS MaxRowCount_CheckedOn
   
        INTO      #DataCurrencyHistory_RowCount_2
 
        FROM      #DataCurrencyHistory_RowCount_1 DCH_RC1
                  INNER JOIN DataCurrencyHistory DCH ON DCH_RC1.DbName = DCH.DbName
                             AND DCH_RC1.[Schema] = DCH.[Schema]
                             AND DCH_RC1.TableName = DCH.TableName
                             AND DCH_RC1.MaxRowCount_30Days = DCH.RowCounts
       
        --WHERE    CONVERT(DATE,DCH.CheckedOn) < CONVERT(DATE,DCH_RC1.CheckedOn) --Just previous dates
        WHERE      DCH.CheckedOn < DCH_RC1.CheckedOn --If re-run the same day, dont consider today
        GROUP BY   DCH_RC1.DbName
                  ,DCH_RC1.[Schema]
                  ,DCH_RC1.TableName
                  ,DCH_RC1.CheckedOn
                  ,DCH_RC1.MaxRowCount_30Days
 
 
DROP TABLE #DataCurrencyHistory_RowCount_1
 
 
-------------------------------------------------------------------------------------------------------------------------------------------------------------------------
   
/* Based on the previous max row count, check whether the current row count has increased, which would be expected (Unless somehow the source table has duplicate entries - which would be another issue) */
 
DROP TABLE IF EXISTS #DataCurrencyHistory_4
 
        SELECT    DCH_2.*
                  ,CASE
                        WHEN RowCheck = 'Can Decrease'  OR  MaxRowCount_CheckedOn IS NULL   THEN 'Row Count Can Decrease Or N/A'
                        WHEN MaxRowCount_30Days > RowCounts THEN 'Row Count Less Than Expected'
                        WHEN MaxRowCount_30Days = RowCounts THEN 'Row Count Same As 30 Day Max'
                        ELSE 'Row Count Has Increased'
                        END AS RowCountCheck
                  ,ISNULL(MaxRowCount_30Days,0) AS MaxRowCount_30Days
                  ,ISNULL(MaxRowCount_CheckedOn,'1900-01-01') AS MaxRowCount_CheckedOn
   
        INTO      #DataCurrencyHistory_4
   
        FROM      #DataCurrencyHistory_2 DCH_2
        LEFT JOIN #DataCurrencyHistory_RowCount_2 DCH_R2 ON DCH_2.DbName = DCH_R2.DbName
                  AND DCH_2.[Schema] = DCH_R2.[Schema]
                  AND DCH_2.TableName = DCH_R2.TableName
                  AND DCH_2.CheckedOn = DCH_R2.CheckedOn
 
               
--Select * FROM #DataCurrencyHistory_4 ORDER BY CheckedOn_Date desc
 
DROP TABLE #DataCurrencyHistory_RowCount_2
DROP TABLE #DataCurrencyHistory_2
 
 
-------------------------------------------------------------------------------------------------------------------------------------------
 
/* Add todays data to the history table that holds the details*/
 
 
-- If rebuilding, truncate the table first
IF @RebuildAllDays = 'Yes'
    TRUNCATE TABLE dbo.DataCurrencyHistory_Detailed;
 
-- This ALWAYS runs
INSERT INTO dbo.DataCurrencyHistory_Detailed
(
    ServerName,
    DbName,
    [Schema],
    TableName,
    ColumnName,
    DataAsAt,
    CheckedOn,
    DataAsAt_Date,
    DataAsAt_Time,
    CheckedOn_Date,
    CheckedOn_Time,
    RowCounts,
    RowCheck,
    ExptdRun_DaysPrior,
    ExptdRun_LatestTime,
    ExptdRun_DateTimeMin,
    DataCurrencyCheck,
    Tolerance_Verify,
    Tolerance_OK,
    RowCountCheck,
    MaxRowCount_30Days,
    MaxRowCount_CheckedOn,
    DataTiming,
    RunsSunday,
    DataEntryUsuallyBusHrs,
    Job_1_ExptdRunStart_DateTime,
    JobName_1,
    JobType_1,
    JobName_2,
    JobType_2
)
SELECT ServerName,
       DbName,
       [Schema],
       TableName,
       ColumnName,
       DataAsAt,
       CheckedOn,
       DataAsAt_Date,
       DataAsAt_Time,
       CheckedOn_Date,
       CheckedOn_Time,
       RowCounts,
       RowCheck,
       ExptdRun_DaysPrior,
       ExptdRun_LatestTime,
       ExptdRun_DateTimeMin,
       DataCurrencyCheck,
       @Tolerance_Verify,
       @Tolerance_OK,
       RowCountCheck,
       MaxRowCount_30Days,
       MaxRowCount_CheckedOn,
       DataTiming,
       RunsSunday,
       DataEntryUsuallyBusHrs,
       Job_1_ExptdRunStart_DateTime,
       JobName_1,
       JobType_1,
       JobName_2,
       JobType_2
FROM #DataCurrencyHistory_4 DCH_4
WHERE NOT EXISTS
(
    SELECT *
    FROM dbo.DataCurrencyHistory_Detailed DCH_D
    -- unique keys
    WHERE DCH_4.DbName = DCH_D.DbName
          AND DCH_4.[Schema] = DCH_4.[Schema]
          AND DCH_4.TableName = DCH_D.TableName
          AND DCH_4.CheckedOn = DCH_D.CheckedOn
);
 
DROP TABLE #DataCurrencyHistory_4
 
 
 
-------------------------------------------------------------------------------------------------------------------------------------------
 
 
END
 
 
GO