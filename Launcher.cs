using System;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Threading;
using System.Windows;
using System.Reflection;

[assembly: AssemblyTitle("Display Studio")]
[assembly: AssemblyDescription("Minimal monitor control panel")]
[assembly: AssemblyVersion("1.6.0.0")]

static class Launcher {
    [STAThread]
    static int Main() {
        string root=AppDomain.CurrentDomain.BaseDirectory;
        try {
            using(var runspace=RunspaceFactory.CreateRunspace()) {
                runspace.ApartmentState=ApartmentState.STA;
                runspace.ThreadOptions=PSThreadOptions.UseCurrentThread;
                runspace.Open();
                using(var shell=PowerShell.Create()) {
                    shell.Runspace=runspace;
                    // Load local source as a script block; no system execution-policy changes.
                    shell.AddScript(File.ReadAllText(Path.Combine(root,"MonitorInput.ps1"))).AddParameter("BaseDirectory",root);
                    shell.Invoke();
                    if(shell.HadErrors)throw new InvalidOperationException(shell.Streams.Error[0].ToString());
                }
            }
            return 0;
        } catch(Exception e) {
            try { File.WriteAllText(Path.Combine(root,"startup-error.txt"),e.ToString()); } catch { }
            MessageBox.Show("工具無法啟動：\n"+e.Message+"\n\n請確認整個資料夾已完整解壓縮。","螢幕輸入切換",MessageBoxButton.OK,MessageBoxImage.Error);
            return 1;
        }
    }
}
