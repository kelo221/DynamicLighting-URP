using UnityEngine;
using UnityEngine.Rendering;
#if UNITY_PIPELINE_URP
using UnityEngine.Rendering.Universal;
#endif

namespace AlpacaIT.DynamicLighting
{
#if UNITY_PIPELINE_URP
    /// <summary>
    /// URP renderer feature that applies the Dynamic Lighting volumetric post-processing shader
    /// as a full-screen pass, replacing the legacy OnRenderImage path.
    /// </summary>
    public class DynamicLightingURPFeature : ScriptableRendererFeature
    {
        [System.Serializable]
        public class Settings
        {
            public RenderPassEvent renderPassEvent = RenderPassEvent.AfterRenderingTransparents;
            public bool enabled = true;
        }

        private class VolumetricPass : ScriptableRenderPass
        {
            private readonly string profilerTag = "DynamicLighting Volumetric";
            private readonly int temporaryColorTextureId = Shader.PropertyToID("_DynLit_TempColorTexture");

            private Material material;
            private RenderTargetIdentifier colorSource;

            public VolumetricPass(RenderPassEvent evt, Material mat)
            {
                renderPassEvent = evt;
                material = mat;
                ConfigureInput(ScriptableRenderPassInput.Depth);
            }

            public void SetSource(RenderTargetIdentifier source)
            {
                colorSource = source;
            }

            public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData renderingData)
            {
                var desc = renderingData.cameraData.cameraTargetDescriptor;
                desc.depthBufferBits = 0;
                cmd.GetTemporaryRT(temporaryColorTextureId, desc, FilterMode.Bilinear);
            }

            public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
            {
                if (material == null) return;

                var manager = DynamicLightManager.Instance;
                if (manager == null) return;

                var camera = renderingData.cameraData.camera;

                // Compute clip-to-world matrix (matches legacy OnRenderImage path)
                var viewMatrix = camera.worldToCameraMatrix;
                var projectionMatrix = camera.projectionMatrix;
                projectionMatrix = GL.GetGPUProjectionMatrix(projectionMatrix, false);
                var clipToWorld = (projectionMatrix * viewMatrix).inverse;
                material.SetMatrix("clipToWorld", clipToWorld);

                var cmd = CommandBufferPool.Get(profilerTag);
                try
                {
                    // Upload volumetric lights just-in-time for this pass.
                    manager.PostProcessingOnPreRenderCallback();

                    // Blit scene color through volumetric material
                    cmd.Blit(colorSource, temporaryColorTextureId, material);
                    cmd.Blit(temporaryColorTextureId, colorSource);

                    // Restore original buffers/state
                    manager.PostProcessingOnPostRenderCallback();

                    context.ExecuteCommandBuffer(cmd);
                }
                finally
                {
                    CommandBufferPool.Release(cmd);
                }
            }

            public override void OnCameraCleanup(CommandBuffer cmd)
            {
                cmd.ReleaseTemporaryRT(temporaryColorTextureId);
            }
        }

        public Settings settings = new Settings();
        private VolumetricPass pass;

        public override void Create()
        {
            var resources = DynamicLightingResources.Instance;
            var material = resources ? resources.dynamicLightingPostProcessingMaterial : null;
            pass = new VolumetricPass(settings.renderPassEvent, material);
        }

        public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
        {
            if (!settings.enabled) return;

            var resources = DynamicLightingResources.Instance;
            if (resources == null || resources.dynamicLightingPostProcessingMaterial == null) return;

            // Skip if no volumetric lights are present to save cost.
            var manager = DynamicLightManager.Instance;
            if (manager == null || manager.postProcessingVolumetricLightsCount == 0) return;

            pass.SetSource(renderer.cameraColorTarget);
            renderer.EnqueuePass(pass);
        }
    }
#endif
}


