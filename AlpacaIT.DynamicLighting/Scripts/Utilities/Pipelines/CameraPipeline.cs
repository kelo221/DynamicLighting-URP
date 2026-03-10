using System.Runtime.CompilerServices;
using UnityEngine;

namespace AlpacaIT.DynamicLighting
{
#if UNITY_PIPELINE_URP

    /// <summary>
    /// Compatibility layer for the Unified Render Pipeline (URP) that does not support <see cref="Camera.SetReplacementShader"/>.
    /// </summary>
    internal class CameraPipeline
    {
        /// <summary>The <see cref="Camera"/> used for capturing replacement shader frames in the scene.</summary>
        private Camera camera;

        /// <summary>The replacement material used on all objects when this camera renders.</summary>
        private Material replacementMaterial;

        /// <summary>Requests rendering a single camera on the render pipeline.</summary>
        private UnityEngine.Rendering.Universal.UniversalRenderPipeline.SingleCameraRequest singleCameraRequest = new UnityEngine.Rendering.Universal.UniversalRenderPipeline.SingleCameraRequest();

        /// <summary>Handles the replacement shader pass in the Unified Render Pipeline.</summary>
        private ReplacementShaderPass replacementShaderPass;

        /// <summary>The universal additional camera data component on the camera.</summary>
        private UnityEngine.Rendering.Universal.UniversalAdditionalCameraData cameraUniversalAdditionalCameraData;

        /// <summary>
        /// Creates a new <see cref="CameraPipeline"/> used in the Unified Render Pipeline (URP).
        /// </summary>
        /// <param name="camera">
        /// The <see cref="Camera"/> used for capturing replacement shader frames in the scene.
        /// </param>
        /// <param name="replacementMaterial">
        /// The replacement material used on all objects when this camera renders.
        /// </param>
        public CameraPipeline(Camera camera, Material replacementMaterial)
        {
            this.camera = camera;
            this.replacementMaterial = replacementMaterial;
            replacementShaderPass = new ReplacementShaderPass(replacementMaterial);
            cameraUniversalAdditionalCameraData = UnityEngine.Rendering.Universal.CameraExtensions.GetUniversalAdditionalCameraData(camera);
        }

        /// <summary>Initialization of the <see cref="CameraPipeline"/> class.</summary>
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public void Initialize()
        {
            UnityEngine.Rendering.RenderPipelineManager.beginCameraRendering += OnBeginCameraRendering;
        }

        /// <summary>Cleanup of the <see cref="CameraPipeline"/> class.</summary>
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public void Cleanup()
        {
            UnityEngine.Rendering.RenderPipelineManager.beginCameraRendering -= OnBeginCameraRendering;
        }

        /// <summary>Called by the unified render pipeline when a camera begins rendering.</summary>
        /// <param name="context">
        /// Defines state and drawing commands that custom render pipelines use.
        /// </param>
        /// <param name="camera">The camera that begins rendering.</param>
        private void OnBeginCameraRendering(UnityEngine.Rendering.ScriptableRenderContext context, Camera camera)
        {
            if (camera != this.camera) return;

            cameraUniversalAdditionalCameraData.scriptableRenderer.EnqueuePass(replacementShaderPass);
        }

        /// <summary>Renders the camera with the replacement material.</summary>
        public void Render()
        {
            camera.SubmitRenderRequest(singleCameraRequest);
        }

        /// <summary>Sets the target render texture to render the camera output to.</summary>
        public RenderTexture targetTexture
        {
            set => singleCameraRequest.destination = value;
        }

        public class ReplacementShaderPass : UnityEngine.Rendering.Universal.ScriptableRenderPass
        {
            /// <summary>The replacement material used on all objects when this camera renders.</summary>
            private Material replacementMaterial;

            private static readonly System.Collections.Generic.List<UnityEngine.Rendering.ShaderTagId> m_ShaderTagIdList = new System.Collections.Generic.List<UnityEngine.Rendering.ShaderTagId>
            {
                new UnityEngine.Rendering.ShaderTagId("UniversalForward"),
                new UnityEngine.Rendering.ShaderTagId("UniversalForwardOnly"),
                new UnityEngine.Rendering.ShaderTagId("UniversalGBuffer"),
                new UnityEngine.Rendering.ShaderTagId("LightweightForward"),
                new UnityEngine.Rendering.ShaderTagId("SRPDefaultUnlit")
            };

            public ReplacementShaderPass(Material replacementMaterial)
            {
                this.replacementMaterial = replacementMaterial;
                renderPassEvent = UnityEngine.Rendering.Universal.RenderPassEvent.AfterRenderingTransparents;
            }

            public override void RecordRenderGraph(UnityEngine.Rendering.RenderGraphModule.RenderGraph renderGraph, UnityEngine.Rendering.ContextContainer frameContext)
            {
                using (var builder = renderGraph.AddRasterRenderPass<PassData>("Dynamic Lighting Replacement Shader Pass", out var passData))
                {
                    // access URP frame data.
                    var renderingData = frameContext.Get<UnityEngine.Rendering.Universal.UniversalRenderingData>();
                    var cameraData = frameContext.Get<UnityEngine.Rendering.Universal.UniversalCameraData>();
                    var lightData = frameContext.Get<UnityEngine.Rendering.Universal.UniversalLightData>();
                    var resourceData = frameContext.Get<UnityEngine.Rendering.Universal.UniversalResourceData>();

                    // Draw opaque, alpha-test, and transparent queues separately so cutout casters
                    // can use the alpha-aware replacement pass without affecting fully opaque objects.
                    var opaqueDrawingSettings = UnityEngine.Rendering.Universal.RenderingUtils.CreateDrawingSettings(
                        m_ShaderTagIdList,
                        renderingData,
                        cameraData,
                        lightData,
                        cameraData.defaultOpaqueSortFlags);
                    opaqueDrawingSettings.overrideMaterial = replacementMaterial;
                    opaqueDrawingSettings.overrideMaterialPassIndex = 0;

                    var opaqueFilteringSettings = new UnityEngine.Rendering.FilteringSettings(new UnityEngine.Rendering.RenderQueueRange
                    {
                        lowerBound = 0,
                        upperBound = 2449
                    });
                    var opaqueRendererListParams = new UnityEngine.Rendering.RendererListParams(
                        renderingData.cullResults,
                        opaqueDrawingSettings,
                        opaqueFilteringSettings);
                    passData.opaqueRendererListHandle = renderGraph.CreateRendererList(opaqueRendererListParams);

                    var alphaTestDrawingSettings = UnityEngine.Rendering.Universal.RenderingUtils.CreateDrawingSettings(
                        m_ShaderTagIdList,
                        renderingData,
                        cameraData,
                        lightData,
                        cameraData.defaultOpaqueSortFlags);
                    alphaTestDrawingSettings.overrideMaterial = replacementMaterial;
                    alphaTestDrawingSettings.overrideMaterialPassIndex = 1;

                    var alphaTestFilteringSettings = new UnityEngine.Rendering.FilteringSettings(new UnityEngine.Rendering.RenderQueueRange
                    {
                        lowerBound = 2450,
                        upperBound = 2500
                    });
                    var alphaTestRendererListParams = new UnityEngine.Rendering.RendererListParams(
                        renderingData.cullResults,
                        alphaTestDrawingSettings,
                        alphaTestFilteringSettings);
                    passData.alphaTestRendererListHandle = renderGraph.CreateRendererList(alphaTestRendererListParams);

                    var transparentDrawingSettings = UnityEngine.Rendering.Universal.RenderingUtils.CreateDrawingSettings(
                        m_ShaderTagIdList,
                        renderingData,
                        cameraData,
                        lightData,
                        UnityEngine.Rendering.SortingCriteria.CommonTransparent);
                    transparentDrawingSettings.overrideMaterial = replacementMaterial;
                    transparentDrawingSettings.overrideMaterialPassIndex = 1;

                    var transparentFilteringSettings = new UnityEngine.Rendering.FilteringSettings(new UnityEngine.Rendering.RenderQueueRange
                    {
                        lowerBound = 2501,
                        upperBound = 5000
                    });
                    var transparentRendererListParams = new UnityEngine.Rendering.RendererListParams(
                        renderingData.cullResults,
                        transparentDrawingSettings,
                        transparentFilteringSettings);
                    passData.transparentRendererListHandle = renderGraph.CreateRendererList(transparentRendererListParams);

                    // Declare usage and attachments (draw to active camera buffers).
                    builder.UseRendererList(passData.opaqueRendererListHandle);
                    builder.UseRendererList(passData.alphaTestRendererListHandle);
                    builder.UseRendererList(passData.transparentRendererListHandle);
                    builder.SetRenderAttachment(resourceData.activeColorTexture, 0);
                    builder.SetRenderAttachmentDepth(resourceData.activeDepthTexture, UnityEngine.Rendering.RenderGraphModule.AccessFlags.Write);

                    // Define the execute function (static to avoid allocations).
                    builder.SetRenderFunc(static (PassData data, UnityEngine.Rendering.RenderGraphModule.RasterGraphContext rgContext) =>
                    {
                        rgContext.cmd.DrawRendererList(data.opaqueRendererListHandle);
                        rgContext.cmd.DrawRendererList(data.alphaTestRendererListHandle);
                        rgContext.cmd.DrawRendererList(data.transparentRendererListHandle);
                    });
                }
            }

            private class PassData
            {
                public UnityEngine.Rendering.RenderGraphModule.RendererListHandle opaqueRendererListHandle;
                public UnityEngine.Rendering.RenderGraphModule.RendererListHandle alphaTestRendererListHandle;
                public UnityEngine.Rendering.RenderGraphModule.RendererListHandle transparentRendererListHandle;
            }
        }
    }

#else

    /// <summary>This class just executes some default commands in the built-in render pipeline.</summary>
    internal class CameraPipeline
    {
        /// <summary>The <see cref="Camera"/> used for capturing replacement shader frames in the scene.</summary>
        private Camera camera;

        /// <summary>Creates a new <see cref="CameraPipeline"/> that does almost nothing.</summary>
        /// <param name="camera">
        /// The <see cref="Camera"/> used for capturing replacement shader frames in the scene.
        /// </param>
        /// <param name="_">Unused in the built-in render pipeline.</param>
        public CameraPipeline(Camera camera, Material _)
        {
            this.camera = camera;
        }

        /// <summary>Does nothing (empty function call).</summary>
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public void Initialize()
        { }

        /// <summary>Does nothing (empty function call).</summary>
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public void Cleanup()
        { }

        /// <summary>Simply calls <see cref="Camera.Render"/>.</summary>
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public void Render() => camera.Render();

        /// <summary>Sets <see cref="Camera.targetTexture"/> to <paramref name="targetTexture"/>.</summary>
        public RenderTexture targetTexture
        {
            [MethodImpl(MethodImplOptions.AggressiveInlining)]
            set => camera.targetTexture = value;
        }
    }

#endif
}