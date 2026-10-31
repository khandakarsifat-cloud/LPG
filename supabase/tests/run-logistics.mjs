// Canonical disposable PostgreSQL verifier shared with accounting and analytics.
process.argv.push('logistics.sql','spending.sql','authorization.sql','employees.sql','purchase-wallets.sql','accounting.sql');
await import('./run-accounting.mjs');
