using UnityEngine;

namespace AlpacaIT.DynamicLighting
{
    /// <summary>
    /// Post-processing image effect for a <see cref="Camera"/>, rendering volumetric fog on <see
    /// cref="DynamicLight"/> sources in the scene.
    /// <para>
    /// <b>Built-in Render Pipeline:</b> Add this component to your camera.<br/>
    /// <b>URP:</b> This component does NOT work in URP. Instead, add the 
    /// <see cref="DynamicLightingVolumetricsFeature"/> to your URP Renderer Asset.
    /// </para>
    /// </summary>
    [ExecuteInEditMode]
    [ImageEffectAllowedInSceneView]
    [RequireComponent(typeof(Camera))]
    public class DynamicLightingPostProcessing : MonoBehaviour
    {
        private Material _material;
        private Camera _camera;

#if UNITY_PIPELINE_URP
        private void OnEnable()
        {
            Debug.LogWarning(
                "[Dynamic Lighting] DynamicLightingPostProcessing does not work in URP!\n" +
                "To enable volumetric fog in URP:\n" +
                "1. Select your URP Renderer Asset (e.g., UniversalRenderPipelineAsset_Renderer)\n" +
                "2. Click 'Add Renderer Feature'\n" +
                "3. Select 'Dynamic Lighting Volumetrics Feature'\n" +
                "4. Remove this DynamicLightingPostProcessing component from your camera.",
                this);
        }
#else
        private void Start()
        {
            _camera = GetComponent<Camera>();
            _camera.depthTextureMode = DepthTextureMode.Depth;

            _material = DynamicLightingResources.Instance.dynamicLightingPostProcessingMaterial;
        }

        private void OnRenderImage(RenderTexture source, RenderTexture destination)
        {
            var dynamicLightManagerInstance = DynamicLightManager.Instance;

            // when there are no active volumetric light sources we can skip work.
            if (dynamicLightManagerInstance.postProcessingVolumetricLightsCount == 0)
            {
                Graphics.Blit(source, destination);
                return;
            }

            var viewMatrix = _camera.worldToCameraMatrix;
            var projectionMatrix = _camera.projectionMatrix;
            projectionMatrix = GL.GetGPUProjectionMatrix(projectionMatrix, false);
            var clipToPos = (projectionMatrix * viewMatrix).inverse;
            _material.SetMatrix("clipToWorld", clipToPos);

            dynamicLightManagerInstance.PostProcessingOnPreRenderCallback();
            Graphics.Blit(source, destination, _material);
            dynamicLightManagerInstance.PostProcessingOnPostRenderCallback();
        }
#endif
    }
}