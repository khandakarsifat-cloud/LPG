import { useRef, useState } from 'react';
import { Camera, ImagePlus, Package, Trash2 } from 'lucide-react';
import toast from 'react-hot-toast';
import { useProductImage, useProductPhoto, useSaveProductImage } from '../../hooks/useProductImages';
import './product-image.css';

export function ProductImage({ path, name, className = '', preview }: { path?: string | null; name: string; className?: string; preview?: string | null }) {
  const image = useProductImage(preview ? null : path); const src = preview ?? image.data;
  const [failed, setFailed] = useState<string | null>(null);
  return <span className={`product-image ${className}`}>
    {src && src !== failed ? <img src={src} alt={name} width={160} height={120} loading="lazy" decoding="async" onError={() => setFailed(src)} /> : <span className="product-image-fallback" role="img" aria-label={`${name} · ${path ? 'Image unavailable' : 'No product photo'}`}><Package size={24} /></span>}
  </span>;
}

export function ProductPhotoField({ photo, disabled = false }: { photo: ReturnType<typeof useProductPhoto>; disabled?: boolean }) {
  const input = useRef<HTMLInputElement>(null);
  return <div className="product-photo-field"><span className="input-label">Product photo <small>(optional)</small></span>
    {photo.path || photo.preview ? <ProductImage path={photo.path} preview={photo.preview} name="Product preview" className="product-photo-preview" /> : <button type="button" aria-label="Add product photo" className="product-photo-upload" disabled={disabled} onClick={() => input.current?.click()}><ImagePlus size={26} /><span>Add product photo</span><small>JPG, PNG or WebP · up to 5 MB</small></button>}
    <div className="product-photo-actions">{(photo.path || photo.preview) && <><button type="button" className="btn btn-secondary" disabled={disabled} onClick={() => input.current?.click()}><Camera size={14} />Replace</button><button type="button" className="btn btn-ghost" disabled={disabled} onClick={() => { photo.choose(null); if (input.current) input.current.value = ''; }}><Trash2 size={14} />Remove</button></>}</div>
    <input ref={input} type="file" accept="image/jpeg,image/png,image/webp" aria-label="Upload product photo" hidden disabled={disabled} onChange={e => { const file = e.target.files?.[0]; if (file) photo.choose(file); e.currentTarget.value = ''; }} />
    {photo.error && <p className="payment-error" role="alert">{photo.error}</p>}
  </div>;
}

export function ProductPhotoEditor({ itemId, path }: { itemId: string; path?: string | null }) {
  const photo = useProductPhoto(path); const save = useSaveProductImage(); const busy = photo.busy || save.isPending;
  return <section className="product-section product-photo-editor"><h3>Product photo</h3><ProductPhotoField photo={photo} disabled={busy} />
    {photo.changed && <button className="btn btn-secondary" disabled={busy} onClick={async () => { try { const next = await photo.prepare(); await save.mutateAsync({ itemId, path: next }); await photo.committed(next); toast.success('Product photo saved'); } catch { /* Inline upload or save error. */ } }}>{busy ? 'Saving…' : 'Save photo'}</button>}
    {save.error && <p role="alert" className="payment-error">{save.error.message}</p>}
  </section>;
}
