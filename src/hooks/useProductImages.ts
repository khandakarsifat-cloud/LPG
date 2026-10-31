import { useEffect, useRef, useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useAuth } from '../contexts/AuthContext';
import { supabase } from '../lib/supabase';
import { compressProductImage } from '../lib/imageCompression';

export function useProductImage(path: string | null | undefined) {
  const { profile, user } = useAuth();
  return useQuery({ queryKey: ['product-image', profile?.tenant_id, user?.id, path], enabled: Boolean(path && profile && user), staleTime: 30 * 60_000, gcTime: 60 * 60_000, refetchInterval: 30 * 60_000, retry: 1,
    queryFn: async () => { if (!path) return null; const { data, error } = await supabase.storage.from('product-images').createSignedUrl(path, 3600); if (error) throw error; return data.signedUrl; },
  });
}

export function useProductPhoto(initialPath: string | null = null) {
  const { profile } = useAuth();
  const [path, setPath] = useState(initialPath); const [file, setFile] = useState<File | null>(null);
  const [baseline, setBaseline] = useState(initialPath);
  const [preview, setPreview] = useState<string | null>(null); const [error, setError] = useState(''); const [busy, setBusy] = useState(false);
  const uploaded = useRef<string | null>(null);
  const mounted = useRef(false);
  useEffect(() => {
    mounted.current = true;
    return () => { mounted.current = false; if (uploaded.current) void supabase.storage.from('product-images').remove([uploaded.current]); };
  }, []);
  useEffect(() => () => { if (preview) URL.revokeObjectURL(preview); }, [preview]);
  function choose(next: File | null) {
    setError('');
    if (next && (!['image/jpeg', 'image/png', 'image/webp'].includes(next.type) || next.size > 5 * 1024 * 1024)) { setError('Choose a JPG, PNG or WebP image smaller than 5 MB.'); return; }
    if (uploaded.current) void supabase.storage.from('product-images').remove([uploaded.current]);
    uploaded.current = null; setFile(next); setPreview(next ? URL.createObjectURL(next) : null); if (!next) setPath(null);
  }
  async function prepare() {
    if (!file) return path;
    if (uploaded.current) return uploaded.current;
    if (!profile) throw new Error('Sign in before uploading a product image.');
    setBusy(true); setError('');
    try {
      const body = await compressProductImage(file); const objectPath = `${profile.tenant_id}/${crypto.randomUUID()}.webp`;
      const { error: uploadError } = await supabase.storage.from('product-images').upload(objectPath, body, { contentType: 'image/webp', cacheControl: '3600', upsert: false });
      if (uploadError) throw uploadError;
      if (!mounted.current) { await supabase.storage.from('product-images').remove([objectPath]); throw new Error('The product dialog closed before its photo was saved.'); }
      uploaded.current = objectPath; return objectPath;
    } catch (cause) { const message = cause instanceof Error ? cause.message : 'Image upload failed. Try again.'; setError(message); throw new Error(message, { cause }); }
    finally { setBusy(false); }
  }
  async function committed(next: string | null) {
    const previous = baseline; setPath(next); setBaseline(next); setFile(null); setPreview(null); uploaded.current = null;
    if (previous && previous !== next) await supabase.storage.from('product-images').remove([previous]);
  }
  return { path, preview, error, busy, choose, prepare, committed, changed: Boolean(file) || path !== baseline };
}

export function useSaveProductImage() {
  const qc = useQueryClient();
  return useMutation({ mutationFn: async ({ itemId, path }: { itemId: string; path: string | null }) => { const { error } = await supabase.rpc('set_product_image', { p_item_id: itemId, p_image_path: path }); if (error) throw new Error(error.message); },
    onSuccess: () => Promise.all([['inventory'], ['price_books'], ['purchases'], ['sales'], ['dashboard']].map(queryKey => qc.invalidateQueries({ queryKey }))),
  });
}
