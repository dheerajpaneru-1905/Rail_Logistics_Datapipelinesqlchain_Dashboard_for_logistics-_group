# 🚂 Rail Freight Analytics & Management Dashboard Pipeline (SQL)

### 📌 Executive Summary
This repository features an enterprise-grade SQL pipeline built to power management-level BI dashboards (Tableau/Power BI) for a Rail Express Logistics network. 

Rail logistics relies heavily on train schedules, wagon capacities, and terminal-to-terminal efficiency. This pipeline translates millions of fragmented operational records (manifests, run sheets, ERP billing) into a flattened, high-visibility dataset. It provides executive leadership with immediate insights into **Network Yield, SLA Breach Impacts, and Freight Gross Margins**.

---

### 💼 Management Use Cases & Business Value

This data model is specifically engineered to answer top-level management questions dynamically:

*   **Lane Profitability & Yield:** By concatenating Origin and Destination Station Codes (`StationLane`), management can instantly filter Tableau views to see which specific train routes generate the highest margin per metric ton.
*   **Wagon Utilization Tracking:** Merging `Train_Data_Final` and `Manifest_THC_Latest` allows capacity planning teams to see exactly which shipments were loaded onto which Wagon ID, identifying under-utilized rail assets.
*   **SLA Liability & Claims Risk:** The pipeline explicitly binds CRM Ticket (Damage/Delay claims) data directly to the delivery SLA engine. This allows leadership to instantly calculate the financial risk of SLA breaches on specific railway lines.

---

### 🛠️ Technical Architecture & Advanced Data Engineering

*   **Window Functions for Manifest Accuracy:** Rail shipments frequently change manifests or get re-routed. By utilizing `ROW_NUMBER() OVER (PARTITION BY DocketNo ORDER BY CreatedOn DESC)`, the pipeline guarantees that only the *latest* and most accurate train/wagon assignment is passed to the visualization layer.
*   **BI-Ready "Skeleton Schema" Engineering:** 
    A common point of failure in data pipelines occurs when downstream BI tools (like Tableau) fail to ingest new columns due to mismatched data types. 
    *This script utilizes forward-looking "Skeleton Columns" (e.g., `CAST(NULL AS DATETIME) AS BillDate`, `0.0 AS LinehaulCost`).* This pre-allocates the exact schema requirements for future financial KPI integrations, ensuring zero dashboard downtime when new cost models are introduced.
*   **Automated EDD Adjustment Logic:** Uses `CROSS APPLY` to dynamically inject penalty days into the Estimated Delivery Date (EDD) based strictly on validated exception codes (e.g., train derailments vs. natural disasters).

### 📁 Repository Structure
*   `rail_freight_pipeline.sql`: The primary stored procedure driving the backend transformation.
*   *(Note: Database identifiers, station codes, and train numbers have been anonymized to generic standards for portfolio display).*
