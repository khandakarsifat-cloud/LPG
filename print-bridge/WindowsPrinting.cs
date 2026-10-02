using System;
using System.ComponentModel;
using System.Drawing;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.IO;
using System.Runtime.InteropServices;

namespace LPG {
  public static class WindowsPrinting {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public class DocInfo {
      [MarshalAs(UnmanagedType.LPWStr)] public string pDocName;
      [MarshalAs(UnmanagedType.LPWStr)] public string pOutputFile;
      [MarshalAs(UnmanagedType.LPWStr)] public string pDataType;
    }
    [DllImport("winspool.drv", EntryPoint = "OpenPrinterW", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool OpenPrinter(string name, out IntPtr handle, IntPtr defaults);
    [DllImport("winspool.drv", SetLastError = true)] static extern bool ClosePrinter(IntPtr handle);
    [DllImport("winspool.drv", EntryPoint = "StartDocPrinterW", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern int StartDocPrinter(IntPtr handle, int level, [In] DocInfo info);
    [DllImport("winspool.drv", SetLastError = true)] static extern bool StartPagePrinter(IntPtr handle);
    [DllImport("winspool.drv", SetLastError = true)] static extern bool EndPagePrinter(IntPtr handle);
    [DllImport("winspool.drv", SetLastError = true)] static extern bool EndDocPrinter(IntPtr handle);
    [DllImport("winspool.drv", SetLastError = true)] static extern bool AbortPrinter(IntPtr handle);
    [DllImport("winspool.drv", SetLastError = true)]
    static extern bool WritePrinter(IntPtr handle, IntPtr bytes, int count, out int written);
    static void Check(bool ok) { if (!ok) throw new Win32Exception(Marshal.GetLastWin32Error()); }

    public static int Send(string queue, byte[] bytes, string title) {
      IntPtr handle;
      Check(OpenPrinter(queue, out handle, IntPtr.Zero));
      bool started = false;
      IntPtr memory = IntPtr.Zero;
      try {
        int job = StartDocPrinter(handle, 1, new DocInfo { pDocName = title, pDataType = "RAW" });
        if (job == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
        started = true;
        Check(StartPagePrinter(handle));
        memory = Marshal.AllocHGlobal(bytes.Length);
        Marshal.Copy(bytes, 0, memory, bytes.Length);
        int offset = 0;
        while (offset < bytes.Length) {
          int written;
          Check(WritePrinter(handle, IntPtr.Add(memory, offset), Math.Min(16384, bytes.Length - offset), out written));
          if (written <= 0) throw new IOException("Windows accepted no printer data. Check the printer before reprinting.");
          offset += written;
        }
        Check(EndPagePrinter(handle));
        Check(EndDocPrinter(handle));
        started = false;
        return job;
      } finally {
        if (memory != IntPtr.Zero) Marshal.FreeHGlobal(memory);
        if (started) AbortPrinter(handle);
        ClosePrinter(handle);
      }
    }

    // Windows font fallback and shaping preserve Bengali content without printer code-page assumptions.
    // Receipt layout is pixel based; every line wraps within the configured print head width.
    public static byte[] Render(string[] left, string[] right, bool[] bold, bool[] center, int width, bool cut) {
      if (width < 240 || width > 640 || width % 8 != 0) throw new ArgumentException("Invalid printable width.");
      using (var stream = new MemoryStream())
      using (var writer = new BinaryWriter(stream))
      using (var regular = new Font("Segoe UI", 23, FontStyle.Regular, GraphicsUnit.Pixel))
      using (var strong = new Font("Segoe UI", 25, FontStyle.Bold, GraphicsUnit.Pixel))
      using (var measuring = new Bitmap(width, 1))
      using (var measure = Graphics.FromImage(measuring)) {
        writer.Write(new byte[] { 0x1b, 0x40, 0x1d, 0x4c, 0, 0, 0x1d, 0x57, (byte)(width % 256), (byte)(width / 256) });
        for (int i = 0; i < left.Length; i++) {
          Font font = bold[i] ? strong : regular;
          using (var format = new StringFormat()) {
            format.Alignment = center[i] ? StringAlignment.Center : StringAlignment.Near;
            int usable = width - 16;
            bool hasRight = !String.IsNullOrEmpty(right[i]);
            int rightWidth = hasRight ? (int)Math.Ceiling(measure.MeasureString(right[i], font).Width) + 8 : 0;
            bool stacked = rightWidth > usable / 2;
            int leftWidth = hasRight && !stacked ? usable - rightWidth : usable;
            int leftHeight = (int)Math.Ceiling(measure.MeasureString(left[i], font, leftWidth, format).Height) + 6;
            int rightHeight = hasRight ? (int)Math.Ceiling(measure.MeasureString(right[i], font, stacked ? usable : rightWidth).Height) + 6 : 0;
            int height = stacked ? leftHeight + rightHeight : Math.Max(leftHeight, rightHeight);
            if (height > 16000) throw new ArgumentException("Receipt line too long.");
            using (var bitmap = new Bitmap(width, Math.Max(height, 1), PixelFormat.Format24bppRgb)) {
              using (var graphics = Graphics.FromImage(bitmap)) {
                graphics.Clear(Color.White);
                graphics.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
                graphics.DrawString(left[i], font, Brushes.Black, new RectangleF(8, 0, leftWidth, leftHeight), format);
                if (hasRight) {
                  format.Alignment = StringAlignment.Far;
                  graphics.DrawString(right[i], font, Brushes.Black,
                    new RectangleF(stacked ? 8 : 8 + leftWidth, stacked ? leftHeight : 0, stacked ? usable : rightWidth, stacked ? rightHeight : height), format);
                }
              }
              WriteRaster(writer, bitmap);
            }
          }
        }
        writer.Write(new byte[] { 0x1b, 0x64, 4 });
        if (cut) writer.Write(new byte[] { 0x1d, 0x56, 0x01 });
        return stream.ToArray();
      }
    }

    static void WriteRaster(BinaryWriter writer, Bitmap bitmap) {
      var locked = bitmap.LockBits(new Rectangle(0, 0, bitmap.Width, bitmap.Height), ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
      try {
        int rowBytes = bitmap.Width / 8;
        var pixels = new byte[locked.Stride];
        for (int top = 0; top < bitmap.Height; top += 128) {
          int rows = Math.Min(128, bitmap.Height - top);
          writer.Write(new byte[] { 0x1d, 0x76, 0x30, 0, (byte)(rowBytes % 256), (byte)(rowBytes / 256), (byte)rows, 0 });
          for (int y = top; y < top + rows; y++) {
            Marshal.Copy(IntPtr.Add(locked.Scan0, y * locked.Stride), pixels, 0, pixels.Length);
            for (int x = 0; x < bitmap.Width; x += 8) {
              byte value = 0;
              for (int bit = 0; bit < 8; bit++) {
                int p = (x + bit) * 3;
                if ((pixels[p] + pixels[p + 1] + pixels[p + 2]) / 3 < 170) value |= (byte)(0x80 >> bit);
              }
              writer.Write(value);
            }
          }
        }
      } finally { bitmap.UnlockBits(locked); }
    }
  }
}
