import type { InvalidateQueryFilters, QueryClient } from '@tanstack/react-query';

/** Initial pending reads must finish or be cancelled before post-write refetch.
 * TanStack otherwise reuses an initial pending promise during invalidation.
 */
export async function invalidateFreshQueries(client: QueryClient, filters: InvalidateQueryFilters) {
  await client.cancelQueries(filters);
  await client.invalidateQueries(filters);
}
