# LPG Manager

A full-featured, multi-tenant business management system built for LPG (Liquefied Petroleum Gas) dealerships in Bangladesh. Handles everything from point-of-sale and inventory to logistics, employee payroll, and supplier management — all backed by a locally-hosted Supabase instance.

> **⚠️ Work in Progress** — The project is under active development. Several modules are functional but two key integrations (thermal POS printer and ZKTeco attendance machine) are still pending.

---

## Table of Contents

- [Overview](#overview)
- [Features](#features)
  - [✅ Implemented](#-implemented)
  - [🚧 In Progress / Planned](#-in-progress--planned)
- [Tech Stack](#tech-stack)
- [Project Structure](#project-structure)
- [Database Architecture](#database-architecture)
- [Getting Started](#getting-started)
  - [Prerequisites](#prerequisites)
  - [Installation](#installation)
  - [Environment Setup](#environment-setup)
  - [Running the App](#running-the-app)
- [Module Breakdown](#module-breakdown)
- [ZKTeco Attendance Integration (WIP)](#zkteco-attendance-integration-wip)
- [Roadmap](#roadmap)

---

## Overview

LPG Manager is designed specifically for LPG cylinder dealerships operating in Bangladesh. It supports multiple independent tenants (businesses) on the same instance, each with full data isolation enforced at the database level via Row-Level Security (RLS).

The system uses **Supabase** running **locally** (not cloud) for development, with a rich set of PostgreSQL RPCs serving as a secure server-side business logic layer.

---

## Features

### ✅ Implemented

#### 🛒 Point of Sale (POS)
- Tiered pricing support — `retail` and `wholesale` customer tiers
- Price books per item and tier (`refill`, `package`, `empty_return` sale types)
- Smart customer lookup with phone number search (BD mobile format validation)
- On-the-fly customer creation at checkout
- Discount and exchange fee fields
- Sale notes
- **PDF receipt generation** (80mm thermal paper format via jsPDF — browser print fallback, hardware printer integration pending)
- Full real-time cart with quantity management

#### 📦 Inventory Management
- Item registry with brand, size (kg), cylinder weight (5/12/25/35 kg), and mouth size (20/22mm) specs
- Real-time stock balances — filled and empty cylinder quantities tracked separately
- Inventory movement feed (last 100 movements, auto-refreshes every 15s)
- Manual stock adjustments with notes
- Per-product movement history modal
- Items linked to LPG brands for accurate cylinder specification tracking

#### 🏷️ LPG Brand Management (Settings)
- Full CRUD for LPG brands (Indane, Bharat Gas, etc.) per tenant
- Brand activation/deactivation (soft delete)
- Brands drive item creation — all inventory items must be linked to a brand

#### 🚛 Logistics
- Truck registry — name, serial number, capacity, size, operational status, and location
- Truck status management (`idle`, `in_transit`, `maintenance`, etc.)
- Transit records linked to trucks — custom transits with driver/helper/oil/additional costs
- Transit cost breakdown and status tracking
- Wallet balances per truck/entity

#### 🏭 Gas Plants (Suppliers)
- Gas plant registry with brand association and location
- Area officer management per plant — name, WhatsApp, email
- Plants used as source references in purchase orders

#### 🧾 Purchases (Inbound Restocking)
- Purchase order creation — truck, gas plant, items with quantities and unit prices
- Transport and labour cost tracking per purchase
- Draft → Complete lifecycle with inventory auto-update on completion
- Purchase list view with status

#### 👥 Customers
- Customer database with name, phone, shop name, address, tier
- Bangladesh mobile phone format enforcement (`01XXXXXXXXX`)
- Smart fuzzy search — scores matches by phone prefix, name, shop, address
- Duplicate phone detection on add

#### 👔 Employees
- Employee profiles — name, multiple phone numbers (primary flag), address, salary, business unit, type, notes
- Business unit separation: `gas_business` vs. `truck_business`
- Employee type classification: Manager, Salesman, Driver, Helper, Staff, etc.
- Activate/deactivate (soft delete)
- **Payment ledger** — records salary, bonus, commission, trips, and other payment categories
- Salary month/year and trip count metadata per payment entry
- Per-employee payment history view

#### 📊 Dashboard
- Today's revenue (from completed POS sales)
- Today's inventory movement count
- Active customer count
- Live today's sales feed

#### 🔐 Authentication & Multi-tenancy
- Email + password authentication via Supabase Auth
- Business registration flow — creates tenant, owner profile, and role atomically (`setup_business` RPC)
- All data isolated by `tenant_id` at the RLS level
- Protected routes — unauthenticated users redirected to login

---

### 🚧 In Progress / Planned

| Feature | Status | Notes |
|---|---|---|
| Thermal POS Printer | 🚧 Pending | jsPDF generates 80mm-format receipts; direct ESC/POS hardware integration not yet done |
| ZKTeco Attendance Integration | 🚧 Pending | ADMS server prototype working (see `zk-test/`); not yet wired into the app |
| Financial Ledger | 🔜 Placeholder | Route exists (`/finance`) but module not started |
| Low-stock Alerts / Exceptions | 🔜 Placeholder | Dashboard widget reserved; logic not configured |
| Reporting & Analytics | 🔜 Not started | Sales summaries, inventory reports, payroll summaries planned |
| User Role Management | 🔜 Not started | Currently single-owner per tenant |

---

## Tech Stack

| Layer | Technology |
|---|---|
| **Frontend** | React 19, TypeScript 6, Vite 8 |
| **Routing** | React Router DOM v7 (Hash Router) |
| **State / Data Fetching** | TanStack React Query v5 |
| **Backend / Database** | Supabase (local) — PostgreSQL + PostgREST + GoTrue |
| **Styling** | Vanilla CSS (custom design system, dark mode, glassmorphism) |
| **Icons** | Lucide React |
| **PDF Receipts** | jsPDF |
| **Toasts** | react-hot-toast |
| **Date Utilities** | date-fns |
| **Attendance Hardware** | ZKTeco MB20-VL via ADMS HTTP protocol (node-zklib, `zk-test/`) |

---

## Project Structure

```
LPG/
├── src/
│   ├── components/
│   │   ├── Layout.tsx              # App shell — sidebar, nav, header
│   │   ├── ProtectedRoute.tsx      # Auth guard
│   │   ├── business/               # Brand management UI
│   │   ├── dashboard/              # Sales feed widget
│   │   ├── gasplants/              # Gas plant & area officer modals
│   │   ├── inventory/              # Item modals, balance grid, movement feed
│   │   ├── logistics/              # Truck, transit, cost modals
│   │   ├── pos/                    # Cart, item grid, checkout modal, customer search
│   │   └── purchases/              # Purchase form components
│   ├── contexts/
│   │   └── AuthContext.tsx         # Auth state, tenant profile, sign-in/register
│   ├── hooks/                      # TanStack Query hooks (one per domain)
│   │   ├── useBrands.ts
│   │   ├── useCustomers.ts
│   │   ├── useDashboard.ts
│   │   ├── useEmployees.ts
│   │   ├── useGasPlants.ts
│   │   ├── useInventory.ts
│   │   ├── useLogistics.ts
│   │   ├── usePOS.ts
│   │   └── usePurchases.ts
│   ├── lib/
│   │   ├── bdPhone.ts              # BD mobile phone normalization & validation
│   │   ├── formatBDT.ts            # Bangladeshi Taka (BDT) number formatting
│   │   ├── receiptPdf.ts           # 80mm thermal receipt PDF generator (jsPDF)
│   │   ├── supabase.ts             # Supabase client (enforces local-only config)
│   │   └── theme.ts                # Theme / CSS variable helpers
│   ├── pages/
│   │   ├── auth/                   # Login & Register pages
│   │   ├── Customers.tsx
│   │   ├── Dashboard.tsx
│   │   ├── Employees.tsx
│   │   ├── GasPlants.tsx
│   │   ├── Inventory.tsx
│   │   ├── Logistics.tsx
│   │   ├── POS.tsx
│   │   ├── Purchases.tsx
│   │   └── Settings.tsx            # LPG brand management tab
│   └── types/                      # Shared TypeScript interfaces
│       ├── gasPlants.ts
│       ├── inventory.ts
│       ├── logistics.ts
│       └── purchase.ts
├── supabase/
│   ├── config.toml                 # Supabase local config (port 54321)
│   └── migrations/                 # PostgreSQL migration files
│       ├── 20260627000000_cloud_baseline.sql
│       ├── 20260627185300_fix_schema_inconsistencies.sql
│       ├── 20260701130553_enforce_customers_phone_format.sql
│       ├── 20260701150242_require_customers_phone_bd_mobile.sql
│       ├── 20260702152740_pos_customer_id_no_update.sql
│       ├── 20260702155154_numeric_customer_phone_lengths.sql
│       └── 20260702164710_employees.sql
├── zk-test/
│   └── test.cjs                    # Standalone ZKTeco ADMS server prototype
├── cloud_auth_data.sql             # Seeded auth data for cloud reference
├── cloud_public_data.sql           # Seeded public schema data for cloud reference
├── LPG_BRANDS_AND_SPECS_DOCUMENTATION.md
├── IMPLEMENTATION_SUMMARY.md
├── vite.config.ts
├── package.json
└── .env / .env.development / .env.local
```

---

## Database Architecture

All business logic lives in **PostgreSQL stored procedures (RPCs)** called via Supabase's PostgREST layer. The frontend never writes to tables directly except for a few simple inserts.

### Key Tables

| Table | Purpose |
|---|---|
| `tenants` | One row per registered business |
| `user_profiles` | Links Supabase Auth users to a tenant |
| `items` | LPG cylinder product registry (brand, size, specs) |
| `lpg_brands` | Brand catalogue per tenant |
| `inventory_movements` | Append-only ledger of all stock changes |
| `customers` | Customer database with tier and phone |
| `employees` | Employee profiles with salary and business unit |
| `employee_phones` | Multi-phone support per employee |
| `employee_payment_categories` | Configurable payment types (salary, bonus, etc.) |
| `employee_payments` | Payment history per employee |
| `trucks` | Truck registry with status and capacity |
| `transits` | Delivery/transport records per truck |
| `gas_plants` | LPG supplier/plant registry |
| `area_officers` | Contact persons per gas plant |
| `purchases` | Inbound stock purchase orders |
| `purchase_items` | Line items per purchase |
| `price_books` | Per-item, per-tier pricing |
| `sales` | POS sale header records |
| `sale_items` | Line items per sale |
| `wallets` | Financial balance ledger |
| `audit_logs` | Immutable change trail for all operations |

### Security Model

- **Row-Level Security (RLS)** is enabled on every table
- All operations are scoped to the current user's `tenant_id`
- Authenticated RPCs extract `tenant_id` from the session — clients cannot spoof it
- The Supabase client is restricted to the **anon key** — service role keys are explicitly blocked in `src/lib/supabase.ts`

---

## Getting Started

### Prerequisites

- **Node.js** ≥ 18
- **npm** ≥ 9
- **Supabase CLI** — [install guide](https://supabase.com/docs/guides/local-development/cli/getting-started)
- **Docker** (required by Supabase CLI for the local stack)

### Installation

```bash
# Clone the repository
git clone <repo-url>
cd LPG

# Install dependencies
npm install
```

### Environment Setup

The project enforces **local-only** Supabase. Cloud URLs are blocked at runtime.

1. **Start the local Supabase stack:**
   ```bash
   supabase start
   ```

2. **Copy the generated keys** from the `supabase start` output into your env file:

   Create (or update) `.env.local`:
   ```env
   VITE_SUPABASE_URL=http://localhost:54321
   VITE_SUPABASE_ANON_KEY=<your-local-anon-key>
   ```

3. **Apply migrations:**
   ```bash
   supabase db reset
   ```
   This runs all files in `supabase/migrations/` in order.

### Running the App

```bash
npm run dev
```

Open [http://localhost:5173](http://localhost:5173), register a new business, and you are in.

---

## Module Breakdown

### POS (`/pos`)
The sales terminal. Select or search for a customer by phone, add cylinder products to the cart (with refill, package, or empty return types), apply discounts/exchange fees, confirm checkout, and generate an 80mm PDF receipt.

> **Note:** The PDF is currently opened in a new browser tab for printing. Direct ESC/POS thermal printer communication is not yet implemented.

### Inventory (`/inventory`)
Two tabs — **Balances** (current filled/empty stock per product) and **Item Registry** (all product definitions). Supports manual adjustments and a live movement feed.

### Logistics (`/logistics`)
Two tabs — **Trucks** (fleet registry with status) and **Transits** (delivery records with full cost breakdowns).

### Purchases (`/purchases`)
Record inbound stock from a gas plant. Each purchase links a truck, a plant, and a list of items with quantities and prices. Completing a purchase updates inventory balances.

### Gas Plants (`/gas-plants`)
Supplier directory. Each plant can have multiple area officers with contact details.

### Customers (`/customers`)
Customer CRM. Phone-based deduplication, tiered (retail/wholesale), smart search.

### Employees (`/employees`)
HR and payroll. Full employee profiles with multi-phone support, business unit assignment, and a detailed payment ledger.

### Settings (`/settings`)
Currently contains the **LPG Brands** management tab for adding/editing cylinder brands.

---

## ZKTeco Attendance Integration (WIP)

The `zk-test/` folder contains a standalone Node.js ADMS server (`test.cjs`) that:

- Listens on port `8000` across all network interfaces
- Handles the ZKTeco ADMS HTTP protocol:
  - `GET /iclock/cdata` — device handshake/heartbeat (responds `OK`)
  - `POST /iclock/cdata` — receives live attendance push data (tab-separated: `UserID \t Timestamp \t Status`)
- Parses and logs incoming attendance records in real time

**Current Status:** The server successfully connects with a ZKTeco MB20-VL biometric terminal and receives attendance data. It is **not yet integrated** into the main application.

**To run the test server:**
```bash
node zk-test/test.cjs
```

**Planned integration:**
- Parse and persist attendance records to a Supabase table
- Build an attendance dashboard within the Employees module
- Link attendance records to employee profiles by `UserID`

---

## Roadmap

- [ ] **Thermal POS Printer** — ESC/POS direct communication for receipt printing on hardware
- [ ] **ZKTeco Attendance** — Full integration: persist records → attendance dashboard → employee linkage
- [ ] **Financial Ledger** (`/finance`) — General ledger, expense tracking, P&L
- [ ] **Low-stock Alerts** — Dashboard exception reporting when stock falls below threshold
- [ ] **Reporting** — Sales summaries, inventory reports, payroll exports
- [ ] **User Role Management** — Multiple staff accounts per tenant with role-based access
- [ ] **Offline Support** — PWA / local-first capabilities for unreliable network environments

---

## Currency & Locale

All monetary values are displayed in **Bangladeshi Taka (BDT / ৳)** using a custom `formatBDT` utility. Phone numbers are validated and normalized to Bangladesh mobile format (`01XXXXXXXXX` — 11 digits, starting with `01[3-9]`).

---

*Built for LPG dealerships in Bangladesh. Not affiliated with any LPG brand or cylinder manufacturer.*
