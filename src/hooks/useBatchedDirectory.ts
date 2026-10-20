import { useQueries, useQuery, type QueryKey } from '@tanstack/react-query';

export const DIRECTORY_BATCH_SIZE = 25;
interface DirectoryResult<T> { entries: T[]; total: number }

/** Cache server batches independently of the grid's visible page boundaries. */
export function useBatchedDirectory<T>(key: QueryKey, page: number, pageSize: number,
  fetchBatch: (offset: number, limit: number, signal: AbortSignal) => Promise<DirectoryResult<T>>) {
  const options = (offset: number) => ({
    queryKey: [...key, 'batch', offset],
    queryFn: ({ signal }: { signal: AbortSignal }) => fetchBatch(offset, DIRECTORY_BATCH_SIZE, signal),
    // Navigation and column changes reuse loaded batches. Existing mutations
    // invalidate this key family; active batches retain the regular refresh.
    staleTime: Infinity,
    refetchInterval: 30_000,
  });
  const first = useQuery(options(0));
  const total = first.data?.total ?? 0;
  const start = page * pageSize;
  const end = Math.min(total, start + pageSize);
  const offsets: number[] = [];
  for (let offset = Math.floor(start / DIRECTORY_BATCH_SIZE) * DIRECTORY_BATCH_SIZE; offset < end; offset += DIRECTORY_BATCH_SIZE) {
    if (offset > 0) offsets.push(offset);
  }
  const rest = useQueries({ queries: offsets.map(options) });
  const queries = [first, ...rest];
  const isPending = queries.some(query => query.isPending);
  const isError = queries.some(query => query.isError);
  const hasData = queries.every(query => query.data !== undefined);
  const batches = new Map([[0, first.data], ...rest.map((query, index): [number, DirectoryResult<T> | undefined] => [offsets[index], query.data])]);
  const entries: T[] = [];
  if (hasData) for (let index = start; index < end; index++) {
    const entry = batches.get(Math.floor(index / DIRECTORY_BATCH_SIZE) * DIRECTORY_BATCH_SIZE)?.entries[index % DIRECTORY_BATCH_SIZE];
    if (entry !== undefined) entries.push(entry);
  }
  return {
    data: first.data ? { total, entries } : undefined,
    isPending, isError, isSuccess: !isPending && !isError,
    isFetching: queries.some(query => query.isFetching),
    refetch: () => Promise.all(queries.filter(query => query.isError).map(query => query.refetch())),
  };
}
