Shader "Hidden/Dynamic Lighting/GaussianBlur"
{
    // contains source code from https://github.com/daniel-ilett/smo-shaders (see Licenses/SmoShaders.txt).
    // shoutouts to Daniel Ilett!

    Properties
    {
        _MainTex ("Texture", 2D) = "white" {}
    }

    HLSLINCLUDE
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

        static const float DYNAMIC_LIGHTING_TWO_PI = 6.28319;

        TEXTURE2D(_MainTex);
        SAMPLER(sampler_MainTex);
        float4 _MainTex_ST;
        float2 _MainTex_TexelSize;
        #define _KernelSize 3
        #define _Spread 1.0
        //int	_KernelSize;
        //float _Spread;

        // gaussian function in one dimension.
	    float gaussian(int x)
	    {
		    float sigmaSqu = _Spread * _Spread;
		    return (1 / sqrt(DYNAMIC_LIGHTING_TWO_PI * sigmaSqu)) * exp(-(x * x) / (2 * sigmaSqu));
	    }

        struct Attributes
        {
            float4 vertex : POSITION;
            float2 uv : TEXCOORD0;
        };

        struct Varyings
        {
            float4 positionCS : SV_POSITION;
            float2 uv : TEXCOORD0;
        };

        Varyings vert(Attributes input)
        {
            Varyings output;
            output.positionCS = TransformObjectToHClip(input.vertex.xyz);
            output.uv = TRANSFORM_TEX(input.uv, _MainTex);
            return output;
        }
    ENDHLSL

    SubShader
    {
        Tags { "RenderType"="Opaque" }
        LOD 100

        Pass
        {
            Name "HorizontalPass"

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag

            float4 frag (Varyings i) : SV_Target
            {
				float4 col = float4(0.0, 0.0, 0.0, 0.0);
				float kernelSum = 0.0;

				int upper = ((_KernelSize - 1) / 2);
				int lower = -upper;

				for (int x = lower; x <= upper; ++x)
				{
					float gauss = gaussian(x);
					kernelSum += gauss;
					col += gauss * SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, i.uv + float2(_MainTex_TexelSize.x * x, 0.0));
				}

				col /= kernelSum;
				return col;
            }
            ENDHLSL
        }

        Pass
        {
            Name "VerticalPass"

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag

            float4 frag (Varyings i) : SV_Target
            {
				float4 col = float4(0.0, 0.0, 0.0, 0.0);
				float kernelSum = 0.0;

				int upper = ((_KernelSize - 1) / 2);
				int lower = -upper;

				for (int y = lower; y <= upper; ++y)
				{
					float gauss = gaussian(y);
					kernelSum += gauss;
					col += gauss * SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, i.uv + float2(0.0, _MainTex_TexelSize.y * y));
				}

				col /= kernelSum;
				return col;
            }
            ENDHLSL
        }
    }
}
