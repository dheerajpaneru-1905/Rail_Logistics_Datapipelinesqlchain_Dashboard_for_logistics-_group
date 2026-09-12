USE [Logistics_Analytics_DB]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/* =========================================================================================
   Author:        [Your Name]
   Create date:   [Current Year]
   Description:   Rail Express Freight Analytics Pipeline. 
                  Maps shipments to train schedules, wagon utilization, and station lanes.
                  Includes pre-configured schema skeletons for downstream Tableau financial KPIs.
   ========================================================================================= */

CREATE PROCEDURE [analytics].[sp_rail_express_pipeline] 
AS
BEGIN
    SET NOCOUNT ON;
    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
    SET LOCK_TIMEOUT 30000;

    WITH
    -- =========================================================================
    -- PHASE 1: MASTER DATA & LOOKUPS
    -- =========================================================================
    Rail_Pincode_Final AS (
        SELECT
            LTRIM(RTRIM(CAST(Pincode AS VARCHAR(20)))) AS Pincode,
            MAX(State)               AS State,
            MAX(CityName)            AS CityName,
            MAX(Zone)                AS ZoneName,
            MAX(PickupBranchId)      AS PickupBranchId,
            MAX(DeliveryBranchId)    AS DeliveryBranchId
        FROM dim_pincode WITH (NOLOCK)
        GROUP BY LTRIM(RTRIM(CAST(Pincode AS VARCHAR(20))))
    ),

    Rail_Station_Final AS (
        SELECT 
            LTRIM(RTRIM(CAST(PinCode AS VARCHAR(20)))) AS PinCode,
            MAX(StationCode) AS StationCode,
            MAX(StationName) AS StationName,
            MAX(CityId) AS CityId
        FROM dim_rail_station WITH (NOLOCK)
        WHERE IsActive = 1
        GROUP BY LTRIM(RTRIM(CAST(PinCode AS VARCHAR(20))))
    ),

    Train_Data_Final AS (
        SELECT 
            ID AS TrainID,
            TrainNo,
            TrainName,
            TrainTypeId,
            DistanceKM,
            JourneyDuration
        FROM dim_train WITH (NOLOCK)
        WHERE IsActive = 1
    ),

    Customer_Final AS (
        SELECT 
            CustomerID, 
            MAX(CustomerName) AS CustomerName,
            MAX(BranchID) AS CustomerBranchID
        FROM dim_customer WITH (NOLOCK)
        GROUP BY CustomerID
    ),

    -- =========================================================================
    -- PHASE 2: EXCEPTIONS, ATTEMPTS, & MANIFEST MAPPING
    -- =========================================================================
    DRS_Latest AS (
        SELECT DocketNo, DeliveryStatus, UndlyReasonId, AttemptDate, AttemptTime, Delivered
        FROM (
            SELECT DocketNo, DeliveryStatus, UndlyReasonId, DeliveryDate AS AttemptDate, DeliveryTime AS AttemptTime, Delivered,
                   ROW_NUMBER() OVER (PARTITION BY DocketNo ORDER BY DeliveryDate DESC, DeliveryTime DESC, DetailId DESC) AS rn
            FROM fct_delivery_run_sheet WITH (NOLOCK)
        ) x WHERE rn = 1
    ),

    Manifest_THC_Latest AS (
        SELECT * 
        FROM (
            SELECT 
                md.DocketNo, md.MFId, md.THCId, t.TrainId, t.TrainNumber, t.WagonNumber, t.WagonTYpeId,
                ROW_NUMBER() OVER (PARTITION BY md.DocketNo ORDER BY md.CreatedOn DESC, md.MFId DESC) AS rn
            FROM fct_manifest_details md WITH (NOLOCK)
            INNER JOIN fct_trip_header t WITH (NOLOCK) ON md.THCId = t.ThcID
            WHERE md.THCId IS NOT NULL
        ) y WHERE rn = 1
    ),

    CRM_Claims_Agg AS (
        SELECT
            tm.DocketNo,
            SUM(ISNULL(tm.ClaimedValue, 0)) AS TotalClaimValue,
            COUNT(*) AS TotalClaimCount,
            SUM(CASE WHEN tm.ComplaintTypeId = 1 THEN ISNULL(tm.ClaimedValue, 0) ELSE 0 END) AS DamageClaimValue,
            SUM(CASE WHEN tm.ComplaintTypeId = 2 THEN ISNULL(tm.ClaimedValue, 0) ELSE 0 END) AS ShortClaimValue
        FROM fct_crm_tickets tm WITH (NOLOCK)
        GROUP BY tm.DocketNo
    ),

    -- =========================================================================
    -- PHASE 3: BASE RAIL SHIPMENT ENGINE
    -- =========================================================================
    Base_Rail_Shipment AS (
        SELECT
            d.ID AS DocketID, d.DocketNo, d.DocketDate,
            d.ServiceTypeId, d.BillToId AS CustomerID, cm.CustomerName, cm.CustomerBranchID,
            
            -- Geography
            d.BkPincode AS OriginPincode, op.CityName AS OriginCity, op.ZoneName AS OriginZone, op.PickupBranchId AS OriginBranchId,
            d.DlPincode AS DestPincode, dp.CityName AS DestCity, dp.ZoneName AS DestZone, dp.DeliveryBranchId AS DestBranchId,
            
            -- Metrics & Revenue
            d.ActualWeight AS ActualWeightKG, d.ChargedWeight AS OriginalChargedWeightKG,
            ISNULL(d.BasicFreight, 0) AS BasicFreight, ISNULL(d.OdaCharge, 0) AS OdaCharge,
            ISNULL(d.SubTotal, 0) AS ERP_RevenueExcGST, ISNULL(d.DocketTotal, 0) AS ERP_RevenueIncGST,
            (ISNULL(d.CGST, 0) + ISNULL(d.SGST, 0) + ISNULL(d.IGST, 0)) AS CGST_Total,
            
            d.EstDldate AS EDD, d.DeliveryDate, d.CurrentStatus
            
        FROM fct_shipment d WITH(NOLOCK)
        LEFT JOIN Customer_Final cm ON d.BillToId = cm.CustomerID
        LEFT JOIN Rail_Pincode_Final op ON LTRIM(RTRIM(CAST(d.BkPincode AS VARCHAR(20)))) = op.Pincode
        LEFT JOIN Rail_Pincode_Final dp ON LTRIM(RTRIM(CAST(d.DlPincode AS VARCHAR(20)))) = dp.Pincode
        WHERE d.ServiceTypeId IN (6, 7) AND ISNULL(d.CancelDocket, 0) = 0
    ),

    -- =========================================================================
    -- PHASE 4: SLA & TAT ENGINE
    -- =========================================================================
    SLA_Engine AS (
        SELECT
            bd.DocketNo,
            CASE WHEN bd.EDD IS NULL OR bd.DocketDate IS NULL THEN NULL ELSE DATEDIFF(DAY, bd.DocketDate, bd.EDD) END AS NormalTATDays,
            edd_calc.FinalEDD,
            
            CASE 
                WHEN bd.DeliveryDate IS NOT NULL AND bd.DeliveryDate <= edd_calc.FinalEDD THEN 'On-Time' 
                WHEN bd.DeliveryDate IS NOT NULL AND bd.DeliveryDate > edd_calc.FinalEDD THEN 'SLA Breach' 
                WHEN bd.DeliveryDate IS NULL AND dl.AttemptDate IS NOT NULL AND dl.AttemptDate > edd_calc.FinalEDD THEN 'SLA Breach' 
                WHEN bd.DeliveryDate IS NULL AND GETDATE() > edd_calc.FinalEDD THEN 'SLA Breach' 
                ELSE 'In-Transit' 
            END AS SLAStatus,
            
            CASE 
                WHEN bd.DeliveryDate IS NOT NULL THEN DATEDIFF(DAY, bd.DocketDate, bd.DeliveryDate) 
                WHEN dl.AttemptDate IS NOT NULL THEN DATEDIFF(DAY, bd.DocketDate, dl.AttemptDate) 
                ELSE DATEDIFF(DAY, bd.DocketDate, GETDATE()) 
            END AS ActualTransitDays
        FROM Base_Rail_Shipment bd
        LEFT JOIN DRS_Latest dl ON bd.DocketNo = dl.DocketNo
        CROSS APPLY (
            SELECT DATEADD(DAY, CASE WHEN dl.UndlyReasonId IN (13, 14, 23) THEN 1 ELSE 0 END, bd.EDD) AS FinalEDD
        ) edd_calc
    ),

    -- =========================================================================
    -- PHASE 5: FINAL ASSEMBLY & BI SKELETON MAPPING
    -- =========================================================================
    Rail_Shipment_Final AS (
        SELECT 
            'RAIL_DOCKET' AS RecordType,
            bd.*,
            
            -- Geographic Lanes
            o_st.StationCode AS OriginStationCode, o_st.StationName AS OriginStationName, 
            d_st.StationCode AS DestStationCode, d_st.StationName AS DestStationName,
            CONCAT(ISNULL(bd.OriginZone, 'NA'), ' to ', ISNULL(bd.DestZone, 'NA')) AS ZoneLane, 
            CONCAT(ISNULL(o_st.StationCode, 'NA'), ' to ', ISNULL(d_st.StationCode, 'NA')) AS StationLane,

            -- Train & Wagon Details
            mtl.WagonNumber, mtl.WagonTYpeId,
            tdf.TrainNo, tdf.TrainName, tdf.DistanceKM AS TrainDistanceKM, tdf.JourneyDuration AS TrainJourneyDuration,

            -- SLA & Exceptions
            sla.FinalEDD, sla.SLAStatus, sla.ActualTransitDays,
            CASE WHEN sla.SLAStatus = 'SLA Breach' THEN 1 ELSE 0 END AS SLABreachFlag,
            ISNULL(crm.TotalClaimValue, 0) AS TotalClaimValue, 
            
            -- =================================================================
            -- SKELETON COLUMNS FOR TABLEAU / FINANCE KPIs
            -- Pre-cast to ensure zero schema breaks during BI ingestion
            -- =================================================================
            CAST(NULL AS VARCHAR(50)) AS BillNumber,
            CAST(NULL AS DATETIME)    AS BillDate,
            0                         AS BillClosedFlag,
            0.0                       AS PaymentCollected,
            0.0                       AS PendingAmount,
            0.0 AS LinehaulCost, 0.0 AS TerminalCost, 0.0 AS FirstMileCost, 0.0 AS LastMileCost, 0.0 AS TotalCost, 
            (bd.ERP_RevenueExcGST - 0.0) AS GrossProfit,
            0.0 AS ProfitMarginPercentage, 0.0 AS WagonsUtilized, 0.0 AS TrainCapacityMT         

        FROM Base_Rail_Shipment bd
        LEFT JOIN Rail_Station_Final o_st ON bd.OriginPincode = o_st.PinCode
        LEFT JOIN Rail_Station_Final d_st ON bd.DestPincode = d_st.PinCode
        LEFT JOIN Manifest_THC_Latest mtl ON bd.DocketNo = mtl.DocketNo
        LEFT JOIN Train_Data_Final tdf ON CAST(mtl.TrainId AS VARCHAR(50)) = CAST(tdf.TrainID AS VARCHAR(50))
        LEFT JOIN SLA_Engine sla ON bd.DocketNo = sla.DocketNo
        LEFT JOIN CRM_Claims_Agg crm ON bd.DocketNo = crm.DocketNo
    )

    SELECT * FROM Rail_Shipment_Final;
END;
GO
