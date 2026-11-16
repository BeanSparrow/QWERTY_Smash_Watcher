using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;

class Launcher {
    static void Main() {
        string dir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        ProcessStartInfo psi = new ProcessStartInfo("powershell.exe",
            "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"" + Path.Combine(dir, "smash_watcher.ps1") + "\"");
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.WorkingDirectory = dir;
        Process.Start(psi);
    }
}
