import { useEffect, useState } from 'react';
import { hashKey, useQueries, useQuery, useQueryClient, type QueryKey } from '@tanstack/react-query';
import { usePagePosition } from './useListPage';

export const DIRECTORY_BATCH_SIZE = 25;
interface DirectoryResult<T> { entries: T[]; total: number }

/** Cache server batches independently of the grid's visible page boundaries. */
export function useBatchedDirectory<T>(key: QueryKey, pageSize: number,
  fetchBatch: (offset: number, limit: number, signal: AbortSignal) => Promise<DirectoryResult<T>>) {
  const client = useQueryClient();
  const scope = hashKey(key);
  // Invalidate the whole scope together. Inactive batches must refresh when reused;
  // separate batch timers can combine rows from different sort/count snapshots.
  useEffect(() => {
    const timer = setInterval(() => { void client.invalidateQueries({ queryKey: JSON.parse(scope) as QueryKey }); }, 30_000);
    return () => clearInterval(timer);
  }, [client, scope]);
  const options = (offset: number) => ({
    queryKey: [...key, 'batch', offset],
    queryFn: ({ signal }: { signal: AbortSignal }) => fetchBatch(offset, DIRECTORY_BATCH_SIZE, signal),
    // Navigation and column changes reuse loaded batches. Existing mutations
    // invalidate this key family; active batches retain the regular refresh.
    staleTime: 30_000,
  });
  const first = useQuery(options(0));
  const { page, setPage } = usePagePosition(pageSize, scope, first.data?.total);
  const total = first.data?.total ?? 0;
  const start = page * pageSize;
  const end = Math.min(total, start + pageSize);
  const offsets: number[] = [];
  for (let offset = Math.floor(start / DIRECTORY_BATCH_SIZE) * DIRECTORY_BATCH_SIZE; offset < end; offset += DIRECTORY_BATCH_SIZE) {
    if (offset > 0) offsets.push(offset);
  }
  const rest = useQueries({ queries: offsets.map(options) });
  const queries = [first, ...rest];
  const isError = queries.some(query => query.isError);
  const isFetching = queries.some(query => query.isFetching);
  const hasData = queries.every(query => query.data !== undefined);
  const batches = new Map([[0, first.data], ...rest.map((query, index): [number, DirectoryResult<T> | undefined] => [offsets[index], query.data])]);
  const entries: T[] = [];
  if (hasData) for (let index = start; index < end; index++) {
    const entry = batches.get(Math.floor(index / DIRECTORY_BATCH_SIZE) * DIRECTORY_BATCH_SIZE)?.entries[index % DIRECTORY_BATCH_SIZE];
    if (entry !== undefined) entries.push(entry);
  }
  const [snapshot, setSnapshot] = useState<{ scope: string; data: DirectoryResult<T> & { page: number; pageSize: number }; sources: unknown[] }>();
  const complete = hasData && !isError && !isFetching;
  if (complete && (snapshot?.scope !== scope || snapshot.data.page !== page || snapshot.data.pageSize !== pageSize
    || queries.some((query, index) => query.data !== snapshot.sources[index]))) {
    setSnapshot({ scope, data: { total, entries, page, pageSize }, sources: queries.map(query => query.data) });
  }
  // Keep cards and their range/page metadata as one committed view while loading.
  // Never reuse a previous filter's records as the results of a new search.
  const data = snapshot?.scope === scope ? snapshot.data : undefined;
  return { data, page, setPage, isPending: !data && !isError, isError,
    isSuccess: complete, isFetching, refetch: () => client.invalidateQueries({ queryKey: key }) };
}
