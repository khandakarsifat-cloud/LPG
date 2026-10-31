const imageTypes = new Set(['image/jpeg', 'image/png', 'image/webp']);

/** Normalize uploads to a bounded raster; original EXIF and filenames stay local. */
export async function compressProductImage(file: File): Promise<Blob> {
  if (!imageTypes.has(file.type)) throw new Error('Choose a JPG, PNG or WebP image.');
  if (file.size > 5 * 1024 * 1024) throw new Error('Choose an image smaller than 5 MB.');
  const objectUrl = URL.createObjectURL(file);
  try {
    const picture = new Image(); picture.src = objectUrl; await picture.decode();
    if (!picture.naturalWidth || picture.naturalWidth * picture.naturalHeight > 24_000_000) throw new Error('Choose an image with at most 24 megapixels.');
    const scale = Math.min(1, 800 / Math.max(picture.naturalWidth, picture.naturalHeight));
    const canvas = document.createElement('canvas');
    canvas.width = Math.max(1, Math.round(picture.naturalWidth * scale)); canvas.height = Math.max(1, Math.round(picture.naturalHeight * scale));
    const context = canvas.getContext('2d');
    if (!context) throw new Error('This browser could not prepare the image.');
    context.drawImage(picture, 0, 0, canvas.width, canvas.height);
    const blob = await new Promise<Blob | null>(resolve => canvas.toBlob(resolve, 'image/webp', .82));
    if (!blob || blob.type !== 'image/webp' || blob.size > 1024 * 1024) throw new Error('The image could not be optimized. Try a smaller image.');
    return blob;
  } finally { URL.revokeObjectURL(objectUrl); }
}
