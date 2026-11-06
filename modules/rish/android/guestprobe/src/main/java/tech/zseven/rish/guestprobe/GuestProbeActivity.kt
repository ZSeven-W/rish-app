package tech.zseven.rish.guestprobe

import android.app.Activity
import android.app.ActivityManager
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.provider.Settings
import android.graphics.Color
import android.graphics.Typeface
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.text.method.ScrollingMovementMethod
import android.util.TypedValue
import android.view.Gravity
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import tech.zseven.rish.guest.AndroidGuestAssets
import tech.zseven.rish.guest.GuestAssets
import tech.zseven.rish.guest.GuestRuntimeState
import tech.zseven.rish.guest.GuestSessionController
import tech.zseven.rish.guest.RishGuestNative
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * On-screen equivalent of LocalGuestBootTest, check for check.
 *
 * The instrumentation test is the real proof on a machine that has adb. A
 * HarmonyOS phone running Android through 卓易通 gives the host no adb at all,
 * so that proof cannot be run where the question is open. This screen runs the
 * same sequence against the same classes and prints each result.
 *
 * Every check states what it expected and what it got. When the boot fails the
 * screen is the only evidence anyone will have, so the probe also retries with
 * less memory and dumps its own logcat: `rish_vm_boot_session` returns a null
 * pointer and carries no reason across the FFI, so the reason has to be
 * recovered from outside it.
 */
class GuestProbeActivity : Activity() {

    private companion object {
        /** The machine that served this APK. */
        const val REPORT_HOST = "192.168.11.85:8765"
    }

    private lateinit var output: TextView
    private lateinit var run: Button
    private lateinit var settings: Button
    private lateinit var copy: Button
    private lateinit var send: Button
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var running = false
    private var failures = 0
    private var checks = 0

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(24, 24, 24, 24)
            setBackgroundColor(Color.BLACK)
        }
        run = Button(this).apply {
            text = "Boot the guest"
            setOnClickListener { start() }
        }
        // 卓易通 offers no Android Settings entry, so there is no way to reach
        // developer options -- and therefore no wireless debugging and no adb
        // from a host. An intent addresses the activity directly and does not
        // need a launcher entry, so the page may still be reachable even
        // though nothing links to it. Each candidate is reported by name: a
        // probe that just said "failed" would not say which door was shut.
        settings = Button(this).apply {
            text = "Try to open developer settings"
            setOnClickListener { openSettings() }
        }
        // The report is the whole deliverable and it leaves this device by
        // hand. Photographing a scrolling log loses most of it.
        send = Button(this).apply {
            text = "Send report to the Mac"
            setOnClickListener { sendReport() }
        }
        copy = Button(this).apply {
            text = "Copy report"
            setOnClickListener {
                val text = output.text.toString()
                (getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager)
                    .setPrimaryClip(ClipData.newPlainText("rish guest probe", text))
                Toast.makeText(this@GuestProbeActivity,
                    "Copied ${text.length} characters", Toast.LENGTH_SHORT).show()
            }
        }
        output = TextView(this).apply {
            typeface = Typeface.MONOSPACE
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
            setTextColor(Color.WHITE)
            setTextIsSelectable(true)
            movementMethod = ScrollingMovementMethod()
            gravity = Gravity.TOP
        }
        root.addView(run, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        root.addView(settings, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        root.addView(copy, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        root.addView(send, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        root.addView(output, LinearLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))
        setContentView(root)
        header()
    }

    private fun header() {
        line("Rish guest probe")
        line("abi        ${android.os.Build.SUPPORTED_ABIS.joinToString(",")}")
        line("device     ${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL}")
        line("android    ${android.os.Build.VERSION.RELEASE} (sdk ${android.os.Build.VERSION.SDK_INT})")
        line("process    ${if (Process.is64Bit()) "64-bit" else "32-bit"}")
        val info = ActivityManager.MemoryInfo()
        (getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).getMemoryInfo(info)
        line("ram        ${info.availMem / 1048576} MiB free of ${info.totalMem / 1048576} MiB" +
            (if (info.lowMemory) " (low)" else ""))
        line("kernel     ${GuestAssets.KERNEL_NAME}")
        line("initramfs  ${GuestAssets.INITRAMFS_NAME}")
        line("")
        line("Tap the button. A boot is interpreted and slow; minutes are normal.")
    }

    /**
     * Tries every route to the Android settings this container might still
     * hold. Developer options is the only thing that would give a host adb,
     * and adb is the only thing that would make this phone drivable at all.
     */
    private fun openSettings() {
        val candidates = listOf(
            "developer options" to Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS,
            "about phone (tap the build number 7 times)" to Settings.ACTION_DEVICE_INFO_SETTINGS,
            "all settings" to Settings.ACTION_SETTINGS,
            "wireless / networking" to Settings.ACTION_WIRELESS_SETTINGS,
        )
        output.text = ""
        line("== reachable settings pages ==")
        var opened = false
        for ((name, action) in candidates) {
            val intent = Intent(action).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            val resolves = intent.resolveActivity(packageManager) != null
            if (!resolves) { line("  [absent]  $name"); continue }
            if (opened) { line("  [present] $name"); continue }
            try {
                startActivity(intent)
                line("  [OPENED]  $name")
                opened = true
            } catch (error: Throwable) {
                line("  [blocked] $name -- ${error.javaClass.simpleName}")
            }
        }
        if (!opened) {
            line("")
            line("No settings page opened. This container exposes no Android")
            line("settings at all, so developer options and wireless debugging")
            line("do not exist here and no host can attach over adb.")
        }
    }

    /**
     * POSTs the report to the machine that built this APK, so the findings stop
     * travelling by photograph. The address is the host this APK was served
     * from; nothing else is contacted, and the button is the only thing that
     * sends. The guest run itself needs no network and does not use one.
     */
    private fun sendReport() {
        val text = output.text.toString()
        Thread({
            val outcome = try {
                val url = URL("http://$REPORT_HOST/report")
                (url.openConnection() as HttpURLConnection).run {
                    requestMethod = "POST"
                    doOutput = true
                    connectTimeout = 8000
                    readTimeout = 8000
                    setRequestProperty("Content-Type", "text/plain; charset=utf-8")
                    outputStream.use { it.write(text.toByteArray()) }
                    "sent ${text.length} characters, HTTP $responseCode"
                }
            } catch (error: Throwable) {
                "could not send: ${error.javaClass.simpleName}: ${error.message}"
            }
            main.post { Toast.makeText(this, outcome, Toast.LENGTH_LONG).show() }
        }, "report-sender").start()
    }

    private fun start() {
        if (running) return
        running = true
        failures = 0
        checks = 0
        run.isEnabled = false
        run.text = "Running…"
        output.text = ""
        Thread({ probe() }, "guest-probe").start()
    }

    private fun line(text: String) = main.post {
        output.append(if (output.text.isEmpty()) text else "\n$text")
    }

    /** Records one expectation. [detail] is printed whether it held or not. */
    private fun check(name: String, ok: Boolean, detail: String = "") {
        checks += 1
        if (!ok) failures += 1
        line("  [${if (ok) "PASS" else "FAIL"}] $name${if (detail.isEmpty()) "" else " -- $detail"}")
    }

    private class Call {
        var receipt: Map<String, Any?>? = null
        var code: String? = null
        var message: String? = null
        val done = CountDownLatch(1)
        /** False when the call never settled, which is itself a result. */
        fun await(seconds: Long): Boolean = done.await(seconds, TimeUnit.SECONDS)
    }

    /**
     * The app's own log. Android lets a process read its own entries, and this
     * is the only place a reason for a failed boot can still be found.
     */
    private fun dumpOwnLog(lines: Int) {
        line("")
        line("== this process's log (last $lines lines) ==")
        try {
            val process = Runtime.getRuntime().exec(
                arrayOf("logcat", "-d", "-v", "time", "--pid=${Process.myPid()}"))
            val collected = ArrayDeque<String>()
            BufferedReader(InputStreamReader(process.inputStream)).use { reader ->
                while (true) {
                    val text = reader.readLine() ?: break
                    collected.addLast(text)
                    if (collected.size > lines) collected.removeFirst()
                }
            }
            if (collected.isEmpty()) line("  (empty -- this layer may not expose logcat to apps)")
            else collected.forEach { line("  $it") }
        } catch (error: Throwable) {
            line("  (unavailable: ${error.javaClass.simpleName}: ${error.message})")
        }
    }

    private fun bootAttempt(controller: GuestSessionController, mib: Int, seconds: Long): Call? {
        val call = Call()
        val started = System.currentTimeMillis()
        controller.bootGuest(
            mapOf("schema_version" to 1, "memory_mib" to mib),
            { call.receipt = it; call.done.countDown() },
            { code, message -> call.code = code; call.message = message; call.done.countDown() },
        )
        if (!call.await(seconds)) return null
        line("  boot at ${mib} MiB -- ${System.currentTimeMillis() - started}ms")
        return call
    }

    private fun exec(controller: GuestSessionController, command: List<String>, seconds: Long): Call? {
        val call = Call()
        val started = System.currentTimeMillis()
        controller.guestExec(
            mapOf("schema_version" to 1, "command" to command),
            { call.receipt = it; call.done.countDown() },
            { code, message -> call.code = code; call.message = message; call.done.countDown() },
        )
        if (!call.await(seconds)) return null
        line("  ${command.joinToString(" ")} -- ${System.currentTimeMillis() - started}ms")
        return call
    }

    /**
     * Why the boot could have failed in 30ms without reading a 12 MiB kernel.
     * The rejection code cannot say, and on the device that matters the log
     * carried nothing from the runtime, so ask the three questions directly.
     */
    private fun diagnose() {
        line("")
        line("== native diagnostics ==")
        if (!NativeProbe.available) {
            line("  libguestprobe_jni.so did not load; no native answers available")
            return
        }
        val staged = try {
            AndroidGuestAssets(this).stage()
        } catch (error: Throwable) {
            line("  staging threw ${error.javaClass.simpleName}: ${error.message}")
            null
        }
        NativeProbe.tempStatus().lines().forEach { line("  $it") }
        if (staged != null) {
            line("  kernel    ${staged.kernelPath}")
            NativeProbe.readFile(staged.kernelPath).lines().forEach { line("    $it") }
            line("  initramfs ${staged.initramfsPath}")
            NativeProbe.readFile(staged.initramfsPath).lines().forEach { line("    $it") }
        }
        line("  ${NativeProbe.mapAnonymous(768)}")
        line("  ${NativeProbe.mapAnonymous(256)}")
        line("  ${NativeProbe.mapExecutable()}")
    }

    private fun probe() {
        val started = System.currentTimeMillis()
        var booted = false
        line("")
        line("== runtime ==")
        if (!RishGuestNative.available) {
            check("librish_ffi.so and librish_guest_jni.so load", false,
                "System.loadLibrary failed; this build has no staged runtime")
            dumpOwnLog(40)
            summarise(started, booted)
            return
        }
        check("librish_ffi.so and librish_guest_jni.so load", true)
        val protocol = try { RishGuestNative.protocolVersion() } catch (error: Throwable) { -1 }
        check("protocolVersion() > 0", protocol > 0, "got $protocol")

        GuestRuntimeState.setGuestRuntimeMounted(false)
        val controller = GuestSessionController(AndroidGuestAssets(this), RishGuestNative)
        try {
            line("")
            line("== boot ==")
            // 256 MiB is the runtime's own floor. Walking down to it separates
            // "this device cannot spare the memory" from "this runtime cannot
            // run here at all", which the single rejection code cannot.
            var receipt: Map<String, Any?>? = null
            for (mib in listOf(768, 512, 256)) {
                val attempt = bootAttempt(controller, mib, 1500)
                if (attempt == null) {
                    check("boot at $mib MiB settles within 1500s", false, "still running")
                    break
                }
                if (attempt.code == null && attempt.receipt != null) {
                    check("boot succeeds", true, "at $mib MiB")
                    receipt = attempt.receipt
                    booted = true
                    break
                }
                line("  rejected: ${attempt.code} ${attempt.message.orEmpty()}")
                if (mib == 256) check("boot succeeds", false,
                    "${attempt.code} at every size from 768 down to 256 MiB")
            }

            if (!booted) {
                diagnose()
                dumpOwnLog(25)
            } else {
                check("status == booted", receipt!!["status"] == "booted", "got ${receipt["status"]}")
                check("kernel name matches", receipt["kernel"] == GuestAssets.KERNEL_NAME, "got ${receipt["kernel"]}")
                check("initramfs name matches", receipt["initramfs"] == GuestAssets.INITRAMFS_NAME, "got ${receipt["initramfs"]}")
                check("kernel sha256 matches", receipt["kernel_sha256"] == GuestAssets.KERNEL_SHA256)
                check("initramfs sha256 matches", receipt["initramfs_sha256"] == GuestAssets.INITRAMFS_SHA256)
                check("boot_ms > 0", (receipt["boot_ms"] as? Long ?: 0L) > 0L, "reported ${receipt["boot_ms"]}ms")
                check("registry reports a mounted guest", GuestRuntimeState.guestRuntimeMounted)

                line("")
                line("== single session ==")
                val second = bootAttempt(controller, 768, 60)
                if (second == null) check("a second boot settles", false, "still running")
                else check("a second boot is refused", second.code == "E_GUEST_ALREADY_BOOTED",
                    "got ${second.code ?: "a receipt"}")

                line("")
                line("== the guest is a real x86_64 machine ==")
                val uname = exec(controller, listOf("uname", "-m"), 300)
                if (uname == null) check("uname -m settles within 300s", false)
                else {
                    check("uname -m is not rejected", uname.code == null, uname.code.orEmpty())
                    val out = uname.receipt?.get("stdout") as? String ?: ""
                    check("stdout contains x86_64", out.contains("x86_64"), out.trim())
                }

                line("")
                line("== apk add tree, from the offline repository ==")
                val apk = exec(controller, listOf("apk", "add", "tree"), 1800)
                if (apk == null) check("apk add settles within 1800s", false)
                else {
                    check("apk add is not rejected", apk.code == null, apk.code.orEmpty())
                    check("ok == true", apk.receipt?.get("ok") == true, "got ${apk.receipt?.get("ok")}")
                    check("exit code == 0", apk.receipt?.get("exit_code") == 0, "got ${apk.receipt?.get("exit_code")}")
                    check("receipt carries boot_units", apk.receipt?.get("boot_units") != null)
                    val out = apk.receipt?.get("stdout") as? String ?: ""
                    check("output shows the tree install", out.contains("Installing tree"))
                    check("output finishes with OK:", out.contains("OK:"))
                }

                line("")
                line("== the installed binary runs ==")
                val tree = exec(controller, listOf("sh", "-lc", "/usr/bin/tree --version"), 300)
                if (tree == null) check("tree --version settles within 300s", false)
                else {
                    check("tree --version is not rejected", tree.code == null, tree.code.orEmpty())
                    check("exit code == 0", tree.receipt?.get("exit_code") == 0, "got ${tree.receipt?.get("exit_code")}")
                    val out = tree.receipt?.get("stdout") as? String ?: ""
                    check("reports tree v2.3.2", out.contains("tree v2.3.2"), out.trim())
                }
            }
        } catch (error: Throwable) {
            check("the probe runs without throwing", false, "${error.javaClass.simpleName}: ${error.message}")
        } finally {
            line("")
            line("== shutdown ==")
            val stop = Call()
            controller.shutdownGuest { stop.receipt = it; stop.done.countDown() }
            if (!stop.await(120)) {
                check("shutdown settles within 120s", false)
            } else {
                // A guest that never booted is correctly already idle. Demanding
                // "shutdown" there reported a failure the run had not earned.
                val status = stop.receipt?.get("status")
                val expected = if (booted) "shutdown" else "already_idle"
                check("status == $expected", status == expected, "got $status")
            }
            check("registry reports no mounted guest", !GuestRuntimeState.guestRuntimeMounted)
            controller.close()
        }
        summarise(started, booted)
    }

    /** Always the last thing printed, whatever happened above it. */
    private fun summarise(started: Long, booted: Boolean) {
        val elapsed = System.currentTimeMillis() - started
        val seconds = if (elapsed >= 1000) "${elapsed / 1000}s" else "${elapsed}ms"
        val verdict = when {
            failures == 0 -> "ALL $checks CHECKS PASSED in ${seconds}"
            !booted -> "$failures of $checks CHECKS FAILED in $seconds -- the guest did not boot here"
            else -> "$failures of $checks CHECKS FAILED in $seconds"
        }
        main.post {
            running = false
            run.isEnabled = true
            run.text = "Run again"
            output.append("\n\n$verdict\n")
        }
    }
}
