# Adaptive grids and pagination

[Architecture](../architecture.md)

## Layout contract

`src/components/ui/adaptive-grid.css` owns card tracks, compact gaps and minimum/maximum widths. Attach `adaptive-grid` and the appropriate modifier to the actual grid, including grids in dialogs. Auto-fill keeps sparse/last-page cards the same size as full-page cards. Cards stop at their profile maximum; empty space is preferable to oversized controls. All tracks can shrink to the container on very small screens. Avoid route-specific column breakpoints.

| Surface | Width policy | Pagination policy |
| --- | --- | --- |
| Customers, Purchases, Sales | 15rem minimum, 22rem maximum | Three rows; containers at most 600px show at least ten records, rounded to whole rows |
| Gas plants, Settings brands, each transit group | Minimum 21.25/18.75/19rem, bounded cards | Same measured directory policy; transit groups navigate independently |
| POS | 14rem minimum, 17.5rem maximum; phone cards can use the compact workspace width | Full catalog scrolls; cart has no pagination |
| Inventory catalog | 8rem minimum, 13rem maximum | Full catalog scrolls |
| Inventory/Customer product picker | Inventory tracks | Two to four rows according to viewport height; body scrolls when necessary |
| Bottle collection picker | 8rem minimum, 13.75rem maximum | Same bounded row policy, with a smaller row estimate |
| Finance wallets | 10.5rem minimum, 15rem maximum | All wallets visible; no display pagination |
| Employees and fleet | Existing responsive tables/labeled phone records | Stable 12 desktop / four phone rows; all-data totals stay independent |
| Finance ledger/dues, customer transactions, payment/bottle histories, inventory history, Dashboard feed | Existing rows/tables | Stable server limits and shared exact-count/look-ahead controls |
| Transaction/purchase lines, shortage warnings, phones, payment and cost editors | Existing list/form layouts | Stable local slices; complete drafts still drive totals and submission |
| Overview figures, form fields, comparison panels, weekly history and calendar | Semantic fixed groups with existing narrow-layout rules | No record pagination |

POS uses the workspace container to stack checkout at 52rem and below. Wider workspaces retain the bounded, sticky checkout panel and its existing height/scroll ownership. Columns depend on product space, with no four-column ceiling or tablet two-column override. The page shell still owns normal page scrolling; dialog bodies retain their own scroller and visible actions.

Inventory, POS and both product pickers start each brand on a new row, in Settings order and then weight/mouth order. The shared `brand-row-start` placement preserves adaptive columns without nested grids or empty placeholder cards. Picker pages account for partially filled brand rows through `useGroupedListPage`; their ranges report actual records, and every product remains reachable. Search, selection and acknowledgements remain independent of the visible page.

Sales and Purchases use `record-card.css`: matching 19rem transaction cards reserve identity, two badge rows, metadata, a bounded product preview, payment summary and total. Paid/due amounts occupy separate aligned rows, and the total footer keeps its label above a full-width amount row so all totals align. `CardProductPreview` measures overflow and adds a surface-colored fade only when products exceed the preview. Financial information and statuses never enter that region. Details retain all product lines. Customers use 15rem cards with bounded identity/address areas; inventory, bottle, wallet, brand, plant and transit grids have their own compact fixed-height profiles. Widths remain container-responsive. Desktop page scrolling reserves its scrollbar gutter so a short final page cannot change column count; phones keep their available width.

## Navigation and fetching

`useGridPageSize` reads resolved CSS tracks from the actual grid through `ResizeObserver`. Measurements settle for 120ms before capacity changes; unchanged capacities do not update React state. Only compact pickers listen to viewport height changes. Directory pages deliberately ignore height and variable card heights, retaining natural scrolling and predictable pages. Picker row estimates reserve space for controls and cap capacity at four rows; they do not promise every field fits without scrolling.

`usePagePosition` stores an absolute record offset plus filter key. A capacity change reframes the page containing that offset, and a resize round trip restores the original page. Explicit navigation replaces the offset. Filters/sorts reset it. `useListPage` also clamps shrinking local lists; `useBatchedDirectory` clamps server pages after an exact-count refresh. Resizing preserves the record anchor, not an exact physical scroll position.

`useBatchedDirectory` owns one navigation anchor for Customers, Purchases and Sales and caches server batches of 25 by filter/sort scope. Display capacity is absent from batch query keys. Only intersecting batches and the count-bearing first batch are fetched. Cards, total, displayed page and page size commit together after every required batch succeeds. During navigation/refresh the previous complete view remains visible and navigation is busy; another filter never inherits its results. Count reductions permanently clamp the anchor, including after counts grow again. One 30-second scope invalidation refreshes active batches together and marks inactive batches stale; old scopes also refresh on remount. Brand, plant, employee, fleet and transit catalogs use `readAllRows` to avoid silently ending at the API row limit, with deterministic ordering and cancellation.

`Pagination` handles exact totals, and `PageNavigation` handles look-ahead APIs. Both disable navigation while fetching, expose accessible page state and share touch/focus styling. Fixed history/editor limits are intentional; resizing them would add requests or disturb editing without improving card utilization.

Dialog visual treatment is shared without changing capacity: headers and footers remain outside the body scroller, bodies retain vertical breathing room, and `.dialog-form` owns form gaps independently of route CSS. `history.css` gives employee, sale, purchase and payment records individual borders and consistent metadata. Record actions wrap within their own separated row; adding a history surface must not change directory tracks or backend batch sizes. Customer profile figures retain four desktop columns and use two on phones so monetary digits remain readable.

## Verification boundaries

`tests/pagination.test.ts` covers anchors, count clamping, capacity and brand-aware page packing. `tests/batched-directory.browser.cjs` covers all three directories, delayed batch transitions, aligned ranges, count shrink/growth, nonzero-anchor resizing, cache reuse, retry, direct jumps, long names, uniform geometry and product fades. `tests/bottle-layouts.browser.cjs` verifies brand row starts, Settings order, picker anchors/selections, natural payment cursor editing and 320–1440px dialogs. `tests/purchase-history.browser.cjs` covers the unified financial timeline. The responsive, compact-layout, Customers, Inventory-history and Purchases suites cover shared regressions with intercepted APIs.

Browser viewport, touch and device-scale emulation establish CSS/layout behavior. Native browser zoom, OS scaling, orientation changes on physical hardware and installed-PWA chrome/keyboard behavior still require device acceptance. Live Auth/PostgREST checks are reported separately from intercepted fixtures.
