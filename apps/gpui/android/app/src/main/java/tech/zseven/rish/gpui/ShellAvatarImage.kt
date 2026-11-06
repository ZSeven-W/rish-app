package tech.zseven.rish.gpui

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Rect
import android.media.ExifInterface
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream

internal data class EncodedAvatar(val bytes: ByteArray, val width: Int, val height: Int)

/** Decode a bounded selection, apply EXIF orientation, then export fresh pixels. */
internal object ShellAvatarImage {
    fun encode(source: ByteArray): EncodedAvatar {
        if (source.isEmpty() || source.size > ShellAvatarContract.MAX_SOURCE_BYTES) throw BridgeFailure("E_ASSISTANT_AVATAR_IMAGE")
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(source, 0, source.size, bounds)
        val sample = ShellAvatarContract.sampleSize(bounds.outWidth, bounds.outHeight)
        val options = BitmapFactory.Options().apply {
            inSampleSize = sample
            inPreferredConfig = Bitmap.Config.ARGB_8888
            inScaled = false
        }
        val decoded = BitmapFactory.decodeByteArray(source, 0, source.size, options)
            ?: throw BridgeFailure("E_ASSISTANT_AVATAR_IMAGE")
        var oriented: Bitmap? = null
        var output: Bitmap? = null
        try {
            val orientation = try {
                ExifInterface(ByteArrayInputStream(source)).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
            } catch (_: java.io.IOException) { ExifInterface.ORIENTATION_NORMAL }
            val matrix = Matrix().apply {
                when (orientation) {
                    ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> setScale(-1f, 1f)
                    ExifInterface.ORIENTATION_ROTATE_180 -> setRotate(180f)
                    ExifInterface.ORIENTATION_FLIP_VERTICAL -> setScale(1f, -1f)
                    ExifInterface.ORIENTATION_TRANSPOSE -> { setRotate(90f); postScale(-1f, 1f) }
                    ExifInterface.ORIENTATION_ROTATE_90 -> setRotate(90f)
                    ExifInterface.ORIENTATION_TRANSVERSE -> { setRotate(-90f); postScale(-1f, 1f) }
                    ExifInterface.ORIENTATION_ROTATE_270 -> setRotate(-90f)
                }
            }
            oriented = Bitmap.createBitmap(decoded, 0, 0, decoded.width, decoded.height, matrix, true)
            val (width, height) = ShellAvatarContract.targetSize(oriented.width, oriented.height)
            // A fresh ARGB bitmap carries no original EXIF/GPS or ICC metadata.
            output = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            output.density = Bitmap.DENSITY_NONE
            Canvas(output).drawBitmap(oriented, null, Rect(0, 0, width, height), Paint(Paint.FILTER_BITMAP_FLAG))
            val encoded = ByteArrayOutputStream()
            if (!output.compress(Bitmap.CompressFormat.PNG, 100, encoded)) throw BridgeFailure("E_ASSISTANT_AVATAR_IMAGE")
            val bytes = encoded.toByteArray()
            if (bytes.isEmpty() || bytes.size > ShellAvatarContract.MAX_PNG_BYTES) throw BridgeFailure("E_ASSISTANT_AVATAR_IMAGE")
            return EncodedAvatar(bytes, width, height)
        } finally {
            output?.recycle()
            if (oriented !== decoded) oriented?.recycle()
            decoded.recycle()
        }
    }
}
