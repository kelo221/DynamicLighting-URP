Shader "Hidden/DynamicLightingPostProcessing.URP"
{
    Properties
    {
        _MainTex ("Texture", 2D) = "white" {}
    }

    SubShader
    {
        Tags { "RenderType" = "Opaque" "RenderPipeline" = "UniversalPipeline" }
        Cull Off ZWrite Off ZTest Always

        Pass
        {
            Name "DynamicLightingVolumetrics"

            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment frag
            
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareDepthTexture.hlsl"
            #include "Packages/com.unity.render-pipelines.core/Runtime/Utilities/Blit.hlsl"
            #include "Packages/de.alpacait.dynamiclighting/AlpacaIT.DynamicLighting/Shaders/DynamicLighting.hlsl"

            float4x4 clipToWorld;
            float3 _DL_WorldSpaceCameraPos;

            float4 DL_ComputeClipSpacePosition(float2 positionNDC, float deviceDepth)
            {
                float4 positionCS = float4(positionNDC * 2.0 - 1.0, deviceDepth, 1.0);
                return positionCS;
            }

            float3 DL_ComputeWorldSpacePosition(float2 positionNDC, float deviceDepth, float4x4 invViewProjMatrix)
            {
                float4 positionCS = DL_ComputeClipSpacePosition(positionNDC, deviceDepth);
                float4 hpositionWS = mul(invViewProjMatrix, positionCS);
                return hpositionWS.xyz / hpositionWS.w;
            }

            // macros to name the recycled variables.
            #define light_volumetricRadius radiusSqr
            #define light_volumetricThickness gpFloat1
            #define light_volumetricScale float3(light.gpFloat2, light.gpFloat3, light.shimmerScale)
            #define light_volumetricSpotAngle light.gpFloat2
            #define volumetric_type_sphere 1
            #define volumetric_type_box 2
            #define volumetric_type_cone_y 3
            #define volumetric_type_cone_z 4

            float4 frag(Varyings input) : SV_Target
            {
                float2 uv = input.texcoord;
                
                // Sample depth - URP provides this via DeclareDepthTexture.hlsl
                float depth = SampleSceneDepth(uv);
                
                // Handle different graphics APIs (convert to linear 0-1 range for calculation)
                #if !UNITY_REVERSED_Z
                    depth = lerp(UNITY_NEAR_CLIP_VALUE, 1, depth);
                #endif
                
                // Use the same UV for world position reconstruction
                float3 worldspace = DL_ComputeWorldSpacePosition(uv, depth, clipToWorld);
                // _BlitTexture is defined by Blit.hlsl
                float4 color = SAMPLE_TEXTURE2D(_BlitTexture, sampler_LinearClamp, uv);
                
                // iterate over every volumetric light in the scene (pre-filtered on the CPU):
                float4 fog_final = float4(0.0, 0.0, 0.0, 0.0);
                float fog_final_t = 0.0;
                
                // DEBUG: Capture first light's data for debugging (outside loop)
                float3 debug_light_pos = float3(0,0,0);
                float debug_light_radius = 0;
                float debug_dist_to_light = 0;
                uint debug_volumetric_type = 0;
                float debug_raw_t = 0;
                float debug_closest_point_in_sphere = 0;
                
                for (uint k = 0; k < dynamic_lights_count; k++)
                {
                    // get the current volumetric light from memory.
                    DynamicLight light = dynamic_lights[k];
                    
                    float4 fog_color = float4(light.color, 1.0);
                    float3 fog_center = light.position;
                    float fog_radius = light.light_volumetricRadius;
                    uint volumetric_type = light.channel;
                    
                    // Capture debug values from first light
                    if (k == 0) {
                        debug_light_pos = fog_center;
                        debug_light_radius = fog_radius;
                        debug_dist_to_light = distance(worldspace, fog_center);
                        debug_volumetric_type = volumetric_type;
                    }

                    float t = 0.0;

                    if (volumetric_type == volumetric_type_sphere)
                    {
                        // closest point to the fog center on line between camera and fragment.
                        float3 fog_closest_point = nearest_point_on_finite_line(_DL_WorldSpaceCameraPos, worldspace, fog_center);
                        
                        // DEBUG: Check if closest point is in sphere
                        float dist_closest_to_center = distance(fog_closest_point, fog_center);
                        if (k == 0) {
                            debug_closest_point_in_sphere = (dist_closest_to_center < fog_radius) ? 1.0 : 0.0;
                        }
                
                        // does the camera to world line intersect the fog sphere?
                        if (point_in_sphere(fog_closest_point, fog_center, fog_radius))
                        {
                            // distance from the closest point on the camera and fragment line to the fog center.
                            float fog_closest_point_distance_to_interior_sphere = fog_radius - distance(fog_closest_point, fog_center);
    
                            // t is the volumetric non-linear color interpolant from 1.0 (center) to 0.0 (edge) of the sphere.
                            t = fog_closest_point_distance_to_interior_sphere / fog_radius;
                            
                            // DEBUG: capture raw t
                            if (k == 0) debug_raw_t = t;
                        }
                    }
                    else if (volumetric_type == volumetric_type_box)
                    {
                        // define box bounds (min and max corners).
                        float3 boxMin = light.position - light.light_volumetricRadius * light_volumetricScale;
                        float3 boxMax = light.position + light.light_volumetricRadius * light_volumetricScale;

                        // compute the ray direction (from camera to the current fragment).
                        float3 rayDir = normalize(worldspace - _DL_WorldSpaceCameraPos);

                        // get the distance to the current fragment in world space.
                        // tMax is limited by the maximum depth (geometry).
                        float tMin, tMax;
                        float maxDepth = length(worldspace - _DL_WorldSpaceCameraPos);
                        ray_box_intersection(_DL_WorldSpaceCameraPos, rayDir, boxMin, boxMax, tMin, tMax, maxDepth);

                        // compute the length of the ray segment inside the box.
                        float ray_length_in_box = tMax - tMin;
                                
                        // calculate the fog intensity based on the distance traveled inside the box.
                        t = ray_length_in_box / length(boxMax - boxMin); // normalize by box size.
                    }
                    else if (volumetric_type == volumetric_type_cone_y || volumetric_type == volumetric_type_cone_z)
                    {
                        // compute the ray direction (from camera to the current fragment).
                        float3 rayDir = normalize(worldspace - _DL_WorldSpaceCameraPos);

                        // get the distance to the current fragment in world space.
                        float tMin, tMax;
                        float maxDepth = length(worldspace - _DL_WorldSpaceCameraPos);

                        // Perform ray-cone intersection test
                        if (ray_cone_intersection(_DL_WorldSpaceCameraPos, rayDir, light.position, light.forward, light_volumetricSpotAngle, light.light_volumetricRadius, tMin, tMax, maxDepth))
                        {
                            // compute the length of the ray segment inside the cone.
                            float ray_length_in_cone = tMax - tMin;

                            // calculate the fog intensity based on the distance traveled inside the cone.
                            t = ray_length_in_cone / light.light_volumetricRadius;
                        }
                    }

                    // apply smoothstep for a gradual fog transition near the edges.
                    t = smoothstep(0.0, 1.0, t);
                                
                    // apply the thickness to the fog that appears as a solid color.
                    t = saturate(t * light.light_volumetricThickness);
                        
                    // the distance from the camera to the world is used to make nearby geometry inside the fog visible.
                    float camera_distance_from_world = distance(_DL_WorldSpaceCameraPos, worldspace) * light.volumetricVisibility;
                        
                    // we only subtract from t so that naturally fading fog takes precedence.
                    t = min(t, camera_distance_from_world);
            
                    // let the user tweak the fog intensity with a multiplier.
                    t *= light.volumetricIntensity;
            
                    // remember the most opaque fog that we have encountered.
                    fog_final_t = max(fog_final_t, t);
            
                    // blend between the current color and the fog color.
                    fog_final = color_screen(fog_final, fog_color * t);
                }
                
                // DEBUG: Uncomment ONE of these lines to diagnose the issue:
                // return float4(debug_raw_t, debug_raw_t, debug_raw_t, 1);  // Test 15: Raw t from sphere
                // return float4(debug_closest_point_in_sphere, 0, 0, 1);  // Test 16: Closest point in sphere?
                // return float4(frac(_DL_WorldSpaceCameraPos * 0.1), 1);  // Test 17: Camera position (constant color)
                // return float4(distance(_DL_WorldSpaceCameraPos, debug_light_pos) * 0.1, 0, 0, 1);  // Test 18: Camera-to-light dist
                
                // special blend that allows for fully opaque fog.
                return lerp(color_screen(fog_final, color), fog_final, saturate(fog_final_t));
            }
            ENDHLSL
        }
    }
}

