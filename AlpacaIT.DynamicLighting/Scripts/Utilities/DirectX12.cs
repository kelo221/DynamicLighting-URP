using UnityEngine;

namespace AlpacaIT.DynamicLighting
{
    /// <summary>
    /// Fixes issues with graphics APIs that require all declared shader buffers to be assigned.
    /// </summary>
    internal static class DirectX12
    {
        /// <summary>The global fallback shader buffer for strict graphics APIs.</summary>
        private static ComputeBuffer dynamicTrianglesGlobalBuffer;

        private static bool RequiresFallbackBuffers()
        {
            var graphicsDeviceType = SystemInfo.graphicsDeviceType;
            return graphicsDeviceType == UnityEngine.Rendering.GraphicsDeviceType.Direct3D12 ||
                   graphicsDeviceType == UnityEngine.Rendering.GraphicsDeviceType.Vulkan;
        }

        /// <summary>Creates the global fallback buffers so strict graphics APIs are satisfied.</summary>
        private static void CreateFallbackBuffers()
        {
            if (dynamicTrianglesGlobalBuffer != null && dynamicTrianglesGlobalBuffer.IsValid()) return;

            dynamicTrianglesGlobalBuffer = new ComputeBuffer(1, 4, ComputeBufferType.Default);
            Shader.SetGlobalBuffer("dynamic_triangles", dynamicTrianglesGlobalBuffer);
        }

        /// <summary>Releases the global fallback buffers (created by <see cref="CreateFallbackBuffers"/>).</summary>
        private static void ReleaseFallbackBuffers()
        {
            if (dynamicTrianglesGlobalBuffer != null && dynamicTrianglesGlobalBuffer.IsValid())
            {
                dynamicTrianglesGlobalBuffer.Release();
                dynamicTrianglesGlobalBuffer = null;
            }
        }

#if UNITY_EDITOR

        [UnityEditor.InitializeOnLoadMethod]
        private static void Initialize()
        {
            if (!RequiresFallbackBuffers()) return;

            // immediately create the fallback buffers.
            CreateFallbackBuffers();

            // before assemblies reload (could cause memory leak) release the fallback buffers.
            UnityEditor.AssemblyReloadEvents.beforeAssemblyReload += ReleaseFallbackBuffers;
        }

#else

        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.SubsystemRegistration)]
        private static void Initialize()
        {
            if (!RequiresFallbackBuffers()) return;

            // immediately create the fallback buffers.
            CreateFallbackBuffers();

            // on application quit in builds release the fallback buffers.
            Application.quitting += ReleaseFallbackBuffers;
        }

#endif
    }
}
