namespace LPG.PrintBridge {
    internal static class Restart {
        private static int Main() {
            try { Common.Restart(true); return 0; }
            catch { return 1; }
        }
    }
}
