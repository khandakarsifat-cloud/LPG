# UI and pagination verification — 2026-10-27

## Findings and changes

All four supplied screenshots were reviewed against source and the deployed development application.

- Sales and Purchases used content-sized cards, allowing product counts and long headings to move every subsequent section. Their listing styles were split across global, purchase and sales CSS. They now use one `record-card.css` layout with matching 19rem heights, stable heading/status/metadata rows, aligned payment and total rows, and a bounded product preview. Only overflowing products receive a surface-colored gradient; full details remain in the existing dialogs. Obsolete purchase-card layout rules were removed.
- Inventory, POS and product/bottle selectors flattened Settings-ordered brand groups into a continuous grid. Each brand now starts a new row. `groupedPageStarts` and `useGroupedListPage` account for unused tracks when paging selectors, report actual record ranges and retain selections/anchors. Other directory grids have compact height profiles appropriate to their content.
- The shared payment editor forced right alignment. Amounts now edit from the left. Purchase monetary controls retain plain decimals instead of inserting grouping separators or selecting the entire amount on focus. Tests exercise cursor movement, Delete, Backspace, clearing and selection replacement.
- Purchase wallet evidence was independently paged below the financial summary. `get_purchase_activity` now attaches each ledger row to one recorded operation/payment, retaining unmatched historical ledger evidence as separate chronological events. The summary keeps balances and refund obligations; Activity history keeps the signed amounts, wallet snapshots, actors, times and audit references once. History navigation retains the previous complete page while loading. No financial or stock records were rewritten.
- `useBatchedDirectory` emptied cards when an uncached batch was needed, while the page indicator already moved. The new regression test failed on the previous deployment with “Uncached navigation cleared existing cards.” One shared hook now owns navigation and commits cards, count, page and capacity together. Polling invalidates a scope together; stale cached scopes refresh on remount. Count reductions permanently clamp the anchor. Grid measurement ignores content-height changes, and desktop scrolling reserves its gutter.
- A live 320px Sales check reproduced pagination controls overflowing on a middle page when extra page buttons appeared. Shared pagination now constrains its width and wraps its controls. Local catalogs use the existing bounded `readAllRows` utility and stable ordering, avoiding silent truncation at the API row limit.

The initial read-only desktop/breakpoint checks did **not** reproduce overlapping Customer card boxes or an incorrect server count: Azure had 62 customers. These symptoms were not attributed to an invented database defect. The final checks compare every rendered ID and page range with the API and assert no card overlap or page overflow. A genuine capacity change still reframes the page containing the saved record anchor.

## Verification

Passed:

- TypeScript/Vite build, ESLint, `git diff --check`, and all 54 unit tests.
- Full migration replay on a disposable PostgreSQL 17.6 database, all ten SQL suites and the existing checkout, payment, refund, transfer and bottle concurrency checks. The disposable database was removed. Purchase SQL/API tests assert chronological, exact-once ledger evidence and foreign-tenant denial.
- Directory fixtures: delayed batches, retry, cache reuse, direct jumps, count shrink/growth, sidebar/viewport round trips, 21 route/viewport combinations, phone pages 4/5, long headings, many/empty product lists, large monetary values, fixed dimensions, visible financial information and overflow fades.
- Responsive fixtures: 260 route/layout combinations, 12 compact layouts, 41 field/picker checks, light/dark dialogs, touch layouts, 1.25×/2× device-scale emulation and keyboard viewport resizing. Bottle, Inventory history, Purchase history, Purchase lifecycle and Finance workflows also passed.
- Published Auth/PostgREST/browser payment, cancellation and refund acceptance on disposable businesses, followed by fixture cleanup and unchanged original-business hashes.
- Read-only published acceptance using the documented burner: **122 directory pages** across eight viewports (320, 390, 600, 768, 1024, 1366, 1440 and 1920px). All **62 Customers, 57 Sales and 23 Purchases** were reachable with exact IDs, ranges and page indicators, including Customer pages 4 and 5. Card dimensions were uniform, with no overlap or horizontal overflow.
- Live Inventory/POS brand row starts and Settings order; a 13-event purchase history containing six wallet entries once; staged checkout cursor editing followed by Cancel. Original stock, wallets, ledger, customers, sales, purchase lines and activity fingerprints were unchanged. Additional Inventory breakpoint probes found no child overflow at 128px tile width.

Reusable live acceptance: `node supabase/tests/ui-directory-api.mjs --azure` and `node supabase/tests/purchase-wallets-api.mjs --azure --browser`. Credentials remain in ignored configuration; the former blocks all business mutations, and the latter writes only disposable fixtures.

The optional PGlite replay stopped in the earlier canonical migration on its `transit_status` type lookup. Already-applied migrations were preserved; the complete PostgreSQL 17.6 replay and suites passed. Browser emulation does not establish physical-device, installed-PWA or external payment-provider behavior.

## Deployment

- Applied reviewed migration **20261027190000** through the existing updater. Backup: `/opt/lpg/backups/deployment-20261027T171417282591Z`. Existing volumes, credentials and services were preserved.
- Azure reports **35 applied migrations**, latest `20261027190000`; no migrations remain pending. Ten services and public HTTPS health passed. The activity RPC retains `postgres` ownership, an empty search path, authenticated execution and no anonymous execution.
- Published Cloudflare version **7185a577-d7c9-4663-94a7-7ce15dfd847c**. Published entry assets match the final deployment build and return HTTP 200. The authenticated checks above ran against this deployment.
