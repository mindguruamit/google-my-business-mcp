package com.mindguru.prompter

import android.annotation.SuppressLint
import android.content.Context
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CameraMetadata
import android.media.CamcorderProfile
import android.media.MediaRecorder
import android.os.Build
import android.provider.Settings
import android.util.Size
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlin.math.min
import kotlin.math.roundToInt

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DEVICE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getDeviceInfo" -> result.success(deviceInfo())
                    "getCameraCapabilities" -> try {
                        result.success(cameraCapabilities())
                    } catch (e: Exception) {
                        result.error("CAMERA_QUERY_FAILED", e.message, null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // ---------------------------------------------------------------------
    // Device identity (used for the vivo X200 FE banner and fallbacks)

    private fun deviceInfo(): Map<String, Any?> = mapOf(
        "manufacturer" to Build.MANUFACTURER,
        "brand" to Build.BRAND,
        "model" to Build.MODEL,
        "device" to Build.DEVICE,
        "product" to Build.PRODUCT,
        "sdkInt" to Build.VERSION.SDK_INT,
        "marketName" to marketName(),
    )

    /** Retail name, e.g. "vivo X200 FE", when the OEM exposes one. */
    private fun marketName(): String {
        val keys = listOf(
            "ro.vivo.market.name",
            "ro.product.marketname",
            "ro.product.vendor.marketname",
            "ro.config.marketing_name",
        )
        for (key in keys) {
            val value = systemProperty(key)
            if (!value.isNullOrBlank()) return value
        }
        return Settings.Global.getString(contentResolver, Settings.Global.DEVICE_NAME) ?: ""
    }

    @SuppressLint("PrivateApi")
    private fun systemProperty(key: String): String? = try {
        val clazz = Class.forName("android.os.SystemProperties")
        clazz.getMethod("get", String::class.java).invoke(null, key) as? String
    } catch (_: Exception) {
        null
    }

    // ---------------------------------------------------------------------
    // Camera2 capability query (SCALER_STREAM_CONFIGURATION_MAP)

    private fun cameraCapabilities(): List<Map<String, Any?>> {
        val manager = getSystemService(Context.CAMERA_SERVICE) as CameraManager
        return manager.cameraIdList.mapNotNull { id ->
            try {
                describeCamera(id, manager.getCameraCharacteristics(id))
            } catch (_: Exception) {
                null
            }
        }
    }

    private fun describeCamera(id: String, chars: CameraCharacteristics): Map<String, Any?> {
        val facing = when (chars.get(CameraCharacteristics.LENS_FACING)) {
            CameraMetadata.LENS_FACING_FRONT -> "front"
            CameraMetadata.LENS_FACING_BACK -> "back"
            else -> "external"
        }
        val map = chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)

        // The recorder can't exceed the fastest AE target range the HAL offers
        // to third-party apps.
        val aeRanges = chars.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
        val aeMax = aeRanges?.maxOfOrNull { it.upper } ?: 30

        val videoSizes = mutableListOf<Map<String, Int>>()
        map?.getOutputSizes(MediaRecorder::class.java)?.forEach { size ->
            if (TARGET_SIZES.any { it.width == size.width && it.height == size.height }) {
                val minFrameNs = map.getOutputMinFrameDuration(MediaRecorder::class.java, size)
                val sizeMax = if (minFrameNs > 0) (1_000_000_000.0 / minFrameNs).roundToInt() else aeMax
                videoSizes.add(
                    mapOf("width" to size.width, "height" to size.height, "maxFps" to min(sizeMax, aeMax)),
                )
            }
        }

        // Constrained high-speed (e.g. 1080p120 slow-motion) sizes.
        val highSpeedSizes = mutableListOf<Map<String, Int>>()
        try {
            map?.highSpeedVideoSizes?.forEach { size ->
                val maxFps = map.getHighSpeedVideoFpsRangesFor(size).maxOfOrNull { it.upper } ?: 0
                highSpeedSizes.add(mapOf("width" to size.width, "height" to size.height, "maxFps" to maxFps))
            }
        } catch (_: Exception) {
            // Not all HALs implement high-speed queries.
        }

        val videoStabilization = chars
            .get(CameraCharacteristics.CONTROL_AVAILABLE_VIDEO_STABILIZATION_MODES)
            ?.any { it != CameraMetadata.CONTROL_VIDEO_STABILIZATION_MODE_OFF } == true
        val opticalStabilization = chars
            .get(CameraCharacteristics.LENS_INFO_AVAILABLE_OPTICAL_STABILIZATION)
            ?.any { it != CameraMetadata.LENS_OPTICAL_STABILIZATION_MODE_OFF } == true

        val capabilities = chars.get(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES) ?: IntArray(0)
        val hdr10Bit = Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            capabilities.contains(CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_DYNAMIC_RANGE_TEN_BIT)

        return mapOf(
            "id" to id,
            "facing" to facing,
            "videoSizes" to videoSizes,
            "highSpeedSizes" to highSpeedSizes,
            "profiles" to encoderProfiles(id),
            "videoStabilization" to videoStabilization,
            "opticalStabilization" to opticalStabilization,
            "hdr10Bit" to hdr10Bit,
            "focalLengths" to chars.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)?.toList(),
        )
    }

    /**
     * CameraX picks recording qualities from the encoder profiles, so these
     * decide what the Flutter camera plugin can actually record. Keys match
     * the Dart VideoResolution enum names.
     */
    @Suppress("DEPRECATION")
    private fun encoderProfiles(id: String): Map<String, Boolean> {
        val cameraId = id.toIntOrNull() ?: return emptyMap()
        fun has(quality: Int): Boolean = try {
            CamcorderProfile.hasProfile(cameraId, quality)
        } catch (_: Exception) {
            false
        }
        return mapOf(
            "hd720" to has(CamcorderProfile.QUALITY_720P),
            "fhd1080" to has(CamcorderProfile.QUALITY_1080P),
            "uhd4k" to has(CamcorderProfile.QUALITY_2160P),
            "uhd8k" to (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && has(CamcorderProfile.QUALITY_8KUHD)),
        )
    }

    companion object {
        private const val DEVICE_CHANNEL = "com.mindguru.prompter/device"

        private val TARGET_SIZES = listOf(
            Size(1280, 720),
            Size(1920, 1080),
            Size(2560, 1440),
            Size(3840, 2160),
            Size(7680, 4320),
        )
    }
}
