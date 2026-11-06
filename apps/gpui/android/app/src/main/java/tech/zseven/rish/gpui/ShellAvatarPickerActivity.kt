package tech.zseven.rish.gpui

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.provider.MediaStore

/** Isolates system Activity results from GPUI's NativeActivity surface lifecycle. */
class ShellAvatarPickerActivity : Activity() {
    private var token: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        token = intent.getStringExtra(ShellAvatarPicker.TOKEN)
        val request = token
        if (request == null || !ShellAvatarPicker.attach(request, this)) { finish(); return }
        if (savedInstanceState == null) {
            try {
                val picker = if (Build.VERSION.SDK_INT >= 33) Intent(MediaStore.ACTION_PICK_IMAGES) else documentIntent()
                picker.type = "image/*"
                picker.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                try { startActivityForResult(picker, REQUEST) }
                catch (_: ActivityNotFoundException) { startActivityForResult(documentIntent(), REQUEST) }
            } catch (_: RuntimeException) { ShellAvatarPicker.fail(request) }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST) return
        val request = token ?: return
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) ShellAvatarPicker.cancel(request)
        else ShellAvatarPicker.selected(request, applicationContext, uri)
    }

    override fun onDestroy() {
        if (!isChangingConfigurations) token?.let(ShellAvatarPicker::cancel)
        super.onDestroy()
    }

    private fun documentIntent() = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
        type = "image/*"
        addCategory(Intent.CATEGORY_OPENABLE)
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }
    companion object { private const val REQUEST = 9132 }
}
