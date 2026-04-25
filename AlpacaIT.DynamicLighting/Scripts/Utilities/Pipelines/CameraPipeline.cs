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
            /// <summary>The replacement shader used on all objects when this camera renders.</summary>
            private Shader replacementShader;

            private static readonly System.Collections.Generic.List<UnityEngine.Rendering.ShaderTagId> m_ShaderTagIdList = new System.Collections.Generic.List<UnityEngine.Rendering.ShaderTagId>
            {
                new UnityEngine.Rendering.ShaderTagId("UniversalForward"),
                new UnityEngine.Rendering.ShaderTagId("SRPDefaultUnlit")
            };

            private const int alphaTestRenderQueue = (int)UnityEngine.Rendering.RenderQueue.AlphaTest;

            private static readonly UnityEngine.Rendering.RenderQueueRange opaqueRenderQueueRange =
                new UnityEngine.Rendering.RenderQueueRange(UnityEngine.Rendering.RenderQueueRange.minimumBound, alphaTestRenderQueue - 1);

            private static readonly UnityEngine.Rendering.RenderQueueRange alphaRenderQueueRange =
                new UnityEngine.Rendering.RenderQueueRange(alphaTestRenderQueue, UnityEngine.Rendering.RenderQueueRange.maximumBound);

            public ReplacementShaderPass(Material replacementMaterial)
            {
                this.replacementShader = replacementMaterial.shader;
                renderPassEvent = UnityEngine.Rendering.Universal.RenderPassEvent.AfterRenderingOpaques;
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

                    var sortingCriteria = cameraData.defaultOpaqueSortFlags;
                    passData.opaqueRendererListHandle = CreateRendererList(renderGraph, renderingData, cameraData, lightData, sortingCriteria, opaqueRenderQueueRange, 0);
                    passData.alphaRendererListHandle = CreateRendererList(renderGraph, renderingData, cameraData, lightData, sortingCriteria, alphaRenderQueueRange, 1);

                    // Declare usage and attachments (draw to active camera buffers).
                    builder.UseRendererList(passData.opaqueRendererListHandle);
                    builder.UseRendererList(passData.alphaRendererListHandle);
                    builder.SetRenderAttachment(resourceData.activeColorTexture, 0);
                    builder.SetRenderAttachmentDepth(resourceData.activeDepthTexture, UnityEngine.Rendering.RenderGraphModule.AccessFlags.Write);

                    // Define the execute function (static to avoid allocations).
                    builder.SetRenderFunc(static (PassData data, UnityEngine.Rendering.RenderGraphModule.RasterGraphContext rgContext) =>
                    {
                        rgContext.cmd.DrawRendererList(data.opaqueRendererListHandle);
                        rgContext.cmd.DrawRendererList(data.alphaRendererListHandle);
                    });
                }
            }

            private UnityEngine.Rendering.RenderGraphModule.RendererListHandle CreateRendererList(
                UnityEngine.Rendering.RenderGraphModule.RenderGraph renderGraph,
                UnityEngine.Rendering.Universal.UniversalRenderingData renderingData,
                UnityEngine.Rendering.Universal.UniversalCameraData cameraData,
                UnityEngine.Rendering.Universal.UniversalLightData lightData,
                UnityEngine.Rendering.SortingCriteria sortingCriteria,
                UnityEngine.Rendering.RenderQueueRange renderQueueRange,
                int replacementPassIndex)
            {
                var drawingSettings = UnityEngine.Rendering.Universal.RenderingUtils.CreateDrawingSettings(m_ShaderTagIdList, renderingData, cameraData, lightData, sortingCriteria);
                drawingSettings.overrideShader = replacementShader;
                drawingSettings.overrideShaderPassIndex = replacementPassIndex;

                var filteringSettings = new UnityEngine.Rendering.FilteringSettings(renderQueueRange);
                var rendererListParams = new UnityEngine.Rendering.RendererListParams(renderingData.cullResults, drawingSettings, filteringSettings);
                return renderGraph.CreateRendererList(rendererListParams);
            }

            private class PassData
            {
                public UnityEngine.Rendering.RenderGraphModule.RendererListHandle opaqueRendererListHandle;
                public UnityEngine.Rendering.RenderGraphModule.RendererListHandle alphaRendererListHandle;
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
