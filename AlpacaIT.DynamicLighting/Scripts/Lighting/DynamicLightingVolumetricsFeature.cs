#if UNITY_PIPELINE_URP
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;
using UnityEngine.Rendering.RenderGraphModule;

namespace AlpacaIT.DynamicLighting
{
    /// <summary>
    /// URP Renderer Feature for Dynamic Lighting volumetric fog post-processing.
    /// Add this to your URP Renderer Asset to enable volumetric light effects.
    /// </summary>
    public class DynamicLightingVolumetricsFeature : ScriptableRendererFeature
    {
        [System.Serializable]
        public class Settings
        {
            public RenderPassEvent renderPassEvent = RenderPassEvent.BeforeRenderingPostProcessing;
            public bool debugLogging = false;
            public int debugViewMode = 0;
        }

        public Settings settings = new Settings();
        private DynamicLightingVolumetricsPass _pass;
        private Material _material;

        public override void Create()
        {
            // Create material here so it persists
            if (_material == null)
            {
                // First try to get shader from DynamicLightingResources (build-safe, prevents shader stripping)
                var resources = DynamicLightingResources.Instance;
                Shader shader = resources?.volumetricFogUrpShader;
                
                // Fallback to Shader.Find for editor-only usage (may fail in builds if shader is stripped)
                if (shader == null)
                {
                    shader = Shader.Find("Hidden/DynamicLightingPostProcessing.URP");
                }
                
                if (shader != null)
                {
                    _material = CoreUtils.CreateEngineMaterial(shader);
                }
                else
                {
                    Debug.LogError("DynamicLighting: Could not find shader 'Hidden/DynamicLightingPostProcessing.URP'. " +
                        "Make sure the shader is assigned to DynamicLightingResources.volumetricFogUrpShader in the Resources folder.");
                }
            }
            
            _pass = new DynamicLightingVolumetricsPass(_material)
            {
                renderPassEvent = settings.renderPassEvent,
                debugLogging = settings.debugLogging,
                debugViewMode = settings.debugViewMode
            };
        }

        public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
        {
            // Skip if not a game or scene view camera
            if (renderingData.cameraData.cameraType != CameraType.Game && 
                renderingData.cameraData.cameraType != CameraType.SceneView)
                return;

            // Skip if DynamicLightManager doesn't exist
            if (!DynamicLightManager.hasInstance)
                return;

            if (_material == null)
                return;

            var camera = renderingData.cameraData.camera;
            if (camera != null)
            {
                camera.depthTextureMode |= DepthTextureMode.Depth;
            }

            // Note: We don't check postProcessingVolumetricLightsCount here because it may not
            // be populated yet (timing depends on Update vs render order). The check is done
            // in RecordRenderGraph instead.
            _pass.ConfigureInput(ScriptableRenderPassInput.Color | ScriptableRenderPassInput.Depth);
            renderer.EnqueuePass(_pass);
            
            // One-time debug log
            if (!_loggedOnce)
            {
                Debug.Log("DynamicLighting Volumetrics: Pass enqueued for rendering");
                _loggedOnce = true;
            }
        }
        
        private bool _loggedOnce = false;

        protected override void Dispose(bool disposing)
        {
            _pass?.Dispose();
            if (_material != null)
            {
                CoreUtils.Destroy(_material);
                _material = null;
            }
        }
    }

    /// <summary>
    /// The render pass that executes the volumetric fog effect.
    /// </summary>
    public class DynamicLightingVolumetricsPass : ScriptableRenderPass
    {
        private readonly Material _material;
        private RTHandle _tempRT;
        private static readonly int ClipToWorldId = Shader.PropertyToID("clipToWorld");
        private static readonly int CameraPosId = Shader.PropertyToID("_DL_WorldSpaceCameraPos");
        private static readonly int DebugViewModeId = Shader.PropertyToID("_DL_DebugViewMode");
        private ProfilingSampler _profilingSampler;
        private int _debugFrameCounter;
        public bool debugLogging { get; set; }
        public int debugViewMode { get; set; }

        public DynamicLightingVolumetricsPass(Material material)
        {
            _material = material;
            _profilingSampler = new ProfilingSampler("DynamicLighting Volumetrics");
            requiresIntermediateTexture = true;
        }

        // Unity 2023.2+ / URP 16+ uses the Render Graph API
        private class PassData
        {
            public TextureHandle source;
            public TextureHandle destination;
            public TextureHandle depth;
            public Material material;
            public DynamicLightManager manager;
            public Matrix4x4 clipToWorld;
            public Vector3 cameraPosition;
            public int debugViewMode;
        }

        private static bool _loggedZeroLightsOnce = false;
        
        public override void RecordRenderGraph(RenderGraph renderGraph, ContextContainer frameData)
        {
            if (_material == null)
            {
                Debug.LogWarning("DynamicLighting Volumetrics: Material is null");
                return;
            }

            var manager = DynamicLightManager.Instance;
            if (manager == null)
            {
                Debug.LogWarning("DynamicLighting Volumetrics: DynamicLightManager is null");
                return;
            }
            
            if (manager.postProcessingVolumetricLightsCount == 0)
            {
                if (!_loggedZeroLightsOnce)
                {
                    Debug.LogWarning("DynamicLighting Volumetrics: postProcessingVolumetricLightsCount is 0. " +
                        "Make sure your DynamicLight has Volumetric Type set to something other than None, " +
                        "and that Volumetric Intensity and Radius are > 0.");
                    _loggedZeroLightsOnce = true;
                }
                return;
            }

            var resourceData = frameData.Get<UniversalResourceData>();
            var cameraData = frameData.Get<UniversalCameraData>();

            // Calculate clip-to-world matrix
            // Note: The second parameter to GL.GetGPUProjectionMatrix should be false
            // to match the original BIRP implementation's coordinate space handling
            var camera = cameraData.camera;
            var viewMatrix = camera.worldToCameraMatrix;
            var projectionMatrix = camera.projectionMatrix;
            projectionMatrix = GL.GetGPUProjectionMatrix(projectionMatrix, false);
            var clipToWorld = (projectionMatrix * viewMatrix).inverse;

            var source = resourceData.activeColorTexture;
            var depth = resourceData.activeDepthTexture;
            if (debugLogging && (++_debugFrameCounter % 120) == 0)
            {
                Debug.Log(
                    $"DynamicLighting Volumetrics: lights={manager.postProcessingVolumetricLightsCount}, " +
                    $"camera='{cameraData.camera.name}', depthValid={depth.IsValid()}, " +
                    $"sourceValid={source.IsValid()}, debugViewMode={debugViewMode}");
            }
            var destinationDesc = renderGraph.GetTextureDesc(source);
            destinationDesc.name = "_DynamicLightingVolumetricsTemp";
            destinationDesc.clearBuffer = false;

            var destination = renderGraph.CreateTexture(destinationDesc);

            // First pass: apply volumetrics effect
            using (var builder = renderGraph.AddUnsafePass<PassData>("DynamicLighting Volumetrics", out var passData))
            {
                passData.source = source;
                passData.destination = destination;
                passData.depth = depth;
                passData.material = _material;
                passData.manager = manager;
                passData.clipToWorld = clipToWorld;
                passData.cameraPosition = camera.transform.position;
                passData.debugViewMode = debugViewMode;

                builder.UseTexture(source, AccessFlags.Read);
                builder.UseTexture(depth, AccessFlags.Read);
                builder.UseTexture(destination, AccessFlags.Write);

                builder.SetRenderFunc((PassData data, UnsafeGraphContext context) =>
                {
                    var cmd = CommandBufferHelpers.GetNativeCommandBuffer(context.cmd);
                    data.material.SetMatrix(ClipToWorldId, data.clipToWorld);
                    data.material.SetVector(CameraPosId, data.cameraPosition);
                    data.material.SetFloat(DebugViewModeId, data.debugViewMode);
                    data.manager.PostProcessingOnPreRenderCallback();
                    Blitter.BlitCameraTexture(cmd, data.source, data.destination, data.material, 0);
                });
            }

            // Second pass: copy back to source
            using (var builder = renderGraph.AddUnsafePass<PassData>("DynamicLighting Volumetrics Copy Back", out var passData))
            {
                passData.source = destination;
                passData.destination = source;
                passData.depth = depth;
                passData.manager = manager;

                builder.UseTexture(destination, AccessFlags.Read);
                builder.UseTexture(depth, AccessFlags.Read);
                builder.UseTexture(source, AccessFlags.Write);

                builder.SetRenderFunc((PassData data, UnsafeGraphContext context) =>
                {
                    var cmd = CommandBufferHelpers.GetNativeCommandBuffer(context.cmd);
                    Blitter.BlitCameraTexture(cmd, data.source, data.destination);
                    data.manager.PostProcessingOnPostRenderCallback();
                });
            }
        }

        [System.Obsolete]
        public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData renderingData)
        {
            var descriptor = renderingData.cameraData.cameraTargetDescriptor;
            descriptor.depthBufferBits = 0;
            
            if (_tempRT == null || _tempRT.rt == null || 
                _tempRT.rt.width != descriptor.width || 
                _tempRT.rt.height != descriptor.height)
            {
                _tempRT?.Release();
                _tempRT = RTHandles.Alloc(descriptor, name: "_DynamicLightingVolumetricsTemp");
            }
        }

        [System.Obsolete]
        public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
        {
            if (_material == null)
                return;

            var manager = DynamicLightManager.Instance;
            if (manager == null || manager.postProcessingVolumetricLightsCount == 0)
            {
                if (debugLogging && (++_debugFrameCounter % 120) == 0)
                {
                    Debug.Log(
                        $"DynamicLighting Volumetrics Execute: manager={(manager != null)}, " +
                        $"lights={(manager != null ? manager.postProcessingVolumetricLightsCount : 0)}, " +
                        $"debugViewMode={debugViewMode}");
                }
                return;
            }

            CommandBuffer cmd = CommandBufferPool.Get();
            using (new ProfilingScope(cmd, _profilingSampler))
            {
                var camera = renderingData.cameraData.camera;
                
                // Calculate clip-to-world matrix
                var viewMatrix = camera.worldToCameraMatrix;
                var projectionMatrix = camera.projectionMatrix;
                projectionMatrix = GL.GetGPUProjectionMatrix(projectionMatrix, false);
                var clipToWorld = (projectionMatrix * viewMatrix).inverse;
                _material.SetMatrix(ClipToWorldId, clipToWorld);
                _material.SetVector(CameraPosId, camera.transform.position);
                _material.SetFloat(DebugViewModeId, debugViewMode);

                if (debugLogging && (++_debugFrameCounter % 120) == 0)
                {
                    var firstLightPos = manager.postProcessingVolumetricLightsCount > 0 ? manager.transform.position : Vector3.zero;
                    Debug.Log(
                        $"DynamicLighting Volumetrics Execute: lights={manager.postProcessingVolumetricLightsCount}, " +
                        $"camera='{camera.name}', target={renderingData.cameraData.cameraTargetDescriptor.width}x{renderingData.cameraData.cameraTargetDescriptor.height}, " +
                        $"debugViewMode={debugViewMode}, cameraPos={camera.transform.position}");
                }

                // Setup volumetric lights buffer
                manager.PostProcessingOnPreRenderCallback();

                // Use the camera color texture directly
                var source = renderingData.cameraData.renderer.cameraColorTargetHandle;

                // Blit with volumetrics material
                Blitter.BlitCameraTexture(cmd, source, _tempRT, _material, 0);
                Blitter.BlitCameraTexture(cmd, _tempRT, source);

                // Cleanup volumetric lights buffer
                manager.PostProcessingOnPostRenderCallback();
            }

            context.ExecuteCommandBuffer(cmd);
            CommandBufferPool.Release(cmd);
        }

        public void Dispose()
        {
            _tempRT?.Release();
            _tempRT = null;
        }
    }
}
#endif

