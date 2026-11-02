using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Security.AccessControl;
using System.Security.Principal;
using System.ServiceProcess;

namespace LPG.PrintBridge {
    internal static class Common {
        internal const string ServiceName = "LPGPrintBridge";
        internal static readonly string InstallDirectory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "LPG Print Bridge");
        internal static readonly string DataDirectory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "LPGManager", "PrintBridge");
        internal static readonly string LegacyDirectory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LPGManager", "PrintBridge");

        internal static void NoLinks(string path) {
            for (string part = Path.GetFullPath(path); !String.IsNullOrEmpty(part); part = Path.GetDirectoryName(part)) {
                if ((Directory.Exists(part) || File.Exists(part)) && (File.GetAttributes(part) & FileAttributes.ReparsePoint) != 0)
                    throw new IOException("Reparse points are not allowed in bridge installation or data paths.");
            }
        }

        internal static void SecureDirectory(string path, bool readable) {
            NoLinks(path);
            Directory.CreateDirectory(path);
            var acl = new DirectorySecurity();
            acl.SetOwner(new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null));
            acl.SetAccessRuleProtection(true, false);
            foreach (var sid in new[] { WellKnownSidType.LocalSystemSid, WellKnownSidType.BuiltinAdministratorsSid })
                acl.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(sid, null), FileSystemRights.FullControl,
                    InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
            if (readable) acl.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.BuiltinUsersSid, null),
                FileSystemRights.ReadAndExecute, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
            Directory.SetAccessControl(path, acl);
        }

        internal static void ResourceToFile(string resource, string path) {
            NoLinks(path);
            using (var source = Assembly.GetExecutingAssembly().GetManifestResourceStream(resource)) {
                if (source == null) throw new IOException("Missing embedded bridge resource.");
                File.Delete(path);
                using (var target = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None)) source.CopyTo(target);
            }
        }

        internal static void SecureDataTree(string path) {
            SecureDirectory(path, false);
            foreach (string directory in Directory.GetDirectories(path)) SecureDataTree(directory);
            foreach (string file in Directory.GetFiles(path)) {
                NoLinks(file);
                var acl = new FileSecurity();
                acl.SetOwner(new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null));
                acl.SetAccessRuleProtection(true, false);
                foreach (var sid in new[] { WellKnownSidType.LocalSystemSid, WellKnownSidType.BuiltinAdministratorsSid })
                    acl.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(sid, null), FileSystemRights.FullControl, AccessControlType.Allow));
                File.SetAccessControl(file, acl);
            }
        }

        internal static void Restart(bool restart) {
            using (var service = new ServiceController(ServiceName)) {
                if (restart && service.Status != ServiceControllerStatus.Stopped) {
                    if (service.Status != ServiceControllerStatus.StopPending) service.Stop();
                    service.WaitForStatus(ServiceControllerStatus.Stopped, TimeSpan.FromSeconds(50));
                }
                service.Refresh();
                if (service.Status == ServiceControllerStatus.Stopped) service.Start();
                service.WaitForStatus(ServiceControllerStatus.Running, TimeSpan.FromSeconds(30));
            }
        }

        internal static bool Installed() {
            foreach (var service in ServiceController.GetServices()) {
                using (service) { if (service.ServiceName == ServiceName) return true; }
            }
            return false;
        }

        internal static void Run(string file, string arguments) {
            using (var process = Process.Start(new ProcessStartInfo(file, arguments) {
                UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true
            })) {
                process.OutputDataReceived += (sender, line) => { };
                process.ErrorDataReceived += (sender, line) => { };
                process.BeginOutputReadLine(); process.BeginErrorReadLine();
                if (!process.WaitForExit(60000)) { process.Kill(); throw new IOException("Windows service command timed out."); }
                if (process.ExitCode != 0) throw new IOException("Windows service command failed (exit " + process.ExitCode + ").");
            }
        }
    }
}
