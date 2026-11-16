// Native helpers for Smash Watcher: window listing and capture, image prep for OCR, and string distance.
// Compiled at startup by PowerShell's Add-Type (C# 5, .NET Framework), so no build step is needed.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;

namespace SmashWatcher
{
    public class WindowInfo
    {
        public IntPtr Handle;
        public string Title;
        public bool Minimized;
    }

    public static class Native
    {
        [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
        delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
        [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hWnd);
        [DllImport("user32.dll")] static extern bool IsIconic(IntPtr hWnd);
        [DllImport("user32.dll")] static extern bool IsWindow(IntPtr hWnd);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int max);
        [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr hWnd);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
        [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
        [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr hWnd, out RECT r);
        [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr hWnd, IntPtr hdc, uint flags);
        [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr hWnd, int attr, out int value, int size);

        const uint PW_CLIENTONLY = 1;
        const uint PW_RENDERFULLCONTENT = 2;
        const int DWMWA_CLOAKED = 14;

        public static void MakeDpiAware() { try { SetProcessDPIAware(); } catch { } }

        // Top-level windows a person could pick: visible, titled, not hidden by Windows, not this app.
        public static List<WindowInfo> ListWindows()
        {
            List<WindowInfo> list = new List<WindowInfo>();
            uint self = (uint)System.Diagnostics.Process.GetCurrentProcess().Id;
            EnumWindowsProc cb = delegate (IntPtr h, IntPtr l)
            {
                if (!IsWindowVisible(h)) return true;
                int n = GetWindowTextLength(h);
                if (n == 0) return true;
                uint pid; GetWindowThreadProcessId(h, out pid);
                if (pid == self) return true;
                int cloaked = 0;
                try { DwmGetWindowAttribute(h, DWMWA_CLOAKED, out cloaked, 4); } catch { }
                if (cloaked != 0) return true;
                bool min = IsIconic(h);
                if (!min)
                {
                    RECT r; GetClientRect(h, out r);
                    if (r.Right - r.Left < 160 || r.Bottom - r.Top < 90) return true;
                }
                StringBuilder sb = new StringBuilder(n + 1);
                GetWindowText(h, sb, n + 1);
                WindowInfo w = new WindowInfo();
                w.Handle = h; w.Title = sb.ToString(); w.Minimized = min;
                list.Add(w);
                return true;
            };
            EnumWindows(cb, IntPtr.Zero);
            GC.KeepAlive(cb);
            return list;
        }

        // Captures a window's contents even when other windows cover it. It must not be minimized.
        public static Bitmap CaptureWindow(IntPtr h)
        {
            if (!IsWindow(h)) throw new Exception("That window has closed. Press Refresh and pick it again.");
            if (IsIconic(h)) throw new Exception("That window is minimized. Restore it; it can sit behind other windows, just not minimized.");
            RECT r;
            if (!GetClientRect(h, out r)) throw new Exception("Couldn't read that window's size.");
            int w = r.Right - r.Left, ht = r.Bottom - r.Top;
            if (w < 8 || ht < 8) throw new Exception("That window has no visible area.");
            Bitmap bmp = new Bitmap(w, ht, PixelFormat.Format32bppArgb);
            bool ok;
            using (Graphics g = Graphics.FromImage(bmp))
            {
                IntPtr hdc = g.GetHdc();
                try { ok = PrintWindow(h, hdc, PW_CLIENTONLY | PW_RENDERFULLCONTENT); }
                finally { g.ReleaseHdc(hdc); }
            }
            if (!ok) { bmp.Dispose(); throw new Exception("Windows couldn't capture that window."); }
            if (!OpaqueAndCheck(bmp))
            {
                bmp.Dispose();
                throw new Exception("That window came back blank (all black). Some apps can't be captured this way; use 'Set region' instead.");
            }
            return bmp;
        }

        // Forces alpha to 255 (PrintWindow can leave it at 0). Returns false if the image is entirely black.
        static bool OpaqueAndCheck(Bitmap bmp)
        {
            Rectangle rc = new Rectangle(0, 0, bmp.Width, bmp.Height);
            BitmapData d = bmp.LockBits(rc, ImageLockMode.ReadWrite, PixelFormat.Format32bppArgb);
            int len = Math.Abs(d.Stride) * bmp.Height;
            byte[] buf = new byte[len];
            Marshal.Copy(d.Scan0, buf, 0, len);
            int max = 0;
            for (int i = 0; i < len; i += 4)
            {
                buf[i + 3] = 255;
                int v = buf[i] | buf[i + 1] | buf[i + 2];
                if (v > max) max = v;
            }
            Marshal.Copy(buf, 0, d.Scan0, len);
            bmp.UnlockBits(d);
            return max > 8;
        }

        // Prepares a frame for OCR: enlarges it, converts to grayscale, and stretches the contrast so that
        // dim screens (for example a darkened replay) read like bright ones.
        public static Bitmap Enhance(Bitmap src, double scale, bool stretch)
        {
            int W = Math.Max(1, (int)Math.Round(src.Width * scale));
            int H = Math.Max(1, (int)Math.Round(src.Height * scale));
            Bitmap dst = new Bitmap(W, H, PixelFormat.Format32bppArgb);
            using (Graphics g = Graphics.FromImage(dst))
            {
                g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                g.DrawImage(src, new Rectangle(0, 0, W, H));
            }
            if (!stretch) return dst;

            Rectangle rc = new Rectangle(0, 0, W, H);
            BitmapData d = dst.LockBits(rc, ImageLockMode.ReadWrite, PixelFormat.Format32bppArgb);
            int stride = Math.Abs(d.Stride);
            byte[] buf = new byte[stride * H];
            Marshal.Copy(d.Scan0, buf, 0, buf.Length);
            int[] hist = new int[256];
            for (int y = 0; y < H; y++)
            {
                int row = y * stride;
                for (int x = 0; x < W; x++)
                {
                    int i = row + x * 4;
                    hist[(buf[i] * 29 + buf[i + 1] * 150 + buf[i + 2] * 77) >> 8]++;
                }
            }
            long total = (long)W * H, acc = 0;
            int lo = 0, hi = 255;
            for (int v = 0; v < 256; v++) { acc += hist[v]; if (acc >= total / 100) { lo = v; break; } }
            acc = 0;
            for (int v = 255; v >= 0; v--) { acc += hist[v]; if (acc >= total / 200) { hi = v; break; } }
            byte[] map = new byte[256];
            int span = Math.Max(1, hi - lo);
            for (int v = 0; v < 256; v++) map[v] = (byte)Math.Max(0, Math.Min(255, (v - lo) * 255 / span));
            for (int y = 0; y < H; y++)
            {
                int row = y * stride;
                for (int x = 0; x < W; x++)
                {
                    int i = row + x * 4;
                    byte gv = map[(buf[i] * 29 + buf[i + 1] * 150 + buf[i + 2] * 77) >> 8];
                    buf[i] = gv; buf[i + 1] = gv; buf[i + 2] = gv; buf[i + 3] = 255;
                }
            }
            Marshal.Copy(buf, 0, d.Scan0, buf.Length);
            dst.UnlockBits(d);
            return dst;
        }

        // Edit distance, used to match stat labels the OCR slightly misread.
        public static int Lev(string a, string b)
        {
            int n = a.Length, m = b.Length;
            if (n == 0) return m;
            if (m == 0) return n;
            int[] prev = new int[m + 1], cur = new int[m + 1];
            for (int j = 0; j <= m; j++) prev[j] = j;
            for (int i = 1; i <= n; i++)
            {
                cur[0] = i;
                for (int j = 1; j <= m; j++)
                {
                    int cost = a[i - 1] == b[j - 1] ? 0 : 1;
                    cur[j] = Math.Min(Math.Min(cur[j - 1] + 1, prev[j] + 1), prev[j - 1] + cost);
                }
                int[] t = prev; prev = cur; cur = t;
            }
            return prev[m];
        }
    }
}
