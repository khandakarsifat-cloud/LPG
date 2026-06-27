/**
 * Format a number using Bangladesh notation (lakh/crore grouping).
 * Example: 1_00_00_000 → "1,00,00,000"
 */
export function formatBDNumber(value: number): string {
  if (value === 0) return '0';

  const isNegative = value < 0;
  const abs = Math.abs(value);

  const [intPart, decPart] = abs.toFixed(2).split('.');

  // Bangladesh grouping: last 3 digits, then groups of 2
  let formatted = '';
  if (intPart.length <= 3) {
    formatted = intPart;
  } else {
    const last3 = intPart.slice(-3);
    const rest  = intPart.slice(0, -3);
    // Split rest into groups of 2 from the right
    const groups: string[] = [];
    let remaining = rest;
    while (remaining.length > 2) {
      groups.unshift(remaining.slice(-2));
      remaining = remaining.slice(0, -2);
    }
    if (remaining.length > 0) groups.unshift(remaining);
    formatted = groups.join(',') + ',' + last3;
  }

  const result = `${formatted}.${decPart}`;
  return isNegative ? `-${result}` : result;
}

/**
 * Format a monetary value in BDT (Bangladeshi Taka).
 * e.g. 1_00_000 → "৳1,00,000.00"
 */
export function formatBDT(value: number): string {
  return `৳${formatBDNumber(value)}`;
}

/**
 * Format integer quantity with Bangladesh grouping (no decimal).
 */
export function formatBDQty(value: number): string {
  const isNegative = value < 0;
  const abs = Math.abs(value);
  const intStr = Math.round(abs).toString();

  let formatted = '';
  if (intStr.length <= 3) {
    formatted = intStr;
  } else {
    const last3 = intStr.slice(-3);
    const rest  = intStr.slice(0, -3);
    const groups: string[] = [];
    let remaining = rest;
    while (remaining.length > 2) {
      groups.unshift(remaining.slice(-2));
      remaining = remaining.slice(0, -2);
    }
    if (remaining.length > 0) groups.unshift(remaining);
    formatted = groups.join(',') + ',' + last3;
  }

  return isNegative ? `-${formatted}` : formatted;
}
