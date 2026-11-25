package com.mawarikhlas.hd_clean

import android.content.Context
import android.opengl.GLES20
import androidx.media3.common.VideoFrameProcessingException
import androidx.media3.common.util.GlProgram
import androidx.media3.common.util.GlUtil
import androidx.media3.common.util.Size
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.BaseGlShaderProgram
import androidx.media3.effect.GlEffect
import androidx.media3.effect.GlShaderProgram

/**
 * TikTok Survival Mode pre-conditioning, on the GPU.
 *
 * 1. Edge-preserving (bilateral) noise reduction: sensor noise is random
 *    detail that a low-bitrate encoder (TikTok's) cannot keep, so it spends
 *    its bits on it and the result breaks into blocks. Edges are kept because
 *    neighbours that differ strongly in colour get almost no weight.
 * 2. Gentle shadow lift: encoders give dark areas the fewest bits, so they
 *    block first. Only the darkest tones are raised; mid-tones and highlights
 *    are untouched. No sharpening is applied.
 */
@UnstableApi
class SurvivalEffect(private val denoise: Float, private val shadowLift: Float) : GlEffect {
    override fun toGlShaderProgram(context: Context, useHdr: Boolean): GlShaderProgram =
        SurvivalShaderProgram(denoise, shadowLift, useHdr)

    override fun isNoOp(inputWidth: Int, inputHeight: Int) = denoise <= 0f && shadowLift <= 0f
}

@UnstableApi
private class SurvivalShaderProgram(
    private val denoise: Float,
    private val shadowLift: Float,
    useHdr: Boolean,
) : BaseGlShaderProgram(useHdr, 1) {

    private val program: GlProgram = try {
        GlProgram(VERTEX, FRAGMENT).apply {
            setBufferAttribute(
                "aFramePosition",
                GlUtil.getNormalizedCoordinateBounds(),
                GlUtil.HOMOGENEOUS_COORDINATE_VECTOR_SIZE,
            )
        }
    } catch (e: GlUtil.GlException) {
        throw VideoFrameProcessingException(e)
    }
    private var width = 1
    private var height = 1

    override fun configure(inputWidth: Int, inputHeight: Int): Size {
        width = inputWidth
        height = inputHeight
        return Size(inputWidth, inputHeight)
    }

    override fun drawFrame(inputTexId: Int, presentationTimeUs: Long) {
        try {
            program.use()
            program.setSamplerTexIdUniform("uTexSampler", inputTexId, 0)
            program.setFloatsUniform("uTexel", floatArrayOf(1f / width, 1f / height))
            program.setFloatUniform("uDenoise", denoise)
            program.setFloatUniform("uLift", shadowLift)
            program.bindAttributesAndUniforms()
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
            GlUtil.checkGlError()
        } catch (e: GlUtil.GlException) {
            throw VideoFrameProcessingException(e, presentationTimeUs)
        }
    }

    override fun release() {
        super.release()
        try { program.delete() } catch (e: GlUtil.GlException) { throw VideoFrameProcessingException(e) }
    }

    companion object {
        private const val VERTEX = """
            attribute vec4 aFramePosition;
            varying vec2 vTexSamplingCoord;
            void main() {
              gl_Position = aFramePosition;
              vTexSamplingCoord = vec2(aFramePosition.x * 0.5 + 0.5, aFramePosition.y * 0.5 + 0.5);
            }
        """

        private const val FRAGMENT = """
            precision highp float;
            uniform sampler2D uTexSampler;
            uniform vec2 uTexel;
            uniform float uDenoise;
            uniform float uLift;
            varying vec2 vTexSamplingCoord;

            float luma(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }

            void main() {
              vec4 src = texture2D(uTexSampler, vTexSamplingCoord);
              vec3 c = src.rgb;
              vec3 outc = c;
              if (uDenoise > 0.0) {
                // Range sigma grows with strength: stronger = removes more noise.
                float sigma = mix(0.025, 0.085, uDenoise);
                float inv = 1.0 / (2.0 * sigma * sigma);
                vec3 sum = c;
                float wsum = 1.0;
                for (int y = -2; y <= 2; y++) {
                  for (int x = -2; x <= 2; x++) {
                    if (x == 0 && y == 0) continue;
                    vec2 o = vec2(float(x), float(y));
                    vec3 s = texture2D(uTexSampler, vTexSamplingCoord + o * uTexel).rgb;
                    vec3 d = s - c;
                    float w = exp(-dot(d, d) * inv) * exp(-dot(o, o) / 4.5);
                    sum += s * w;
                    wsum += w;
                  }
                }
                outc = mix(c, sum / wsum, clamp(0.55 + 0.45 * uDenoise, 0.0, 1.0));
              }
              if (uLift > 0.0) {
                float l = luma(outc);
                // Raise only the darkest tones; fades out completely by mid-grey.
                float gain = uLift * 0.45 * (1.0 - smoothstep(0.0, 0.42, l));
                outc = outc * (1.0 + gain) + vec3(uLift * 0.010 * (1.0 - smoothstep(0.0, 0.2, l)));
              }
              gl_FragColor = vec4(clamp(outc, 0.0, 1.0), src.a);
            }
        """
    }
}
