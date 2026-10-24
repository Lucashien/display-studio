using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace MonitorInputPrototype {
    public sealed class MonitorRecord {
        public string Id, Name, GdiName, Capabilities;
        public int Current = -1, ReadError;
        public bool IsPhilips;
        public MonitorLevels Levels;
        public override string ToString() { return Name + "  /  " + GdiName; }
    }
    public sealed class OperationResult {
        public string State, Message;
        public int Requested = -1, Current = -1, Error;
        public bool Sent;
        public MonitorRecord[] Monitors = new MonitorRecord[0];
        public ConnectionRecord[] Connections = new ConnectionRecord[0];
        public bool ConnectionScanSucceeded;
        public string ConnectionError;
        public MonitorLevels Levels;
        public string LevelControl;
        public int LevelRequested = -1;
    }
    public sealed class MonitorLevel {
        public bool Available;
        public uint Current, Maximum;
        public int Percent = -1, Error;
    }
    public sealed class MonitorLevels {
        public MonitorLevel Brightness, Volume;
        public MonitorPreset SmartImage;
    }
    public sealed class MonitorPreset {
        public bool Available;
        public int Code = -1, Error;
    }
    public sealed class ConnectionRecord {
        public string MonitorPath, Name, Technology;
        public bool Active, Available;
    }
    public sealed class HotkeySpec {
        public uint Modifiers, Key;
        public string Text;
    }
    public static class Native {
        [StructLayout(LayoutKind.Sequential)] struct Luid { public uint Low; public int High; }
        [StructLayout(LayoutKind.Sequential)] struct Rational { public uint N, D; }
        [StructLayout(LayoutKind.Sequential)] struct Source { public Luid Adapter; public uint Id, Mode, Flags; }
        [StructLayout(LayoutKind.Sequential)] struct Target {
            public Luid Adapter; public uint Id, Mode, Technology, Rotation, Scaling;
            public Rational Refresh; public uint Scanline;
            [MarshalAs(UnmanagedType.Bool)] public bool Available;
            public uint Flags;
        }
        [StructLayout(LayoutKind.Sequential)] struct DisplayPath { public Source Source; public Target Target; public uint Flags; }
        [StructLayout(LayoutKind.Sequential)] struct Header { public uint Type, Size; public Luid Adapter; public uint Id; }
        [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct SourceName {
            public Header Header;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string Name;
        }
        [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct TargetName {
            public Header Header; public uint Flags, Technology; public ushort Manufacturer, Product; public uint Connector;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst=64)] public string Name;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string DevicePath;
        }
        [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct MonitorInfo {
            public uint Size; public int Left, Top, Right, Bottom, WorkLeft, WorkTop, WorkRight, WorkBottom; public uint Flags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string Device;
        }
        [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct Physical {
            public IntPtr Handle;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string Description;
        }
        delegate bool EnumProc(IntPtr monitor, IntPtr hdc, IntPtr rect, IntPtr data);
        [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr rect, EnumProc callback, IntPtr data);
        [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);
        [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint flags, out uint paths, out uint modes);
        [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint flags, ref uint paths, [Out] DisplayPath[] pathArray, ref uint modes, IntPtr modeArray, IntPtr topology);
        [DllImport("user32.dll", EntryPoint="DisplayConfigGetDeviceInfo")] static extern int GetSourceName(ref SourceName name);
        [DllImport("user32.dll", EntryPoint="DisplayConfigGetDeviceInfo")] static extern int GetTargetName(ref TargetName name);
        [DllImport("dxva2.dll", SetLastError=true)] static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr monitor, out uint count);
        [DllImport("dxva2.dll", SetLastError=true)] static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr monitor, uint count, [Out] Physical[] monitors);
        [DllImport("dxva2.dll", SetLastError=true)] static extern bool DestroyPhysicalMonitors(uint count, Physical[] monitors);
        [DllImport("dxva2.dll", SetLastError=true)] static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr monitor, byte code, out uint type, out uint current, out uint maximum);
        // Writes are restricted to input 0x60, brightness 0x10, monitor volume 0x62, and SmartImage 0xDC.
        [DllImport("dxva2.dll", SetLastError=true)] static extern bool SetVCPFeature(IntPtr monitor, byte code, uint value);
        [DllImport("dxva2.dll", SetLastError=true)] static extern bool GetCapabilitiesStringLength(IntPtr monitor, out uint length);
        [DllImport("dxva2.dll", CharSet=CharSet.Ansi, SetLastError=true)] static extern bool CapabilitiesRequestAndCapabilitiesReply(IntPtr monitor, StringBuilder text, uint length);
        [DllImport("user32.dll", SetLastError=true)] static extern bool RegisterHotKey(IntPtr window, int id, uint modifiers, uint key);
        [DllImport("user32.dll", SetLastError=true)] static extern bool UnregisterHotKey(IntPtr window, int id);
        [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int size);
        static readonly SemaphoreSlim Gate = new SemaphoreSlim(1, 1);

        public static void StyleWindow(IntPtr window) {
            if (window == IntPtr.Zero) return;
            try {
                int dark=1, corners=2, caption=0x00211511, text=0x00FCF2EF;
                DwmSetWindowAttribute(window,20,ref dark,4);
                DwmSetWindowAttribute(window,33,ref corners,4);
                DwmSetWindowAttribute(window,35,ref caption,4);
                DwmSetWindowAttribute(window,36,ref text,4);
            } catch (DllNotFoundException) { }
              catch (EntryPointNotFoundException) { }
            // Older Windows versions may reject these optional appearance attributes.
        }

        static DisplayPath[] GetPaths(uint flags) {
            for (int attempt=0; attempt<3; attempt++) {
                uint paths, modes;
                int error=GetDisplayConfigBufferSizes(flags, out paths, out modes);
                if (error!=0) throw new Win32Exception(error, "QueryDisplayConfig buffer");
                var pathArray=new DisplayPath[paths];
                IntPtr modeArray=Marshal.AllocHGlobal(Math.Max(64, checked((int)modes*64)));
                try {
                    error=QueryDisplayConfig(flags, ref paths, pathArray, ref modes, modeArray, IntPtr.Zero);
                    if (error==122) continue;
                    if (error!=0) throw new Win32Exception(error, "QueryDisplayConfig");
                    Array.Resize(ref pathArray, (int)paths);
                    return pathArray;
                } finally { Marshal.FreeHGlobal(modeArray); }
            }
            throw new InvalidOperationException("Display topology changed during discovery; retry.");
        }
        static Dictionary<string, TargetName> DisplayNames() {
            var paths=GetPaths(2);
            var names=new Dictionary<string, TargetName>(StringComparer.OrdinalIgnoreCase);
            foreach(var path in paths) {
                        var source=new SourceName();
                        source.Header.Type=1; source.Header.Size=(uint)Marshal.SizeOf(typeof(SourceName));
                        source.Header.Adapter=path.Source.Adapter; source.Header.Id=path.Source.Id;
                        var target=new TargetName();
                        target.Header.Type=2; target.Header.Size=(uint)Marshal.SizeOf(typeof(TargetName));
                        target.Header.Adapter=path.Target.Adapter; target.Header.Id=path.Target.Id;
                        if (GetSourceName(ref source)==0 && GetTargetName(ref target)==0 && !String.IsNullOrEmpty(source.Name)) names[source.Name]=target;
            }
            return names;
        }
        static ConnectionRecord[] ReadConnections() {
            var connections=new Dictionary<string,ConnectionRecord>(StringComparer.OrdinalIgnoreCase);
            // Include available inactive targets; absence never means an input socket is empty.
            foreach(var path in GetPaths(1)) {
                if(!path.Target.Available)continue;
                var target=new TargetName();
                target.Header.Type=2; target.Header.Size=(uint)Marshal.SizeOf(typeof(TargetName));
                target.Header.Adapter=path.Target.Adapter; target.Header.Id=path.Target.Id;
                if(GetTargetName(ref target)!=0 || String.IsNullOrEmpty(target.DevicePath))continue;
                if((target.Name??"").IndexOf("498P9Z",StringComparison.OrdinalIgnoreCase)<0 && target.DevicePath.IndexOf("PHL0978",StringComparison.OrdinalIgnoreCase)<0)continue;
                string technology=path.Target.Technology==5?"HDMI":path.Target.Technology==10?"DisplayPort":"Other";
                ConnectionRecord connection;
                if(!connections.TryGetValue(target.DevicePath,out connection)) {
                    connection=new ConnectionRecord { MonitorPath=target.DevicePath, Name=target.Name, Technology=technology, Available=true };
                    connections[target.DevicePath]=connection;
                }
                connection.Active|=(path.Flags&1)!=0;
            }
            var result=new ConnectionRecord[connections.Count]; connections.Values.CopyTo(result,0); return result;
        }
        static bool ReadInput(IntPtr handle, out uint value, out int error) {
            uint type, maximum;
            bool ok=GetVCPFeatureAndVCPFeatureReply(handle, 0x60, out type, out value, out maximum);
            error=ok ? 0 : Marshal.GetLastWin32Error();
            return ok;
        }
        static MonitorLevel ReadLevel(IntPtr handle, byte code) {
            uint type, current, maximum;
            if(!GetVCPFeatureAndVCPFeatureReply(handle,code,out type,out current,out maximum))
                return new MonitorLevel { Error=Marshal.GetLastWin32Error() };
            if(maximum==0 || maximum>65535 || current>maximum)
                return new MonitorLevel { Current=current, Maximum=maximum, Error=13 };
            return new MonitorLevel { Available=true, Current=current, Maximum=maximum, Percent=(int)Math.Round(current*100.0/maximum,MidpointRounding.AwayFromZero) };
        }
        static MonitorLevels ReadLevels(IntPtr handle) {
            uint type, current, maximum;
            var preset=new MonitorPreset();
            if(GetVCPFeatureAndVCPFeatureReply(handle,0xDC,out type,out current,out maximum)) { preset.Available=true; preset.Code=(int)(current&0xFF); }
            else preset.Error=Marshal.GetLastWin32Error();
            return new MonitorLevels { Brightness=ReadLevel(handle,0x10), Volume=ReadLevel(handle,0x62), SmartImage=preset };
        }
        public static uint LevelValue(int percent,uint maximum) {
            if(percent<0 || percent>100 || maximum==0 || maximum>65535)throw new ArgumentOutOfRangeException("percent");
            return (uint)Math.Round(maximum*percent/100.0,MidpointRounding.AwayFromZero);
        }
        static OperationResult Visit(string selectedId, string operation, int requested) {
            if (operation=="switch" && (requested<1 || requested>255)) throw new ArgumentOutOfRangeException("requested");
            bool levelWrite=operation=="brightness" || operation=="volume";
            if(levelWrite && (requested<0 || requested>100))throw new ArgumentOutOfRangeException("requested");
            if(operation=="smartimage" && requested!=0 && requested!=11)throw new ArgumentOutOfRangeException("requested");
            var names=DisplayNames();
            var records=new List<MonitorRecord>();
            var result=new OperationResult { State="notfound", Requested=requested, Message="Selected physical monitor is unavailable." };
            if(operation=="discover") {
                try { result.Connections=ReadConnections(); result.ConnectionScanSucceeded=true; }
                catch(Exception e) { result.ConnectionError=e.Message; }
            }
            bool found=false;
            EnumProc callback=delegate(IntPtr monitor, IntPtr hdc, IntPtr rect, IntPtr data) {
                var info=new MonitorInfo(); info.Size=(uint)Marshal.SizeOf(typeof(MonitorInfo));
                if (!GetMonitorInfo(monitor, ref info)) return true;
                TargetName target;
                if (!names.TryGetValue(info.Device, out target) || String.IsNullOrEmpty(target.DevicePath)) return true;
                uint count;
                if (!GetNumberOfPhysicalMonitorsFromHMONITOR(monitor, out count) || count==0) return true;
                var physical=new Physical[count];
                if (!GetPhysicalMonitorsFromHMONITOR(monitor, count, physical)) return true;
                try {
                    for (int i=0;i<count;i++) {
                        string id=target.DevicePath+"|"+i;
                        if (operation!="discover" && !String.Equals(id, selectedId, StringComparison.OrdinalIgnoreCase)) continue;
                        bool philips=(target.Name??"").IndexOf("498P9Z",StringComparison.OrdinalIgnoreCase)>=0 || target.DevicePath.IndexOf("PHL0978",StringComparison.OrdinalIgnoreCase)>=0;
                        var record=new MonitorRecord { Id=id, Name=String.IsNullOrWhiteSpace(target.Name)?physical[i].Description:target.Name, GdiName=info.Device, IsPhilips=philips };
                        // Never send vendor input mappings to an unrelated or virtual monitor.
                        if (!philips) { if(operation=="discover") records.Add(record); continue; }
                        found=true;
                        uint current; int readError;
                        if(operation=="smartimage") {
                            result.LevelControl=operation; result.LevelRequested=requested;
                            result.Levels=ReadLevels(physical[i].Handle);
                            if(!result.Levels.SmartImage.Available) {
                                result.State="unavailable"; result.Error=result.Levels.SmartImage.Error; result.Message="SmartImage cannot currently be read; retry detection.";
                                break;
                            }
                            if(!SetVCPFeature(physical[i].Handle,0xDC,(uint)requested)) {
                                result.State="failed"; result.Error=Marshal.GetLastWin32Error(); result.Message="SmartImage write failed.";
                                break;
                            }
                            result.Sent=true; result.State="unverified"; result.Message="SmartImage command sent; mode is not confirmed.";
                            for(int retry=0;retry<3;retry++) {
                                Thread.Sleep(350);
                                result.Levels=ReadLevels(physical[i].Handle);
                                if(result.Levels.SmartImage.Available && result.Levels.SmartImage.Code==requested) { result.State="confirmed"; result.Message="Monitor reported the requested SmartImage mode."; break; }
                                result.Error=result.Levels.SmartImage.Error;
                            }
                        } else if(levelWrite) {
                            result.LevelControl=operation; result.LevelRequested=requested;
                            var before=ReadLevels(physical[i].Handle);
                            var level=operation=="brightness"?before.Brightness:before.Volume;
                            result.Levels=before;
                            // This 498P9Z has been observed to acknowledge brightness writes
                            // without a backlight change in LowBlue. Do not report false success.
                            if(operation=="brightness" && before.SmartImage.Available && before.SmartImage.Code==11) {
                                result.State="modeblocked"; result.Message="LowBlue may override backlight control; select SmartImage Off before adjusting brightness.";
                                break;
                            }
                            if(!level.Available) {
                                result.State="unavailable"; result.Error=level.Error; result.Message="Monitor control is unsupported, locked, or unavailable.";
                                break;
                            }
                            uint raw=LevelValue(requested,level.Maximum);
                            byte code=operation=="brightness"?(byte)0x10:(byte)0x62;
                            if(!SetVCPFeature(physical[i].Handle,code,raw)) {
                                result.State="failed"; result.Error=Marshal.GetLastWin32Error(); result.Message="Monitor level write failed.";
                                break;
                            }
                            result.Sent=true; result.State="unverified"; result.Message="Level command sent; readback is not confirmed.";
                            for(int retry=0;retry<3;retry++) {
                                Thread.Sleep(250);
                                result.Levels=ReadLevels(physical[i].Handle);
                                var observed=operation=="brightness"?result.Levels.Brightness:result.Levels.Volume;
                                if(observed.Available && observed.Current==raw) { result.State="confirmed"; result.Message="Monitor reported the requested level."; break; }
                                result.Error=observed.Error;
                            }
                        } else if (operation=="switch") {
                            uint value=(uint)requested;
                            // Preserve the secondary source byte, if the monitor reports one.
                            if (ReadInput(physical[i].Handle,out current,out readError)) value=(current&0xFF00)|(uint)requested;
                            if (!SetVCPFeature(physical[i].Handle,0x60,value)) {
                                result.State="failed"; result.Error=Marshal.GetLastWin32Error(); result.Message="SetVCPFeature failed.";
                                break;
                            }
                            result.Sent=true; result.State="unverified"; result.Message="Command sent; display has not confirmed the requested source.";
                            Thread.Sleep(1800);
                            for(int retry=0;retry<3;retry++) {
                                if (ReadInput(physical[i].Handle,out current,out readError)) {
                                    result.Current=(int)(current&0xFF);
                                    if(result.Current==requested) { result.State="confirmed"; result.Message="Monitor reported the requested input value."; break; }
                                } else result.Error=readError;
                                if(retry<2)Thread.Sleep(600);
                            }
                            result.Levels=ReadLevels(physical[i].Handle);
                        } else {
                            if(ReadInput(physical[i].Handle,out current,out readError)) record.Current=(int)(current&0xFF);
                            else record.ReadError=readError;
                            if(operation=="discover") {
                                uint length;
                                if(GetCapabilitiesStringLength(physical[i].Handle,out length) && length>0 && length<16384) {
                                    var caps=new StringBuilder((int)length);
                                    if(CapabilitiesRequestAndCapabilitiesReply(physical[i].Handle,caps,length)) record.Capabilities=caps.ToString();
                                }
                            }
                            records.Add(record);
                            record.Levels=ReadLevels(physical[i].Handle);
                            result.Levels=record.Levels;
                            result.Current=record.Current; result.Error=record.ReadError;
                            result.State=record.Current>=0?"read":"unavailable";
                            result.Message=record.Current>=0?"Input read successfully.":"DDC/CI input read failed.";
                        }
                    }
                } finally { DestroyPhysicalMonitors(count, physical); }
                return !found || operation=="discover";
            };
            if(!EnumDisplayMonitors(IntPtr.Zero,IntPtr.Zero,callback,IntPtr.Zero)) {
                // Callback may stop enumeration intentionally after the selected monitor.
                if(!found) result.Message="Physical monitor enumeration failed.";
            }
            result.Monitors=records.ToArray();
            if(operation=="discover") { result.State="discovered"; result.Message=records.Count+" physical monitor(s)."; }
            return result;
        }
        public static Task<OperationResult> Begin(string operation,string id,int requested) {
            if(operation!="discover" && operation!="read" && operation!="switch" && operation!="brightness" && operation!="volume" && operation!="smartimage")throw new ArgumentException("Unknown operation.");
            return Task.Run<OperationResult>(delegate {
                if(!Gate.Wait(0))return new OperationResult { State="busy", Message="Another monitor operation is running." };
                try { return Visit(id,operation,requested); }
                catch(Exception e) { return new OperationResult { State="error", Message=e.Message, Error=Marshal.GetLastWin32Error() }; }
                finally { Gate.Release(); }
            });
        }
        public static HotkeySpec ParseHotkey(string text) {
            if(String.IsNullOrWhiteSpace(text))return new HotkeySpec { Text="", Modifiers=0, Key=0 };
            uint modifiers=0, key=0;
            foreach(string raw in text.Split('+')) {
                string token=raw.Trim().ToUpperInvariant(); uint mod=0;
                if(token=="CTRL" || token=="CONTROL")mod=2;
                else if(token=="ALT")mod=1;
                else if(token=="SHIFT")mod=4;
                if(mod!=0) { if((modifiers&mod)!=0)throw new ArgumentException("Duplicate modifier."); modifiers|=mod; continue; }
                uint next=0; int function;
                if(token.Length==1 && ((token[0]>='A'&&token[0]<='Z')||(token[0]>='0'&&token[0]<='9')))next=token[0];
                else if(token.StartsWith("F") && Int32.TryParse(token.Substring(1),out function) && function>=1 && function<=24)next=(uint)(111+function);
                else throw new ArgumentException("Use Ctrl / Alt / Shift with A-Z, 0-9, or F1-F24.");
                if(key!=0)throw new ArgumentException("Use exactly one letter, number, or function key."); key=next;
            }
            if((modifiers&3)==0 || key==0)throw new ArgumentException("A shortcut must include Ctrl or Alt and one key.");
            var parts=new List<string>();
            if((modifiers&2)!=0)parts.Add("Ctrl"); if((modifiers&1)!=0)parts.Add("Alt"); if((modifiers&4)!=0)parts.Add("Shift");
            parts.Add(key>=112 && key<=135?"F"+(key-111):((char)key).ToString());
            return new HotkeySpec { Text=String.Join("+",parts.ToArray()), Modifiers=modifiers, Key=key };
        }
        public static int Bind(IntPtr window,int id,string text) {
            var spec=ParseHotkey(text); if(spec.Key==0)return 0;
            return RegisterHotKey(window,id,spec.Modifiers|0x4000,spec.Key)?0:Marshal.GetLastWin32Error();
        }
        public static void Unbind(IntPtr window,int id) { UnregisterHotKey(window,id); }
    }
}
