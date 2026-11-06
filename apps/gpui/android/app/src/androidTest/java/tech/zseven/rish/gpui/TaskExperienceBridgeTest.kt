package tech.zseven.rish.gpui

import android.app.NotificationManager
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.system.Os
import android.system.OsConstants
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.core.app.ActivityScenario
import androidx.lifecycle.Lifecycle
import dev.gpui.mobile.GpuiActivity
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleCallback
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.tasks.TaskExperience
import java.io.File
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

@RunWith(AndroidJUnit4::class)
class TaskExperienceBridgeTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private fun id() = UUID.randomUUID().toString()
    private fun request(op: String) = JSONObject().put("schema_version", 1).put("op", op)
    private fun preferences(background: Boolean = false) = JSONObject()
        .put("completed", false).put("failed", false).put("attention", false)
        .put("liveActivity", false).put("background", background).put("muted", JSONArray())
    private fun call(request: JSONObject): Any = RishGpuiBridge.routePlatform(
        context, null, "TaskExperience", "handle", JSONArray().put(request),
    ) { error("unexpected permission callback") }
    private fun begin(run: String, conversation: String, eligible: Boolean = false) =
        call(request("begin").put("runId", run).put("conversationId", conversation).put("backgroundEligible", eligible))
    private fun onMain(body: () -> Unit) = instrumentation.runOnMainSync(body)
    private fun awaitRenderer() {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(15)
        while (!GpuiActivity.nativeIsInitialized() && System.nanoTime() < deadline) Thread.sleep(25)
        assertTrue("Activity must finish initializing its GPUI renderer", GpuiActivity.nativeIsInitialized())
    }
    private fun fixture(body: (MutableList<Pair<String, JSONObject>>) -> Unit) {
        val events = mutableListOf<Pair<String, JSONObject>>()
        onMain {
            RishGpuiBridge.initialize(context)
            TaskExperience.activeRun()?.let { call(request("end").put("runId", it.id).put("status", "cancelled")) }
            call(request("preferences").put("preferences", preferences()))
            call(request("drain"))
            RishGpuiBridge.bindTaskEvents { name, value -> events.add(name to value) }
            TaskExperience.resume()
            events.clear()
        }
        try { body(events) }
        finally {
            onMain {
                TaskExperience.activeRun()?.let { call(request("end").put("runId", it.id).put("status", "cancelled")) }
                call(request("preferences").put("preferences", preferences()))
                call(request("drain"))
                TaskExperience.pause()
                RishGpuiBridge.bindTaskEvents()
            }
        }
    }

    @Test fun storageRouteReturnsOnlyThePrivateAssistantDirectory() {
        val result = RishGpuiBridge.routePlatform(context, null, "ShellAssistant", "storage", JSONArray()) { }
            as JSONObject
        val directory = File(result.getString("directory"))
        assertEquals(File(context.filesDir, "assistant-v1").canonicalPath, directory.path)
        assertEquals(directory.canonicalPath, directory.path)
        assertEquals("android", result.getString("platform"))
        assertEquals(1, result.getInt("schema_version"))
        val stat = Os.lstat(directory.path)
        assertTrue(OsConstants.S_ISDIR(stat.st_mode))
        assertEquals(0x1c0, stat.st_mode and 0x1ff)
        assertThrows(IllegalArgumentException::class.java) {
            RishGpuiBridge.routePlatform(context, null, "ShellAssistant", "storage", JSONArray().put("extra")) { }
        }
    }

    @Test fun storageRouteRejectsASymlinkInsteadOfHandingRustAnExternalDirectory() {
        val root = File(context.cacheDir, "assistant-storage-${id()}").apply { mkdirs() }
        val outside = File(root, "outside").apply { mkdirs() }
        val appFiles = File(root, "files").apply { mkdirs() }
        val scoped = object : ContextWrapper(context) { override fun getFilesDir(): File = appFiles }
        try {
            Os.symlink(outside.path, File(appFiles, "assistant-v1").path)
            assertThrows(BridgeFailure::class.java) {
                RishGpuiBridge.routePlatform(scoped, null, "ShellAssistant", "storage", JSONArray()) { }
            }
            assertTrue(outside.isDirectory)
            assertTrue(outside.listFiles()!!.isEmpty())
        } finally { root.deleteRecursively() }
    }

    @Test fun settingsAndMissingForegroundPermissionRequestNeverAskForPermission() = fixture { _ ->
        onMain {
            val prefs = context.getSharedPreferences("rish.task.experience.v1", Context.MODE_PRIVATE)
            prefs.edit().remove("permissionRequested").commit()
            val settings = call(request("settings")) as JSONObject
            assertTrue(settings.getBoolean("foreground"))
            assertFalse(settings.getJSONObject("preferences").getBoolean("background"))
            assertFalse(settings.getJSONObject("preferences").getBoolean("liveActivity"))
            call(request("permission").put("userInitiated", true)) // No Activity is attached: report current authorization only.
            assertFalse(prefs.getBoolean("permissionRequested", false))
            assertThrows(IllegalArgumentException::class.java) {
                call(JSONObject().put("schema_version", true).put("op", "permission"))
            }
        }
    }

    @Test fun scheduledForegroundRunCannotAcquireBackgroundAndPauseReachesEventSinkWithoutDrain() = fixture { events ->
        onMain {
            call(request("preferences").put("preferences", preferences(background = true)))
            val run = id(); val conversation = id()
            begin(run, conversation, eligible = false)
            assertEquals("notRequested", TaskExperience.backgroundAdmission)
            assertFalse(TaskExperience.canAdmitBackground(run))
            TaskExperience.pause()
            assertEquals(listOf("taskExperienceLifecycle", "taskExperienceAction"), events.map { it.first })
            assertFalse(events[0].second.getBoolean("foreground"))
            assertEquals("cancel", events[1].second.getString("action"))
            assertEquals(run, events[1].second.getString("runId"))
            assertEquals("background_expired", events[1].second.getString("reason"))
            assertTrue(TaskExperience.activeRun()!!.stopRequested)
            TaskExperience.resume()
            assertTrue(events.last().second.getBoolean("foreground"))
        }
    }

    @Test fun realNotificationStopPendingIntentPublishesOneActorEventWithoutDrain() = fixture { events ->
        val received = CountDownLatch(1)
        lateinit var pending: android.app.PendingIntent
        val run = id(); val conversation = id()
        onMain {
            begin(run, conversation)
            RishGpuiBridge.bindTaskEvents { name, value ->
                events.add(name to value)
                if (name == "taskExperienceAction" && value.optString("action") == "cancel") received.countDown()
            }
            pending = TaskExperience.progressNotification()!!.actions[0].actionIntent
        }
        pending.send()
        assertTrue("Stop must reach the process event sink without drain", received.await(5, TimeUnit.SECONDS))
        pending.send()
        instrumentation.waitForIdleSync()
        onMain {
            val actions = events.filter { it.first == "taskExperienceAction" }
            assertEquals(1, actions.size)
            assertEquals(run, actions[0].second.getString("runId"))
            assertEquals(conversation, actions[0].second.getString("conversationId"))
            assertEquals("user_stop", actions[0].second.getString("reason"))
            assertTrue(TaskExperience.activeRun()!!.stopRequested)
            assertEquals(false, call(request("update").put("runId", run).put("phase", "approval_pending")))
            assertEquals("cancelling", TaskExperience.activeRun()!!.phase)
        }
    }

    @Test fun expiryFinishesOnlyItsOwnerAndOldPendingIntentCannotStopTheNextRun() = fixture { events ->
        lateinit var oldStop: android.app.PendingIntent
        val first = id(); val firstConversation = id(); val second = id(); val secondConversation = id()
        onMain {
            begin(first, firstConversation)
            oldStop = TaskExperience.progressNotification()!!.actions[0].actionIntent
            assertTrue(TaskExperience.expire(first))
            assertNull(TaskExperience.activeRun())
            assertEquals("notRequested", TaskExperience.backgroundAdmission)
            assertEquals("background_expired", events.single().second.getString("reason"))
            val manager = context.getSystemService(NotificationManager::class.java)
            assertFalse(manager.activeNotifications.any { it.id == TaskExperience.ONGOING_ID })
            begin(second, secondConversation)
            assertFalse(TaskExperience.expire(first))
            TaskExperience.backgroundLost(first)
        }
        oldStop.send()
        instrumentation.waitForIdleSync()
        onMain {
            assertEquals(second, TaskExperience.activeRun()!!.id)
            assertFalse(TaskExperience.activeRun()!!.stopRequested)
            assertEquals(1, events.size)
        }
    }

    @Test fun realActivityLifecycleReportsPauseAndResumeToTheProcessSink() = fixture { events ->
        ActivityScenario.launch(GpuiActivity::class.java).use { scenario ->
            awaitRenderer()
            scenario.onActivity {
                RishGpuiBridge.bindTaskEvents { name, value -> events.add(name to value) }
                begin(id(), id())
                events.clear()
            }
            scenario.moveToState(Lifecycle.State.CREATED)
            onMain {
                assertFalse(TaskExperience.foreground)
                assertEquals(listOf("taskExperienceLifecycle", "taskExperienceAction"), events.map { it.first })
                assertEquals("background_expired", events.last().second.getString("reason"))
            }
            scenario.moveToState(Lifecycle.State.RESUMED)
            onMain {
                assertTrue(TaskExperience.foreground)
                assertEquals("taskExperienceLifecycle", events.last().first)
                assertTrue(events.last().second.getBoolean("foreground"))
            }
        }
    }

    @Test fun activityRecreationInTheSameProcessStartsAFreshRenderer() {
        repeat(2) {
            ActivityScenario.launch(GpuiActivity::class.java).use { scenario ->
                awaitRenderer()
                val storeLock = File(context.filesDir, "assistant-v1/.assistant-v1.lock")
                val storeDeadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
                while (!storeLock.isFile && System.nanoTime() < storeDeadline) Thread.sleep(25)
                assertTrue("The actual Rust assistant must open its native private directory", storeLock.isFile)
                scenario.onActivity { assertFalse(it.isFinishing) }
            }
            assertFalse("Destroyed renderer must clear readiness", GpuiActivity.nativeIsInitialized())
        }
    }

    @Test fun pauseDuringInitialRendererStartupRemainsResponsive() {
        // Deliberately do not wait for first-frame readiness before pausing.
        // This catches lifecycle ACK stalls that a ready-only test would hide.
        ActivityScenario.launch(GpuiActivity::class.java).use { scenario ->
            scenario.moveToState(Lifecycle.State.CREATED)
            onMain { assertFalse(TaskExperience.foreground) }
            scenario.moveToState(Lifecycle.State.RESUMED)
            awaitRenderer()
            onMain { assertTrue(TaskExperience.foreground) }
        }
    }

    @Test fun notificationOpenReusesTheCurrentActivityAndRenderer() = fixture { events ->
        ActivityScenario.launch(GpuiActivity::class.java).use { scenario ->
            awaitRenderer()
            val opened = CountDownLatch(1)
            val created = AtomicInteger()
            val monitor = ActivityLifecycleMonitorRegistry.getInstance()
            val callback = ActivityLifecycleCallback { activity, stage ->
                if (activity is GpuiActivity && stage == Stage.CREATED) created.incrementAndGet()
            }
            lateinit var open: android.app.PendingIntent
            lateinit var owner: GpuiActivity
            lateinit var launchIntent: Intent
            val run = id(); val conversation = id()
            scenario.onActivity {
                owner = it
                launchIntent = Intent(it.intent)
                RishGpuiBridge.bindTaskEvents { name, value ->
                    events.add(name to value)
                    if (name == "taskExperienceAction" && value.optString("action") == "open") opened.countDown()
                }
                begin(run, conversation)
                open = TaskExperience.progressNotification()!!.contentIntent
                monitor.addLifecycleCallback(callback)
            }
            try {
                open.send()
                assertTrue("Notification must open the existing Activity", opened.await(5, TimeUnit.SECONDS))
                instrumentation.waitForIdleSync()
                scenario.onActivity { assertFalse(it.isFinishing) }
                assertEquals("Notification must not create a second native render thread", 0, created.get())
                onMain {
                    val action = events.last { it.first == "taskExperienceAction" }.second
                    assertEquals(run, action.getString("runId"))
                    assertEquals(conversation, action.getString("conversationId"))
                }
            } finally {
                onMain {
                    monitor.removeLifecycleCallback(callback)
                    // ActivityScenario filters lifecycle callbacks by launch
                    // Intent. The real onNewIntent correctly stores OPEN_TASK;
                    // restore only this test fixture before Scenario closes it.
                    owner.intent = launchIntent
                }
            }
        }
    }

    @Test fun explicitForegroundRunCanAcquireOsServiceAndPreferenceRevocationCancelsAfterPause() = fixture { events ->
        ActivityScenario.launch(GpuiActivity::class.java).use { scenario ->
            awaitRenderer()
            val run = id(); val conversation = id()
            scenario.onActivity {
                RishGpuiBridge.bindTaskEvents { name, value -> events.add(name to value) }
                call(request("preferences").put("preferences", preferences(background = true)))
                val started = begin(run, conversation, eligible = true) as JSONObject
                assertTrue(started.getBoolean("started"))
            }
            var admission = "notRequested"
            for (attempt in 0 until 40) {
                instrumentation.waitForIdleSync()
                onMain { admission = TaskExperience.backgroundAdmission }
                if (admission != "submitted") break
                Thread.sleep(25)
            }
            assertEquals("accepted", admission)
            scenario.moveToState(Lifecycle.State.CREATED)
            onMain {
                assertFalse(TaskExperience.foreground)
                assertFalse(TaskExperience.activeRun()!!.stopRequested)
                assertTrue(TaskExperience.canAdmitBackground(run))
                call(request("preferences").put("preferences", preferences(background = false)))
                assertNull(TaskExperience.activeRun())
                assertFalse(TaskExperience.canAdmitBackground(run))
                val action = events.last { it.first == "taskExperienceAction" }.second
                assertEquals(run, action.getString("runId"))
                assertEquals("background_expired", action.getString("reason"))
            }
        }
    }

    @Test fun activeRunIdentityCannotBeReboundAndNotificationOpenUsesTheSameSink() = fixture { events ->
        onMain {
            val run = id(); val conversation = id()
            begin(run, conversation)
            assertThrows(IllegalArgumentException::class.java) { begin(run, id()) }
            assertThrows(IllegalArgumentException::class.java) { begin(id(), id()) }
            TaskExperience.open(Intent(TaskExperience.OPEN).putExtra("runId", run).putExtra("conversationId", conversation))
            assertEquals("taskExperienceAction", events.single().first)
            assertEquals("open", events.single().second.getString("action"))
            assertFalse(events.single().second.has("reason"))
        }
    }
}
