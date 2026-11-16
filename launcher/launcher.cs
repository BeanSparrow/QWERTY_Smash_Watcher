// SmashWatcher.exe: starts SmashWatcher.ps1 from the same folder without a console window.
// Built by make_exe.bat with the C# compiler that ships with Windows. Only rebuild it if this file changes.
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;

class Launcher
{
    static void Main()
    {
        string dir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        string script = Path.Combine(dir, "SmashWatcher.ps1");
        if (!File.Exists(script))
        {
            // Older versions used this name.
            string old = Path.Combine(dir, "smash_watcher.ps1");
            if (File.Exists(old)) script = old;
        }
        ProcessStartInfo psi = new ProcessStartInfo("powershell.exe",
            "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"" + script + "\"");
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.WorkingDirectory = dir;
        Process.Start(psi);
    }
}
