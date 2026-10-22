import { formatReceipt } from '../../lib/receipt';
import type { ReceiptData } from '../../types/receipt';
import './receipt.css';

export function ReceiptPreview({ receipt, width = 80 }: { receipt: ReceiptData; width?: 58 | 80 }) {
  return <div className={`receipt-preview receipt-${width}`} aria-label={`${width}mm receipt preview`}>
    {formatReceipt(receipt, width).map((line, index) => /^─+$/.test(line.text) ? <div className="receipt-divider" key={index} /> :
      <div className={`receipt-line${line.bold ? ' receipt-bold' : ''}${line.center ? ' receipt-center' : ''}`} key={index}><span>{line.text}</span>{line.right && <span className="receipt-amount">{line.right}</span>}</div>)}
  </div>;
}
