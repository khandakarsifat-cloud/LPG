import { useLayoutEffect, useRef, type ReactNode } from 'react';
import './record-card.css';

/** Only the product preview clips; identity, statuses and money have their own rows. */
export function CardProductPreview({ children, label }: { children: ReactNode; label: string }) {
  const ref = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    const node = ref.current;
    if (!node) return;
    const measure = () => node.toggleAttribute('data-overflow', node.scrollHeight > node.clientHeight + 1);
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(node);
    if (node.firstElementChild) observer.observe(node.firstElementChild);
    return () => observer.disconnect();
  }, [children]);
  return <div className="card-product-preview" ref={ref} aria-label={label}>
    <div className="purchase-items-list">{children}</div>
  </div>;
}
