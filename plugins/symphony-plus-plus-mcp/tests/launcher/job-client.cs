using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading.Tasks;

public sealed class JobHandle : IDisposable
{
    const int ExtendedLimitInformation = 9, BasicProcessIdList = 3;
    const uint KillOnClose = 0x2000, BreakawayOk = 0x800, SilentBreakawayOk = 0x1000;
    IntPtr handle;
    [StructLayout(LayoutKind.Sequential)] struct IoCounters { public ulong ReadOps, WriteOps, OtherOps, ReadBytes, WriteBytes, OtherBytes; }
    [StructLayout(LayoutKind.Sequential)] struct BasicLimits
    {
        public long PerProcessTime, PerJobTime;
        public uint Flags;
        public UIntPtr MinimumWorkingSet, MaximumWorkingSet;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass, SchedulingClass;
    }
    [StructLayout(LayoutKind.Sequential)] struct ExtendedLimits { public BasicLimits Basic; public IoCounters Io; public UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory; }
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetInformationJobObject(IntPtr job, int type, IntPtr value, uint length);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool QueryInformationJobObject(IntPtr job, int type, IntPtr value, uint length, out uint returned);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    static void Require(bool value, string action) { if (!value) throw new Win32Exception(Marshal.GetLastWin32Error(), action); }

    public JobHandle()
    {
        handle = CreateJobObject(IntPtr.Zero, null); Require(handle != IntPtr.Zero, "CreateJobObject");
        var limits = new ExtendedLimits { Basic = new BasicLimits { Flags = KillOnClose } };
        var buffer = Marshal.AllocHGlobal(Marshal.SizeOf<ExtendedLimits>());
        try
        {
            Marshal.StructureToPtr(limits, buffer, false);
            Require(SetInformationJobObject(handle, ExtendedLimitInformation, buffer, (uint)Marshal.SizeOf<ExtendedLimits>()), "SetInformationJobObject");
            uint returned;
            Require(QueryInformationJobObject(handle, ExtendedLimitInformation, buffer, (uint)Marshal.SizeOf<ExtendedLimits>(), out returned), "QueryInformationJobObject");
            var flags = Marshal.PtrToStructure<ExtendedLimits>(buffer).Basic.Flags;
            if ((flags & KillOnClose) == 0 || (flags & (BreakawayOk | SilentBreakawayOk)) != 0) throw new InvalidOperationException("Job limits are not non-breakaway kill-on-close.");
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }
    public void Assign(Process process) { Require(AssignProcessToJobObject(handle, process.Handle), "AssignProcessToJobObject"); }
    public int[] Pids()
    {
        var buffer = Marshal.AllocHGlobal(4096);
        try
        {
            uint returned;
            Require(QueryInformationJobObject(handle, BasicProcessIdList, buffer, 4096, out returned), "QueryInformationJobObject");
            var result = new int[Marshal.ReadInt32(buffer, 4)];
            for (var i = 0; i < result.Length; i++) result[i] = (int)Marshal.ReadIntPtr(buffer, 8 + i * IntPtr.Size);
            return result;
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }
    public static async Task ProxyInput(Stream input, Stream output) { await input.CopyToAsync(output); output.Close(); }
    public void Dispose() { if (handle != IntPtr.Zero) { CloseHandle(handle); handle = IntPtr.Zero; } }
}
