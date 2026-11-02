using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.ServiceProcess;
using System.Threading;

namespace LPG.PrintBridge {
    internal sealed class BridgeHost : ServiceBase {
        private Process child;
        private IntPtr job;
        private Mutex singleton;
        private bool ownsMutex;
        private Thread mutexThread;
        private readonly ManualResetEvent releaseMutex = new ManualResetEvent(false);
        private volatile bool stopping;
        private string data;
        private readonly object logLock = new object();

        private static int Main(string[] args) {
            try {
                if (args.Length == 1 && args[0] == "--service") {
                    ServiceBase.Run(new BridgeHost { ServiceName = Common.ServiceName, AutoLog = false, CanShutdown = true });
                    return 0;
                }
                if (args.Length == 1 && args[0] == "--restart") { Common.Restart(true); return 0; }
                if (args.Length == 0 && Common.Installed()) { Common.Restart(false); return 0; }
                if (args.Length > 0 && !(args.Length == 1 && args[0] == "--portable")) return 2;
                using (var host = new BridgeHost()) {
                    host.StartBridge(false);
                    if (host.child != null) host.child.WaitForExit();
                    host.StopBridge();
                }
                return 0;
            } catch {
                // The service and portable application deliberately never open UI or a console.
                return 1;
            }
        }

        protected override void OnStart(string[] args) {
            RequestAdditionalTime(30000);
            StartBridge(true);
        }
        protected override void OnStop() {
            RequestAdditionalTime(50000);
            StopBridge();
        }
        protected override void OnShutdown() { StopBridge(); }

        private void StartBridge(bool service) {
            data = service ? Common.DataDirectory : Environment.GetEnvironmentVariable("LPG_PRINT_DATA_DIR") ?? Common.LegacyDirectory;
            Common.NoLinks(data);
            Directory.CreateDirectory(data);
            var security = new MutexSecurity();
            security.AddAccessRule(new MutexAccessRule(new SecurityIdentifier(WellKnownSidType.WorldSid, null),
                MutexRights.Synchronize | MutexRights.Modify, AccessControlType.Allow));
            bool created;
            singleton = new Mutex(false, @"Global\LPGManager.PrintBridge.v1", out created, security);
            var acquired = new ManualResetEvent(false);
            mutexThread = new Thread(() => {
                try { ownsMutex = singleton.WaitOne(0); }
                catch (AbandonedMutexException) { ownsMutex = true; }
                acquired.Set();
                if (ownsMutex) { releaseMutex.WaitOne(); singleton.ReleaseMutex(); }
            }) { IsBackground = true };
            mutexThread.Start(); acquired.WaitOne(); acquired.Dispose();
            if (!ownsMutex) {
                if (service) throw new IOException("Another bridge is already running.");
                return;
            }
            string runtime = ExtractRuntime();
            var start = new ProcessStartInfo(Path.Combine(runtime, "node.exe"), "--disable-warning=ExperimentalWarning --max-old-space-size=96 \"" + Path.Combine(runtime, "bridge.mjs") + "\"") {
                WorkingDirectory = runtime, UseShellExecute = false, CreateNoWindow = true,
                RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true
            };
            start.EnvironmentVariables.Remove("NODE_OPTIONS");
            start.EnvironmentVariables.Remove("NODE_PATH");
            start.EnvironmentVariables["LPG_PRINT_DATA_DIR"] = data;
            start.EnvironmentVariables["LPG_PRINT_MANAGED"] = "1";
            job = CreateJobObject(IntPtr.Zero, null);
            var limits = new ExtendedLimits();
            limits.Basic.LimitFlags = 0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
            if (job == IntPtr.Zero || !SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf(limits)))
                throw new IOException("Cannot create bridge process containment.");
            child = new Process { StartInfo = start };
            var ready = new ManualResetEvent(false);
            child.OutputDataReceived += (sender, line) => {
                if (line.Data != null) { Log(line.Data); if (line.Data == "LPG print bridge ready. Dashboard Refresh rescans printers.") ready.Set(); }
            };
            child.ErrorDataReceived += (sender, line) => { if (line.Data != null) Log(line.Data); };
            child.Start();
            if (!AssignProcessToJobObject(job, child.Handle)) { child.Kill(); throw new IOException("Cannot contain bridge process."); }
            child.BeginOutputReadLine(); child.BeginErrorReadLine();
            child.Exited += (sender, e) => {
                if (!stopping) { Log("Bridge process stopped unexpectedly; Windows service recovery will restart it."); Environment.Exit(1); }
            };
            child.EnableRaisingEvents = true;
            child.StandardInput.WriteLine("start"); child.StandardInput.Flush();
            if (!ready.WaitOne(20000)) { StopBridge(); throw new IOException("Bridge did not become ready. Inspect bridge.log."); }
            // Keep the small event alive until the redirected output stream is closed.
        }

        private string ExtractRuntime() {
            string id;
            var assembly = Assembly.GetExecutingAssembly();
            using (var reader = new StreamReader(assembly.GetManifestResourceStream("runtime.id"))) id = reader.ReadToEnd().Trim();
            string directory = Path.Combine(data, "runtime", id);
            Common.NoLinks(directory);
            if (File.Exists(Path.Combine(directory, ".complete")) && File.Exists(Path.Combine(directory, "node.exe")) && File.Exists(Path.Combine(directory, "bridge.mjs")) && File.Exists(Path.Combine(directory, "windows.ps1")) && File.Exists(Path.Combine(directory, "WindowsPrinting.cs"))) return directory;
            Directory.CreateDirectory(directory);
            using (var source = assembly.GetManifestResourceStream("runtime.zip"))
            using (var archive = new ZipArchive(source, ZipArchiveMode.Read)) {
                foreach (var entry in archive.Entries) {
                    if (Path.GetFileName(entry.FullName) != entry.FullName) throw new IOException("Invalid runtime asset.");
                    string path = Path.Combine(directory, entry.FullName);
                    Common.NoLinks(path);
                    File.Delete(path);
                    using (var input = entry.Open())
                    using (var output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None)) input.CopyTo(output);
                }
            }
            File.WriteAllText(Path.Combine(directory, ".complete"), id);
            return directory;
        }

        private void Log(string text) {
            lock (logLock) {
                try {
                    string path = Path.Combine(data, "bridge.log");
                    Common.NoLinks(path);
                    if (File.Exists(path) && new FileInfo(path).Length >= 256 * 1024) {
                        Common.NoLinks(path + ".1");
                        File.Delete(path + ".1"); File.Move(path, path + ".1");
                    }
                    File.AppendAllText(path, DateTime.UtcNow.ToString("o") + " " + text + Environment.NewLine);
                } catch { /* Logging must never change a print result. */ }
            }
        }

        private void StopBridge() {
            stopping = true;
            if (child != null) {
                try {
                    if (!child.HasExited) {
                        child.StandardInput.WriteLine("shutdown"); child.StandardInput.Flush();
                        child.WaitForExit(42000);
                    }
                } catch { }
            }
            if (job != IntPtr.Zero) { CloseHandle(job); job = IntPtr.Zero; }
            if (child != null) { child.Dispose(); child = null; }
            releaseMutex.Set();
            if (mutexThread != null) { mutexThread.Join(); mutexThread = null; }
            ownsMutex = false;
            if (singleton != null) { singleton.Dispose(); singleton = null; }
        }

        protected override void Dispose(bool disposing) { if (disposing) StopBridge(); base.Dispose(disposing); }

        [StructLayout(LayoutKind.Sequential)] private struct BasicLimits {
            internal long PerProcessUserTimeLimit, PerJobUserTimeLimit;
            internal uint LimitFlags;
            internal UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
            internal uint ActiveProcessLimit;
            internal UIntPtr Affinity;
            internal uint PriorityClass, SchedulingClass;
        }
        [StructLayout(LayoutKind.Sequential)] private struct IoCounters { internal ulong ReadOperationCount, WriteOperationCount, OtherOperationCount, ReadTransferCount, WriteTransferCount, OtherTransferCount; }
        [StructLayout(LayoutKind.Sequential)] private struct ExtendedLimits {
            internal BasicLimits Basic;
            internal IoCounters Io;
            internal UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
        }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr CreateJobObject(IntPtr attributes, string name);
        [DllImport("kernel32.dll")] private static extern bool SetInformationJobObject(IntPtr job, int type, ref ExtendedLimits info, uint length);
        [DllImport("kernel32.dll")] private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
    }
}
