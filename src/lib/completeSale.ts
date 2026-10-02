// Sale creation is the only rejecting operation. Printer failure is a separate result,
// so callers cannot mistake a saved sale for a failed checkout and submit it again.
export async function completeSale<T extends { sale_id: string }>(
  create: () => Promise<T>,
  onCompleted: (sale: T) => void,
  print?: (saleId: string) => Promise<unknown>,
): Promise<{ sale: T; printError?: unknown }> {
  const sale = await create();
  onCompleted(sale);
  if (print) {
    try { await print(sale.sale_id); }
    catch (printError) { return { sale, printError }; }
  }
  return { sale };
}
