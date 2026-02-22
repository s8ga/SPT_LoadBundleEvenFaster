using BepInEx;
using BepInEx.Logging;
using BepInEx.Configuration;
using BepInEx.Bootstrap; // used to check if a soft dependency plugin is loaded
using HarmonyLib;
using System;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Threading.Tasks;
using System.Buffers;
using System.Runtime.InteropServices; // for Marshal

using SPT.Custom.Patches;
using SPT.Custom.Utils;
using SPT.Custom.Models;
using SPT.Common.Utils;

namespace SPT_LoadBundleEvenFaster.Plugin
{
    // This PLUGIN_VERSION is generated from csproj AssenblyVersion directive.
    [BepInPlugin("com.s8.sptloadbundleevenfaster", "s8_SPTLoadBundleEvenFaster", PluginInfo.PLUGIN_VERSION)]
    [BepInDependency("com.SPT.custom", "4.0.0")]
    // Soft dependency: use if present, otherwise fall back
    [BepInDependency("com.s8.sptpatchcrc32", BepInDependency.DependencyFlags.SoftDependency)]
    public class Plugin : BaseUnityPlugin
    {
        public static ManualLogSource LogSource;

        // Global flag indicating whether multithreaded validation succeeded
        public static bool ValidationSucceeded = false;

        private void Awake()
        {
            LogSource = Logger;

            // Initialize CRC acceleration module (checks dependencies via reflection)
            HelperMethods.InitCrcAccelerator();

            Harmony.CreateAndPatchAll(Assembly.GetExecutingAssembly());
            LogSource.LogInfo("SPT_LoadBundleEvenFaster plugin loaded");
        }
    }

    [HarmonyPatch(typeof(EasyAssetsPatch), "Init")]
    [HarmonyPriority(Priority.First)]
    class Patch_EasyAssetsInit
    {
        [HarmonyPrefix]
        static bool Init_Prefix()
        {
            Plugin.LogSource.LogInfo("Init_Prefix: Starting parallel bundle validation...");

            // Perform multithreaded CRC checks at full speed on a background thread pool
            bool allValid = Task.Run(() => HelperMethods.ValidateBundlesStreamingAsync()).GetAwaiter().GetResult();

            if (allValid && BundleManager.Bundles.Count > 0)
            {
                Plugin.ValidationSucceeded = true;
                Plugin.LogSource.LogInfo("Init_Prefix: Validation succeeded! Fast path enabled. Bypassing SPT serial hash checks.");
            }
            else
            {
                Plugin.ValidationSucceeded = false;
                Plugin.LogSource.LogWarning("Init_Prefix: Validation failed or no bundles. Falling back to SPT serial hash checks.");
            }

            // Always return true so the original Init can build its dependency graph
            return true;
        }
    }

    [HarmonyPatch(typeof(BundleManager), nameof(BundleManager.ShouldAcquire))]
    class Patch_BundleManager_ShouldAcquire
    {
        //cached Task<bool> to avoid creating new Task instances on every call when validation succeeded
        private static readonly Task<bool> CachedFalseTask = Task.FromResult(false);

        [HarmonyPrefix]
        static bool Prefix(ref Task<bool> __result)
        {
            if (Plugin.ValidationSucceeded)
            {
                __result = CachedFalseTask;
                return false;
            }
            return true;
        }
    }

    static class HelperMethods
    {
        // Dynamically get CPU thread count
        private static readonly int MAX_CONCURRENT_CRC = Environment.ProcessorCount >= 8 ? 8 : Environment.ProcessorCount;
        private static readonly System.Threading.SemaphoreSlim _crcSemaphore = new System.Threading.SemaphoreSlim(MAX_CONCURRENT_CRC);

        // Native delegate definition corresponding to the libcrc32_pclmulqdq.dll interface
        // uint crc32_pclmulqdq(uint crc, byte* buf, IntPtr len)
        private unsafe delegate uint NativeCrcDelegate(uint crc, byte* buf, IntPtr len);

        // Stores the reflected native method
        private static NativeCrcDelegate _nativeCrcMethod;
        private static bool _useNativeCrc = false;

        internal static void InitCrcAccelerator()
        {
            // Check if the CRC patch plugin has been loaded
            if (Chainloader.PluginInfos.TryGetValue("com.s8.sptpatchcrc32", out var pluginInfo))
            {
                try
                {
                    // Try to reflect the Patch_Crc32 class

                    var patchType = pluginInfo.Instance.GetType().Assembly.GetType("Patch_Crc32");

                    if (patchType != null)
                    {
                        // Get private static extern crc32_pclmulqdq method
                        var methodInfo = patchType.GetMethod("crc32_pclmulqdq", BindingFlags.Static | BindingFlags.NonPublic);

                        if (methodInfo != null)
                        {
                            _nativeCrcMethod = methodInfo.CreateDelegate(typeof(NativeCrcDelegate)) as NativeCrcDelegate;
                            _useNativeCrc = true;
                            Plugin.LogSource.LogInfo("[Performance] Hooked into 'com.s8.sptpatchcrc32' native accelerator successfully!");
                            return;
                        }
                    }
                    Plugin.LogSource.LogWarning("Found 'com.s8.sptpatchcrc32' but failed to reflect method. Interface might have changed.");
                }
                catch (Exception ex)
                {
                    Plugin.LogSource.LogError($"Error hooking into CRC patch: {ex.Message}");
                }
            }
            else
            {
                // Plugin not found; print recommendation
                Plugin.LogSource.LogWarning("-----------------------------------------------------------------------");
                Plugin.LogSource.LogWarning("[Performance Tip] Native CRC32 accelerator not found!");
                Plugin.LogSource.LogWarning("Install 'CRC32 Patch' to drastically reduce loading times (3x-5x faster).");
                Plugin.LogSource.LogWarning("Download: https://forge.sp-tarkov.com/mod/2563/loadbundlefaster-crc32-patch");
                Plugin.LogSource.LogWarning("Using slower default C# fallback for now.");
                Plugin.LogSource.LogWarning("-----------------------------------------------------------------------");
            }
        }

        private static async Task<uint> ComputeCrcStreamingAsync(string filepath)
        {
            const int bufferSize = 256 * 1024; // 256KB buffer

            // Use ArrayPool to minimize allocations and GC overhead during streaming
            byte[] buffer = ArrayPool<byte>.Shared.Rent(bufferSize);

            // ⚠️ Logic branch:
            // If using the Native DLL (pclmulqdq): starting value is usually 0 and result doesn't need inversion.
            // If using SPT C# (Crc32.Update): starting value is usually 0xFFFFFFFF and result must be inverted (~crc).

            uint crc = _useNativeCrc ? 0u : 0xFFFF_FFFFu;

            try
            {
                using (FileStream stream = new FileStream(
                    filepath,
                    FileMode.Open,
                    FileAccess.Read,
                    FileShare.Read,
                    bufferSize,
                    FileOptions.SequentialScan | FileOptions.Asynchronous))
                {
                    int bytesRead;
                    while ((bytesRead = await stream.ReadAsync(buffer, 0, bufferSize).ConfigureAwait(false)) > 0)
                    {
                        if (_useNativeCrc)
                        {
                            // === Fast path: call the reflected native pointer ===
                            unsafe
                            {
                                fixed (byte* p = buffer)
                                {
                                    // Directly invoke the function from the DLL, passing the previous crc
                                    crc = _nativeCrcMethod(crc, p, (IntPtr)bytesRead);
                                }
                            }
                        }
                        else
                        {
                            // === Slow path: default C# implementation ===
                            crc = Crc32.Update(crc, new ReadOnlySpan<byte>(buffer, 0, bytesRead));
                        }
                    }
                }

                // Native version usually returns the final CRC directly; C# version typically requires inversion
                return _useNativeCrc ? crc : ~crc;
            }

            catch (Exception ex)
            {
                Plugin.LogSource.LogError($"ComputeCrcStreamingAsync: Error reading file - {filepath}. Error: {ex.Message}");
                throw;
            }

            finally
            {
                ArrayPool<byte>.Shared.Return(buffer);
            }
        }

        private static async Task<bool> ValidateSingleBundleAsync(BundleItem bundle)
        {
            await _crcSemaphore.WaitAsync().ConfigureAwait(false);

            try
            {
                string filepath = BundleManager.GetBundleFilePath(bundle);

                if (!VFS.Exists(filepath))
                {
                    Plugin.LogSource.LogWarning($"ValidateSingleBundleAsync: Bundle file not found - {filepath}");
                    return false;
                }

                uint computedCrc = await ComputeCrcStreamingAsync(filepath).ConfigureAwait(false);

                if (computedCrc != bundle.Crc)
                {
                    Plugin.LogSource.LogWarning($"ValidateSingleBundleAsync: CRC mismatch for {filepath}. Expected: 0x{bundle.Crc:X8}, Computed: 0x{computedCrc:X8}");
                    return false;
                }

                return true;
            }
            catch (Exception ex)
            {
                Plugin.LogSource.LogError($"ValidateSingleBundleAsync: Error validating bundle {bundle.FileName}. Error: {ex.Message}");
                return false;
            }
            finally
            {
                _crcSemaphore.Release();
            }
        }

        internal static async Task<bool> ValidateBundlesStreamingAsync()
        {
            try
            {
                if (BundleManager.Bundles == null || BundleManager.Bundles.Count == 0)
                    return false;

                var bundles = BundleManager.Bundles.Values;
                int totalBundles = bundles.Count;

                Plugin.LogSource.LogInfo($"ValidateBundlesStreamingAsync: Starting parallel bundle validation for {totalBundles} bundles using {(_useNativeCrc ? "Native PCLMULQDQ" : "C# Fallback")}");
                Plugin.LogSource.LogInfo($"ValidateBundlesStreamingAsync: Max concurrent CRC tasks set to {MAX_CONCURRENT_CRC} based on CPU thread count.");
                var checks = bundles.Select(bundle => ValidateSingleBundleAsync(bundle));
                bool[] results = await Task.WhenAll(checks).ConfigureAwait(false);

                bool allValid = results.All(x => x);
                int validCount = results.Count(x => x);

                Plugin.LogSource.LogInfo($"ValidateBundlesStreamingAsync: Validation completed. Valid: {validCount}/{totalBundles}");

                return allValid;
            }
            catch (Exception ex)
            {
                Plugin.LogSource.LogError($"ValidateBundlesStreamingAsync: Error during bundle validation. Error: {ex.Message}");
                return false;
            }
        }
    }
}