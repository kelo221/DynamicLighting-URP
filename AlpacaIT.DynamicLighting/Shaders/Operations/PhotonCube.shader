Shader "Hidden/Dynamic Lighting/PhotonCube"
{
    Properties
    {
        _Color("Main Color", Color) = (1,1,1,1)
        _MainTex("Base (RGB)", 2D) = "white" {}
        _BaseColor("Base Color", Color) = (1,1,1,1)
        _BaseMap("Base Map", 2D) = "white" {}
        _Cutoff("Alpha Cutoff", Range(0,1)) = 0.5
    }

    SubShader
    {
        Tags { "RenderType" = "Opaque" "RenderPipeline" = "UniversalPipeline" }
        LOD 100

        Pass
        {
            Name "PhotonCube"
            Tags { "LightMode" = "UniversalForward" }

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/de.alpacait.dynamiclighting/AlpacaIT.DynamicLighting/Shaders/Internal/Common.hlsl"

            struct appdata
            {
                float4 vertex : POSITION;
                float3 normal : NORMAL;
            };

            struct v2f
            {
                float4 vertex : SV_POSITION;
                float3 world : TEXCOORD0;
                float3 normal : TEXCOORD1;
            };

            v2f vert (appdata v)
            {
                v2f o;
                VertexPositionInputs vertexInput = GetVertexPositionInputs(v.vertex.xyz);
                VertexNormalInputs normalInput = GetVertexNormalInputs(v.normal);

                o.vertex = vertexInput.positionCS;
                o.world = vertexInput.positionWS;
                o.normal = normalInput.normalWS;
                return o;
            }

            float2 frag (v2f i) : SV_Target
            {
                float2 result;

                // calculate the unnormalized direction between the light source and the fragment.
                float3 light_direction = _WorldSpaceCameraPos - i.world;

                // properly normalize the direction between the light source and the fragment.
                light_direction = normalize(light_direction);

                // as the distance from the light increases, so does the chance that the world positions
                // are behind the geometry when sampled from the cubemap due to the low resolution.
                // we try to wiggle them back out by moving them closer towards the light source as well
                // as offsetting them by the geometry normal.
                float light_distance = distance(_WorldSpaceCameraPos, i.world);
                float bias = max(light_distance * 0.001, 0.001);
                light_distance = distance(_WorldSpaceCameraPos, i.world + light_direction * bias + i.normal * bias);

                // store the distance in the red channel and a small normal offset for raycasting on the cpu.
                result.r = light_distance;
                // store the compressed normal in the green channel (8 bits unused).
                result.g = asfloat(minivector3(i.normal));

                return result;
            }

            ENDHLSL
        }

        Pass
        {
            Name "PhotonCubeAlpha"
            Tags { "LightMode" = "UniversalForward" }

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/de.alpacait.dynamiclighting/AlpacaIT.DynamicLighting/Shaders/Internal/Common.hlsl"

            struct appdata
            {
                float4 vertex : POSITION;
                float3 normal : NORMAL;
                float2 uv0 : TEXCOORD0;
            };

            struct v2f
            {
                float4 vertex : SV_POSITION;
                float3 world : TEXCOORD0;
                float3 normal : TEXCOORD1;
                float2 uv0 : TEXCOORD2;
                float2 uvBase : TEXCOORD3;
            };

            sampler2D _MainTex;
            float4 _MainTex_ST;
            float4 _MainTex_TexelSize;
            sampler2D _BaseMap;
            float4 _BaseMap_ST;
            float4 _BaseMap_TexelSize;
            float4 _Color;
            float4 _BaseColor;
            float _Cutoff;

            v2f vert (appdata v)
            {
                v2f o;
                VertexPositionInputs vertexInput = GetVertexPositionInputs(v.vertex.xyz);
                VertexNormalInputs normalInput = GetVertexNormalInputs(v.normal);

                o.vertex = vertexInput.positionCS;
                o.world = vertexInput.positionWS;
                o.normal = normalInput.normalWS;
                o.uv0 = TRANSFORM_TEX(v.uv0, _MainTex);
                o.uvBase = TRANSFORM_TEX(v.uv0, _BaseMap);
                return o;
            }

            float2 frag (v2f i) : SV_Target
            {
                float2 result;

                float3 light_direction = _WorldSpaceCameraPos - i.world;
                light_direction = normalize(light_direction);

                float light_distance = distance(_WorldSpaceCameraPos, i.world);
                float bias = max(light_distance * 0.001, 0.001);
                light_distance = distance(_WorldSpaceCameraPos, i.world + light_direction * bias + i.normal * bias);

                result.r = light_distance;
                result.g = asfloat(minivector3(i.normal));

                float mainAlpha = texture_alpha_sample_gaussian5(_MainTex, _MainTex_TexelSize, i.uv0) * _Color.a;
                float baseAlpha = texture_alpha_sample_gaussian5(_BaseMap, _BaseMap_TexelSize, i.uvBase) * _BaseColor.a;
                clip(min(mainAlpha, baseAlpha) - _Cutoff);

                return result;
            }

            ENDHLSL
        }
    }

    SubShader
    {
        Tags { "Queue"="Transparent" "IgnoreProjector"="True" "RenderType" = "Transparent" "RenderPipeline" = "UniversalPipeline" }
        LOD 100

        Pass
        {
            Name "PhotonCubeTransparent"
            Tags { "LightMode" = "UniversalForward" }

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/de.alpacait.dynamiclighting/AlpacaIT.DynamicLighting/Shaders/Internal/Common.hlsl"

            struct appdata
            {
                float4 vertex : POSITION;
                float3 normal : NORMAL;
                float2 uv0 : TEXCOORD0;
            };

            struct v2f
            {
                float4 vertex : SV_POSITION;
                float3 world : TEXCOORD0;
                float3 normal : TEXCOORD1;
                float2 uv0 : TEXCOORD2;
                float2 uvBase : TEXCOORD3;
            };

            sampler2D _MainTex;
            float4 _MainTex_ST;
            float4 _MainTex_TexelSize;
            sampler2D _BaseMap;
            float4 _BaseMap_ST;
            float4 _BaseMap_TexelSize;
            float4 _Color;
            float4 _BaseColor;
            float _Cutoff;

            v2f vert (appdata v)
            {
                v2f o;
                VertexPositionInputs vertexInput = GetVertexPositionInputs(v.vertex.xyz);
                VertexNormalInputs normalInput = GetVertexNormalInputs(v.normal);

                o.vertex = vertexInput.positionCS;
                o.world = vertexInput.positionWS;
                o.normal = normalInput.normalWS;
                o.uv0 = TRANSFORM_TEX(v.uv0, _MainTex);
                o.uvBase = TRANSFORM_TEX(v.uv0, _BaseMap);
                return o;
            }

            float2 frag (v2f i) : SV_Target
            {
                float2 result;
                
                // calculate the unnormalized direction between the light source and the fragment.
                float3 light_direction = _WorldSpaceCameraPos - i.world;

                // properly normalize the direction between the light source and the fragment.
                light_direction = normalize(light_direction);

                // as the distance from the light increases, so does the chance that the world positions
                // are behind the geometry when sampled from the cubemap due to the low resolution.
                // we try to wiggle them back out by moving them closer towards the light source as well
                // as offsetting them by the geometry normal.
                float light_distance = distance(_WorldSpaceCameraPos, i.world);
                float bias = max(light_distance * 0.001, 0.001);
                light_distance = distance(_WorldSpaceCameraPos, i.world + light_direction * bias + i.normal * bias);

                // store the distance in the red channel and a small normal offset for raycasting on the cpu.
                result.r = light_distance;
                // store the compressed normal in the green channel (8 bits unused).
                result.g = asfloat(minivector3(i.normal));

                // discard fragments for transparent textures so that light can shine through it.
                float mainAlpha = texture_alpha_sample_gaussian5(_MainTex, _MainTex_TexelSize, i.uv0) * _Color.a;
                float baseAlpha = texture_alpha_sample_gaussian5(_BaseMap, _BaseMap_TexelSize, i.uvBase) * _BaseColor.a;
                float textureAlpha = min(mainAlpha, baseAlpha);
                if (textureAlpha > _Cutoff)
                {
                    return result;
                }
                else
                {
                    result.r = 0.0;
                    discard;
                }

                return result;
            }

            ENDHLSL
        }
    }

    SubShader
    {
        Tags { "Queue"="Transparent" "IgnoreProjector"="True" "RenderType" = "TransparentCutout" "RenderPipeline" = "UniversalPipeline" }
        LOD 100

        Pass
        {
            Name "PhotonCubeCutout"
            Tags { "LightMode" = "UniversalForward" }

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/de.alpacait.dynamiclighting/AlpacaIT.DynamicLighting/Shaders/Internal/Common.hlsl"

            struct appdata
            {
                float4 vertex : POSITION;
                float3 normal : NORMAL;
                float2 uv0 : TEXCOORD0;
            };

            struct v2f
            {
                float4 vertex : SV_POSITION;
                float3 world : TEXCOORD0;
                float3 normal : TEXCOORD1;
                float2 uv0 : TEXCOORD2;
                float2 uvBase : TEXCOORD3;
            };

            sampler2D _MainTex;
            float4 _MainTex_ST;
            float4 _MainTex_TexelSize;
            sampler2D _BaseMap;
            float4 _BaseMap_ST;
            float4 _BaseMap_TexelSize;
            float4 _Color;
            float4 _BaseColor;
            float _Cutoff;

            v2f vert (appdata v)
            {
                v2f o;
                VertexPositionInputs vertexInput = GetVertexPositionInputs(v.vertex.xyz);
                VertexNormalInputs normalInput = GetVertexNormalInputs(v.normal);

                o.vertex = vertexInput.positionCS;
                o.world = vertexInput.positionWS;
                o.normal = normalInput.normalWS;
                o.uv0 = TRANSFORM_TEX(v.uv0, _MainTex);
                o.uvBase = TRANSFORM_TEX(v.uv0, _BaseMap);
                return o;
            }

            float2 frag (v2f i) : SV_Target
            {
                float2 result;

                // calculate the unnormalized direction between the light source and the fragment.
                float3 light_direction = _WorldSpaceCameraPos - i.world;

                // properly normalize the direction between the light source and the fragment.
                light_direction = normalize(light_direction);

                // as the distance from the light increases, so does the chance that the world positions
                // are behind the geometry when sampled from the cubemap due to the low resolution.
                // we try to wiggle them back out by moving them closer towards the light source as well
                // as offsetting them by the geometry normal.
                float light_distance = distance(_WorldSpaceCameraPos, i.world);
                float bias = max(light_distance * 0.001, 0.001);
                light_distance = distance(_WorldSpaceCameraPos, i.world + light_direction * bias + i.normal * bias);

                // store the distance in the red channel and a small normal offset for raycasting on the cpu.
                result.r = light_distance;
                // store the compressed normal in the green channel (8 bits unused).
                result.g = asfloat(minivector3(i.normal));

                // discard fragments for transparent textures so that light can shine through it.
                float mainAlpha = texture_alpha_sample_gaussian5(_MainTex, _MainTex_TexelSize, i.uv0) * _Color.a;
                float baseAlpha = texture_alpha_sample_gaussian5(_BaseMap, _BaseMap_TexelSize, i.uvBase) * _BaseColor.a;
                float textureAlpha = min(mainAlpha, baseAlpha);
                if (textureAlpha > _Cutoff)
                {
                    return result;
                }
                else
                {
                    result.r = 0.0;
                    discard;
                }

                return result;
            }

            ENDHLSL
        }
    }
    Fallback "Diffuse"
}
