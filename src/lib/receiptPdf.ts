import jsPDF from 'jspdf';
import { formatBDT } from './formatBDT';

export interface ReceiptItem {
  name: string;
  type: 'refill' | 'package' | 'empty_return';
  quantity: number;
  unit_price: number;
  line_total: number;
}

export interface ReceiptData {
  sale_id: string;
  created_at: string;
  shop_name?: string;
  customer_name: string;
  customer_phone: string;
  customer_tier: string;
  items: ReceiptItem[];
  subtotal: number;
  discount_amount: number;
  exchange_fee: number;
  total_amount: number;
  notes?: string;
}

const PAGE_WIDTH_MM = 80;    // 78mm paper, 1mm margin each side
const CONTENT_W    = 72;     // usable width (mm)
const MARGIN_LEFT  = 4;
const FONT_NORMAL  = 7.5;
const FONT_SMALL   = 6.5;
const FONT_LARGE   = 10;
const LINE_H       = 4.5;    // mm between lines

const TYPE_LABELS: Record<string, string> = {
  refill:       'Refill',
  package:      'New Pkg',
  empty_return: 'Empty Rtn',
};

function hLine(doc: jsPDF, y: number) {
  doc.setDrawColor(180, 180, 180);
  doc.setLineWidth(0.2);
  doc.line(MARGIN_LEFT, y, MARGIN_LEFT + CONTENT_W, y);
}

function dashedLine(doc: jsPDF, y: number) {
  doc.setDrawColor(180, 180, 180);
  doc.setLineWidth(0.2);
  doc.setLineDashPattern([1.5, 1.5], 0);
  doc.line(MARGIN_LEFT, y, MARGIN_LEFT + CONTENT_W, y);
  doc.setLineDashPattern([], 0);
}

function row(doc: jsPDF, y: number, left: string, right: string, bold = false) {
  if (bold) doc.setFont('helvetica', 'bold');
  else      doc.setFont('helvetica', 'normal');
  doc.setFontSize(FONT_NORMAL);
  doc.text(left,  MARGIN_LEFT,                  y);
  doc.text(right, MARGIN_LEFT + CONTENT_W, y, { align: 'right' });
  return y + LINE_H;
}

export function generateReceiptPDF(data: ReceiptData): jsPDF {
  const doc = new jsPDF({
    unit:        'mm',
    format:      [PAGE_WIDTH_MM, 297], // tall enough; will auto-trim via autoPrint
    orientation: 'portrait',
  });

  let y = 6;

  // ── Header ──────────────────────────────────────────────────────────────────
  doc.setFont('helvetica', 'bold');
  doc.setFontSize(FONT_LARGE);
  doc.text(data.shop_name || 'Gas Dealership', PAGE_WIDTH_MM / 2, y, { align: 'center' });
  y += LINE_H + 1;

  doc.setFont('helvetica', 'normal');
  doc.setFontSize(FONT_SMALL);
  doc.text('Official Sales Receipt', PAGE_WIDTH_MM / 2, y, { align: 'center' });
  y += LINE_H;

  // Date & Receipt No
  const dt = new Date(data.created_at);
  const dateStr = dt.toLocaleDateString('en-BD', {
    year: 'numeric', month: 'short', day: '2-digit',
    hour: '2-digit', minute: '2-digit', hour12: true,
  });
  doc.setFontSize(FONT_SMALL);
  doc.text(dateStr, PAGE_WIDTH_MM / 2, y, { align: 'center' });
  y += LINE_H;
  doc.text(`Receipt: #${data.sale_id.slice(0, 8).toUpperCase()}`, PAGE_WIDTH_MM / 2, y, { align: 'center' });
  y += LINE_H;

  dashedLine(doc, y); y += 2;

  // ── Customer ─────────────────────────────────────────────────────────────────
  doc.setFont('helvetica', 'bold');
  doc.setFontSize(FONT_SMALL);
  doc.text('CUSTOMER', MARGIN_LEFT, y);
  y += LINE_H - 0.5;

  doc.setFont('helvetica', 'normal');
  doc.setFontSize(FONT_NORMAL);
  doc.text(data.customer_name, MARGIN_LEFT, y);
  doc.text(data.customer_tier.toUpperCase(), MARGIN_LEFT + CONTENT_W, y, { align: 'right' });
  y += LINE_H;
  doc.text(`Ph: ${data.customer_phone}`, MARGIN_LEFT, y);
  y += LINE_H;

  dashedLine(doc, y); y += 2;

  // ── Items table header ────────────────────────────────────────────────────────
  doc.setFont('helvetica', 'bold');
  doc.setFontSize(FONT_SMALL);
  doc.text('ITEM',      MARGIN_LEFT,          y);
  doc.text('TYPE',      MARGIN_LEFT + 34,     y);
  doc.text('QTY',       MARGIN_LEFT + 50,     y, { align: 'right' });
  doc.text('PRICE',     MARGIN_LEFT + 59,     y, { align: 'right' });
  doc.text('TOTAL',     MARGIN_LEFT + CONTENT_W, y, { align: 'right' });
  y += LINE_H - 0.5;

  hLine(doc, y); y += 1.5;

  // ── Item rows ─────────────────────────────────────────────────────────────────
  doc.setFont('helvetica', 'normal');
  doc.setFontSize(FONT_NORMAL);
  for (const item of data.items) {
    const typeLabel = TYPE_LABELS[item.type] ?? item.type;
    const priceStr = item.type === 'empty_return' ? 'Free' : formatBDT(item.unit_price);
    const totalStr = item.type === 'empty_return' ? '-' : formatBDT(item.line_total);

    // Wrap long names
    const nameParts = doc.splitTextToSize(item.name, 30) as string[];
    doc.text(nameParts[0],  MARGIN_LEFT,               y);
    doc.text(typeLabel,     MARGIN_LEFT + 34,           y);
    doc.text(`x${item.quantity}`,  MARGIN_LEFT + 50,   y, { align: 'right' });
    doc.text(priceStr,      MARGIN_LEFT + 59,           y, { align: 'right' });
    doc.text(totalStr,      MARGIN_LEFT + CONTENT_W,   y, { align: 'right' });
    y += LINE_H;

    // If name wrapped, print extra lines
    for (let i = 1; i < nameParts.length; i++) {
      doc.text(nameParts[i], MARGIN_LEFT, y);
      y += LINE_H;
    }
  }

  hLine(doc, y); y += 1.5;

  // ── Totals ────────────────────────────────────────────────────────────────────
  y = row(doc, y, 'Subtotal', formatBDT(data.subtotal));
  if (data.discount_amount > 0) {
    y = row(doc, y, 'Discount', `-${formatBDT(data.discount_amount)}`);
  }
  if (data.exchange_fee > 0) {
    y = row(doc, y, 'Exchange Fee', formatBDT(data.exchange_fee));
  }

  y += 0.5;
  hLine(doc, y); y += 1.5;

  doc.setFont('helvetica', 'bold');
  doc.setFontSize(FONT_LARGE - 1);
  doc.text('TOTAL', MARGIN_LEFT, y);
  doc.text(formatBDT(data.total_amount), MARGIN_LEFT + CONTENT_W, y, { align: 'right' });
  y += LINE_H + 1;

  if (data.notes) {
    dashedLine(doc, y); y += 2;
    doc.setFont('helvetica', 'italic');
    doc.setFontSize(FONT_SMALL);
    const noteLines = doc.splitTextToSize(`Note: ${data.notes}`, CONTENT_W) as string[];
    noteLines.forEach(l => { doc.text(l, MARGIN_LEFT, y); y += LINE_H - 0.5; });
    y += 1;
  }

  dashedLine(doc, y); y += 2;

  // ── Footer ─────────────────────────────────────────────────────────────────────
  doc.setFont('helvetica', 'bold');
  doc.setFontSize(FONT_NORMAL);
  doc.text('Thank you for your business!', PAGE_WIDTH_MM / 2, y, { align: 'center' });
  y += LINE_H;
  doc.setFont('helvetica', 'normal');
  doc.setFontSize(FONT_SMALL);
  doc.text('Powered by LPG Manager', PAGE_WIDTH_MM / 2, y, { align: 'center' });
  y += LINE_H + 2;

  return doc;
}

export function printReceipt(data: ReceiptData) {
  const doc = generateReceiptPDF(data);
  doc.autoPrint();
  const blob = doc.output('bloburl');
  const w = window.open(blob as unknown as string, '_blank');
  if (!w) {
    // Fallback: download
    doc.save(`receipt-${data.sale_id.slice(0, 8)}.pdf`);
  }
}
