
-- View raw inpatient charge data 
SELECT *
FROM [Healthcare].[dbo].[inpatientCharges];

--Count total records in the dataset
SELECT COUNT(*) AS Total_Records
FROM [Healthcare].[dbo].[inpatientCharges];

--Check for invalid discharges and missing payments
SELECT
    SUM(CASE 
            WHEN Total_Discharges IS NULL OR Total_Discharges = 0 
            THEN 1 ELSE 0 
        END) AS Bad_Discharge_Records,
    SUM(CASE 
            WHEN Average_Total_Payments IS NULL 
            THEN 1 ELSE 0 
        END) AS Missing_Payments
FROM [Healthcare].[dbo].[inpatientCharges];

--Compare billed charges to actual payments by DRG
SELECT 
    DRG_Definition,
    AVG(CAST(Average_Covered_Charges AS MONEY)) AS Avg_Charges,
    AVG(CAST(Average_Total_Payments AS MONEY)) AS Avg_Payments,
    AVG(CAST(Average_Covered_Charges AS MONEY)) / 
        NULLIF(AVG(CAST(Average_Total_Payments AS MONEY)), 0)
        AS Charge_to_Payment_Ratio
FROM [Healthcare].[dbo].[inpatientCharges]
GROUP BY DRG_Definition
ORDER BY Charge_to_Payment_Ratio DESC;

--Calculate Medicare payments as a percent of total payments 
SELECT 
    Provider_Name,
    Provider_State,
    AVG(
        TRY_PARSE(Average_Medicare_Payments AS MONEY USING 'en-US') / 
        NULLIF(TRY_PARSE(Average_Total_Payments AS MONEY USING 'en-US'), 0)
    ) * 100 AS Medicare_Payment_Percent
FROM [Healthcare].[dbo].[inpatientCharges]
GROUP BY Provider_Name, Provider_State
ORDER BY Medicare_Payment_Percent DESC;

--Analyze payment and charge variation by state
SELECT 
    Provider_State,
    AVG(TRY_PARSE(Average_Total_Payments AS MONEY USING 'en-US')) AS Avg_Total_Payments,
    AVG(TRY_PARSE(Average_Covered_Charges AS MONEY USING 'en-US')) AS Avg_Covered_Charges
FROM [Healthcare].[dbo].[inpatientCharges]
GROUP BY Provider_State
ORDER BY Avg_Total_Payments DESC;

--Identify high-payment outliers within each DRG
WITH DRG_Stats AS (
    SELECT
        DRG_Definition,
        AVG(TRY_PARSE(Average_Total_Payments AS MONEY USING 'en-US')) AS Avg_Payment,
        STDEV(TRY_PARSE(Average_Total_Payments AS MONEY USING 'en-US')) AS StdDev_Payment
    FROM [Healthcare].[dbo].[inpatientCharges]
    GROUP BY DRG_Definition
)
SELECT
    i.Provider_Name,
    i.DRG_Definition,
    i.Average_Total_Payments,
    d.Avg_Payment,
    d.StdDev_Payment
FROM dbo.InpatientCharges i
JOIN DRG_Stats d
    ON i.DRG_Definition = d.DRG_Definition
WHERE 
    TRY_PARSE(i.Average_Total_Payments AS MONEY USING 'en-US') >
    (d.Avg_Payment + (2 * ISNULL(d.StdDev_Payment, 0)));


--Create cleaned, analysis-ready inpatient table
SELECT 
    CAST(DRG_Definition AS NVARCHAR(255)) AS DRG_Definition,
    Provider_Id,
    Provider_Name,
    CAST(Provider_State AS NVARCHAR(50)) AS Provider_State,
    Hospital_Referral_Region_Description,
    Total_Discharges,
    TRY_PARSE(Average_Covered_Charges AS MONEY USING 'en-US') AS Avg_Covered_Charges,
    TRY_PARSE(Average_Total_Payments AS MONEY USING 'en-US') AS Avg_Total_Payments,
    TRY_PARSE(Average_Medicare_Payments AS MONEY USING 'en-US') AS Avg_Medicare_Payments
INTO dbo.InpatientCharges_Analytic
FROM [Healthcare].[dbo].[inpatientCharges]
WHERE Total_Discharges > 0;

--Add indexes to improve query performance
CREATE INDEX idx_drg ON dbo.InpatientCharges_Analytic (DRG_Definition);
CREATE INDEX idx_provider ON dbo.InpatientCharges_Analytic (Provider_Id);
CREATE INDEX idx_state ON dbo.InpatientCharges_Analytic (Provider_State);

--Highest volume DRGs using cleaned analytic table
SELECT
    DRG_Definition,
    SUM(Total_Discharges) AS Total_Discharges
FROM dbo.InpatientCharges_Analytic
GROUP BY DRG_Definition
ORDER BY Total_Discharges DESC;

-- Hospitals with the highest inpatient volume 
SELECT
    Provider_Name,
    Provider_State,
    SUM(Total_Discharges) AS Total_Discharges
FROM dbo.InpatientCharges_Analytic
GROUP BY Provider_Name, Provider_State
ORDER BY Total_Discharges DESC;

-- Average financial gap between charges and payments by DRG 
SELECT
    DRG_Definition,
    AVG(Avg_Covered_Charges) AS Avg_Covered_Charges,
    AVG(Avg_Total_Payments) AS Avg_Total_Payments,
    AVG(Avg_Covered_Charges - Avg_Total_Payments) AS Avg_Charge_Payment_Gap
FROM dbo.InpatientCharges_Analytic
GROUP BY DRG_Definition
ORDER BY Avg_Charge_Payment_Gap DESC;

-- Medicare payment percentage by hospital 
SELECT
    Provider_Name,
    Provider_State,
    AVG(Avg_Medicare_Payments / NULLIF(Avg_Total_Payments, 0)) * 100
        AS Medicare_Payment_Percentage
FROM dbo.InpatientCharges_Analytic
GROUP BY Provider_Name, Provider_State
ORDER BY Medicare_Payment_Percentage DESC;

-- Identify high-payment outliers within each DRG
WITH DRG_Stats AS (
    SELECT
        DRG_Definition,
        AVG(Avg_Total_Payments) AS Avg_Payment,
        STDEV(Avg_Total_Payments) AS StdDev_Payment
    FROM dbo.InpatientCharges_Analytic
    GROUP BY DRG_Definition
)
SELECT
    i.Provider_Name,
    i.Provider_State,
    i.DRG_Definition,
    i.Avg_Total_Payments
FROM dbo.InpatientCharges_Analytic i
JOIN DRG_Stats d
    ON i.DRG_Definition = d.DRG_Definition
WHERE i.Avg_Total_Payments > d.Avg_Payment + (2 * d.StdDev_Payment)
ORDER BY i.Avg_Total_Payments DESC;

--Rank hospitals by payment amount within each DRG using window functions.

SELECT
    Provider_Name,
    Provider_State,
    DRG_Definition,
    Avg_Total_Payments,
    RANK() OVER (
        PARTITION BY DRG_Definition
        ORDER BY Avg_Total_Payments DESC
    ) AS Payment_Rank_Within_DRG
FROM dbo.InpatientCharges_Analytic;

--High-level summary metrics suitable for executive reporting

SELECT
    COUNT(DISTINCT Provider_Id) AS Total_Hospitals,
    COUNT(DISTINCT DRG_Definition) AS Total_DRGs,
    SUM(Total_Discharges) AS Total_Discharges,
    AVG(Avg_Total_Payments) AS Avg_Payment_Per_Case
FROM dbo.InpatientCharges_Analytic;


