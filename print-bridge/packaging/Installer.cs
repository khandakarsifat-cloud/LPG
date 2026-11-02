using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.ServiceProcess;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace LPG.PrintBridge {
    internal static class Installer {
        private static bool quiet;
        private static string Sc { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "sc.exe"); } }
        private static int Main(string[] args) {
            quiet = args.Contains("--quiet");
            if (args.Any(arg => arg != "--quiet")) return 2;
            bool installed = Common.Installed();
            bool wasRunning = false;
            string executable = Path.Combine(Common.InstallDirectory, "LPG Print Bridge.exe");
            string previous = executable + ".previous";
            bool replaced = false;
            try {
                Common.SecureDirectory(Common.InstallDirectory, true);
                Common.SecureDirectory(Path.GetDirectoryName(Common.DataDirectory), false);
                Common.SecureDataTree(Common.DataDirectory);
                if (installed) {
                    using (var service = new ServiceController(Common.ServiceName)) {
                        wasRunning = service.Status != ServiceControllerStatus.Stopped;
                        if (wasRunning) {
                            if (service.Status != ServiceControllerStatus.StopPending) service.Stop();
                            service.WaitForStatus(ServiceControllerStatus.Stopped, TimeSpan.FromSeconds(50));
                        }
                    }
                }
                // Never import a journal while a source/portable bridge might still be sending.
                foreach (int port in new[] { 17891, 17892 }) {
                    var check = new TcpListener(IPAddress.Loopback, port);
                    try { check.Server.ExclusiveAddressUse = true; check.Start(); }
                    catch { throw new IOException("Close the old source/portable print bridge, then run Setup again. Port " + port + " is in use."); }
                    finally { check.Stop(); }
                }
                ImportLegacy();
                if (File.Exists(executable)) { Common.NoLinks(previous); File.Delete(previous); File.Copy(executable, previous); }
                Common.ResourceToFile("bridge.exe", executable + ".new");
                replaced = true;
                if (File.Exists(executable)) File.Delete(executable);
                File.Move(executable + ".new", executable);
                Common.ResourceToFile("restart.exe", Path.Combine(Common.InstallDirectory, "Restart LPG Print Bridge.exe"));
                Common.ResourceToFile("installation.md", Path.Combine(Common.InstallDirectory, "INSTALLATION.md"));
                Common.ResourceToFile("node-license", Path.Combine(Common.InstallDirectory, "NODE-LICENSE.txt"));

                string registration = " binPath= \"\\\"" + executable + "\\\" --service\" start= auto obj= LocalSystem depend= Spooler DisplayName= \"LPG Print Bridge\"";
                Common.Run(Sc, (installed ? "config " : "create ") + Common.ServiceName + registration);
                Common.Run(Sc, "description " + Common.ServiceName + " \"Silent local LPG USB and Ethernet receipt printing.\"");
                Common.Run(Sc, "failure " + Common.ServiceName + " reset= 86400 actions= restart/5000/restart/15000/restart/60000");
                Common.Run(Sc, "failureflag " + Common.ServiceName + " 1");
                string current;
                using (var reader = new StreamReader(System.Reflection.Assembly.GetExecutingAssembly().GetManifestResourceStream("runtime.id"))) current = reader.ReadToEnd().Trim();
                // Re-extract trusted embedded assets after every installation, even over an existing cache.
                string marker = Path.Combine(Common.DataDirectory, "runtime", current, ".complete");
                Common.NoLinks(marker);
                if (File.Exists(marker)) File.Delete(marker);
                Common.Restart(false);
                File.WriteAllText(Path.Combine(Common.DataDirectory, ".legacy-imported"), "Imported before service startup. Original per-user history was preserved.");
                if (File.Exists(previous)) File.Delete(previous);
                // Keep one current extracted runtime. Settings, logs and every job record remain.
                string runtime = Path.Combine(Common.DataDirectory, "runtime");
                if (Directory.Exists(runtime)) foreach (string directory in Directory.GetDirectories(runtime)) {
                    if (Path.GetFileName(directory) == current) continue;
                    Common.NoLinks(directory);
                    foreach (string file in Directory.GetFiles(directory)) Common.NoLinks(file);
                    // Only remove known flat runtime caches; never follow or delete arbitrary trees.
                    if (Directory.GetDirectories(directory).Length == 0) {
                        foreach (string file in Directory.GetFiles(directory)) File.Delete(file);
                        Directory.Delete(directory);
                    }
                }
                if (!quiet) MessageBox.Show("LPG Print Bridge is installed and running. It starts before Windows login and restarts after crashes.\n\nUse POS Printer in LPG Manager as usual. To restart manually, run Restart LPG Print Bridge.exe from:\n" + Common.InstallDirectory,
                    "LPG Print Bridge Setup", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return 0;
            } catch (Exception error) {
                // Restore the previous executable if an update fails. Never roll back or delete jobs.
                try {
                    if (replaced && File.Exists(previous)) {
                        using (var service = new ServiceController(Common.ServiceName)) {
                            if (service.Status != ServiceControllerStatus.Stopped) { service.Stop(); service.WaitForStatus(ServiceControllerStatus.Stopped, TimeSpan.FromSeconds(50)); }
                        }
                        File.Copy(previous, executable, true);
                    }
                    if (installed && wasRunning) Common.Restart(false);
                } catch { }
                string message = error is IOException ? error.Message : "Windows could not install/start the bridge. Check administrator access, Print Spooler, service state and the protected ProgramData bridge.log.";
                try { File.WriteAllText(Path.Combine(Common.DataDirectory, "setup-error.txt"), message); } catch { }
                if (!quiet) MessageBox.Show(message, "LPG Print Bridge Setup", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 1;
            }
        }

        private static void ImportLegacy() {
            Common.NoLinks(Common.LegacyDirectory);
            string destination = Path.Combine(Common.DataDirectory, "jobs");
            Common.SecureDirectory(destination, false);
            string source = Path.Combine(Common.LegacyDirectory, "jobs");
            Common.NoLinks(source);
            if (!File.Exists(Path.Combine(Common.DataDirectory, ".legacy-imported")) && Directory.Exists(source)) {
                foreach (string file in Directory.GetFiles(source, "*.json")) {
                    Guid id;
                    if (!Guid.TryParseExact(Path.GetFileNameWithoutExtension(file), "D", out id)) throw new IOException("Unrecognized legacy journal filename. Preserve it and inspect before installing.");
                    Common.NoLinks(file);
                    string target = Path.Combine(destination, Path.GetFileName(file));
                    Common.NoLinks(target);
                    byte[] bytes = File.ReadAllBytes(file);
                    if (File.Exists(target)) {
                        if (!bytes.SequenceEqual(File.ReadAllBytes(target))) throw new IOException("Legacy and service job history conflict. Preserve both journals and reconcile before updating.");
                    } else File.WriteAllBytes(target, bytes);
                }
            }
            string settings = Path.Combine(Common.DataDirectory, "settings.json");
            Common.NoLinks(settings);
            if (!File.Exists(settings)) {
                string legacy = Path.Combine(Common.LegacyDirectory, "settings.json");
                Common.NoLinks(legacy);
                if (File.Exists(legacy)) File.Copy(legacy, settings);
                else {
                    var values = new Dictionary<string, string>();
                    foreach (string name in new[] { "LPG_PRINT_ORIGINS", "LPG_PRINT_HOST", "LPG_PRINT_TLS_CERT", "LPG_PRINT_TLS_KEY", "LPG_PRINT_TOKEN", "LPG_PRINT_DIAGNOSTICS" }) {
                        string value = Environment.GetEnvironmentVariable(name);
                        if (!String.IsNullOrEmpty(value)) values[name] = value;
                    }
                    File.WriteAllText(settings, new JavaScriptSerializer().Serialize(values));
                }
            }
        }
    }
}
