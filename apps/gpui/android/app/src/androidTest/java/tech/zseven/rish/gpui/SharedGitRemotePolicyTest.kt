package tech.zseven.rish.gpui

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import tech.zseven.rish.runtime.AndroidGitRemoteUrl
import tech.zseven.rish.runtime.RishAgentCoreNative

/** Actual JNI acceptance plus Android's existing HTTP(S)-only transport boundary. */
@RunWith(AndroidJUnit4::class)
class SharedGitRemotePolicyTest {
    @Before fun requireSharedNativePolicy() {
        assertTrue("The shared Rust agent core must be packaged for this acceptance gate", RishAgentCoreNative.available)
    }

    private fun policy(url: String, form: Boolean = false): JSONObject {
        val request = JSONObject().put("url", url).apply { if (form) put("form", true) }
        val reply = RishAgentCoreNative.gitRemotePolicy(request.toString())
        assertNotNull("The JNI Git policy must return an envelope", reply)
        return JSONObject(reply!!)
    }

    private fun accepted(input: String, canonical: String, host: String, port: Int, path: String) {
        val reply = policy(input)
        assertEquals(setOf("ok", "value"), reply.keys().asSequence().toSet())
        assertEquals(true, reply.get("ok"))
        val value = reply.getJSONObject("value")
        assertEquals(setOf("url", "canonical_url", "scheme", "host", "port", "username", "path", "scp"),
            value.keys().asSequence().toSet())
        assertEquals(canonical, value.getString("url"))
        assertEquals(canonical, value.getString("canonical_url"))
        assertEquals(canonical.substringBefore(":"), value.getString("scheme"))
        assertEquals(host, value.getString("host"))
        assertEquals(port, value.getInt("port"))
        assertTrue(value.isNull("username"))
        assertEquals(path, value.getString("path"))
        assertFalse(value.getBoolean("scp"))
        assertEquals(canonical, AndroidGitRemoteUrl.validated(input))
        assertEquals(host, AndroidGitRemoteUrl.hostOf(input))
        val padded = " \u0085\u00a0$input\u3000 "
        val sharedForm = policy(padded, form = true)
        assertTrue(sharedForm.getBoolean("ok"))
        assertEquals(canonical, sharedForm.getJSONObject("value").getString("canonical_url"))
        assertEquals(canonical, AndroidGitRemoteUrl.validatedForm(padded))
        val form = GitFormValidation.evaluate("remote", listOf(padded))
        assertNotNull(form)
        assertEquals(setOf("url"), form!!.keys().asSequence().toSet())
        assertEquals(canonical, form.getString("url"))
    }

    private fun rejected(url: String) {
        val reply = policy(url)
        assertEquals(setOf("ok", "error"), reply.keys().asSequence().toSet())
        assertEquals(false, reply.get("ok"))
        assertEquals("E_PROJECT_INVALID", reply.getString("error"))
        assertNull(AndroidGitRemoteUrl.validated(url))
        assertEquals("", AndroidGitRemoteUrl.hostOf(url))
        assertNull(GitFormValidation.evaluate("remote", listOf(url)))
    }

    @Test fun canonicalHttpIdentityKeepsExplicitPortAndRepositoryPathBytes() {
        accepted("HTTPS://GitHub.COM/Org/repo.git", "https://github.com/Org/repo.git", "github.com", 443, "/Org/repo.git")
        accepted("HTTPS://GitHub.COM:443/Org/repo.git", "https://github.com:443/Org/repo.git", "github.com", 443, "/Org/repo.git")
        accepted("https://github.com/a%20b", "https://github.com/a%20b", "github.com", 443, "/a b")
        accepted("https://github.com/%E4%B8%AD%E6%96%87.git", "https://github.com/%E4%B8%AD%E6%96%87.git", "github.com", 443, "/中文.git")
        // Repository path identity must not be NFC-normalized by the UI adapter.
        val decomposed = "https://github.com/cafe\u0301"
        accepted(decomposed, "https://github.com/cafe%CC%81", "github.com", 443, "/cafe\u0301")
        accepted("https://github.com/caf%C3%A9", "https://github.com/caf%C3%A9", "github.com", 443, "/café")
    }

    @Test fun httpAllowsOnlyLoopbackPrivateAndLinkLocalAddresses() {
        for (host in listOf("localhost", "127.0.0.1", "10.1.2.3", "172.16.0.1", "172.31.255.254", "192.168.1.2", "169.254.1.2")) {
            accepted("http://$host:8080/repo.git", "http://$host:8080/repo.git", host, 8080, "/repo.git")
        }
        for (url in listOf("http://github.com/repo", "http://8.8.8.8/repo", "http://172.32.0.1/repo",
            "http://192.169.1.2/repo", "http://fcfake/repo", "http://fdexample.com/repo")) rejected(url)
    }

    @Test fun ipv6AddressesUseRealParsingAndUnbracketedCredentialHost() {
        for (host in listOf("::1", "fd00::1", "fe80::1")) {
            accepted("http://[$host]:8000/repo", "http://[$host]:8000/repo", host, 8000, "/repo")
        }
        accepted("HTTP://[FC00::AB]:8080/repo", "http://[fc00::ab]:8080/repo", "fc00::ab", 8080, "/repo")
        for (url in listOf("http://[2001:4860:4860::8888]/repo", "http://[fcfake]/repo",
            "http://[::1%25en0]/repo", "https://[::1]/repo", "https://[2001:4860::1]/repo")) rejected(url)
    }

    @Test fun remoteNeverAcceptsCredentialsQueriesFragmentsOrNonPublicHttps() {
        for (url in listOf("https://user:token@github.com/org/repo", "https://user@github.com/repo",
            "https://github.com/repo?token=secret", "https://github.com/repo#token",
            "https://github.com/repo?", "https://github.com/repo#", "file:///tmp/repo", "ftp://example.com/repo",
            "https://host.internal/repo", "https://host.local/repo", "https://host.localhost/repo", "https://github.com./repo",
            "https://github.com:8443/repo", "https://127.0.0.1/repo", "https://8.8.8.8/repo",
            "http://localhost:0/repo", "http://localhost:65536/repo")) rejected(url)
    }

    @Test fun unsafeAndMissingRepositoryPathsAreRejectedBeforeTransport() {
        for (url in listOf("https://github.com", "https://github.com/", "https://github.com/a/../repo",
            "https://github.com/a/./repo", "https://github.com/a/%2e%2e/repo", "https://github.com/%2E/repo",
            "https://github.com/%00repo", "https://github.com/a%5cb", "https://github.com/a\\b",
            "https://github.com/a\u200db", "https://github.com/a%0Ab", "https://github.com/a%ZZb",
            "https://github.com/" + "a".repeat(2048))) rejected(url)
    }

    @Test fun sharedSshRecognitionDoesNotEnableAnAndroidSshTransport() {
        for (url in listOf("git@github.com:org/repo.git", "ssh://git@github.com/org/repo.git")) {
            val reply = policy(url)
            assertTrue(reply.getBoolean("ok"))
            assertEquals("ssh", reply.getJSONObject("value").getString("scheme"))
            assertNull(AndroidGitRemoteUrl.validated(url))
            assertEquals("", AndroidGitRemoteUrl.hostOf(url))
            assertNull(GitFormValidation.evaluate("remote", listOf(url)))
        }
    }

    @Test fun formOnlyTrimsPeripheralWhitespaceAndCounts2048Utf8Bytes() {
        val prefix = "https://github.com/"
        val input = prefix + "a".repeat(2048 - prefix.length)
        assertEquals(input, AndroidGitRemoteUrl.validatedForm(input))
        assertEquals(input, GitFormValidation.evaluate("remote", listOf(" \t$input\n "))!!.getString("url"))
        assertFalse(policy(" $input ").getBoolean("ok")) // Stored origins are not form text.
        assertEquals(input + "a", AndroidGitRemoteUrl.validated(input + "a"))
        assertFalse(policy(input + "a", form = true).getBoolean("ok"))
        assertNull(AndroidGitRemoteUrl.validatedForm(input + "a"))
        assertNull(GitFormValidation.evaluate("remote", listOf(input + "a")))

        val unicodeBoundary = prefix + "中".repeat((2048 - prefix.length) / 3) +
            "a".repeat((2048 - prefix.length) % 3)
        assertEquals(2048, unicodeBoundary.toByteArray(Charsets.UTF_8).size)
        // Within the raw form budget, but its escaped origin exceeds the
        // transport limit. Do not accept a URL that cannot be read back.
        rejected(unicodeBoundary)
        assertFalse(policy(unicodeBoundary, form = true).getBoolean("ok"))
        assertNull(AndroidGitRemoteUrl.validatedForm(unicodeBoundary))
    }

    @Test fun encodedUnicodeOriginRoundTripsAtTheTransportLimit() {
        val prefix = "https://example.com/"
        val budget = 4096 - prefix.length
        val tail = "a".repeat(budget % 9)
        val raw = prefix + "中".repeat(budget / 9) + tail
        val canonical = prefix + "%E4%B8%AD".repeat(budget / 9) + tail
        assertEquals(4096, canonical.length)
        assertTrue(raw.toByteArray(Charsets.UTF_8).size < 2048)
        accepted(raw, canonical, "example.com", 443, "/" + "中".repeat(budget / 9) + tail)
        assertEquals(canonical, AndroidGitRemoteUrl.validated(canonical))
        assertEquals(policy(raw).toString(), policy(canonical).toString())
        rejected(raw + "a")
        rejected(canonical + "a")
        assertNull(AndroidGitRemoteUrl.validatedForm(raw + "a"))
    }

    @Test fun longerTransportOriginKeeps4096UnitLimitWithoutExpandingTheFormLimit() {
        val prefix = "https://github.com/"
        val room = 4096 - prefix.length
        // Escaped path remains below the decoded-path bound while origin reaches 4096 units.
        val boundary = prefix + "%61".repeat(room / 3) + "a".repeat(room % 3)
        assertEquals(4096, boundary.length)
        assertTrue(policy(boundary).getBoolean("ok"))
        assertEquals(boundary, AndroidGitRemoteUrl.validated(boundary))
        assertEquals("github.com", AndroidGitRemoteUrl.hostOf(boundary))
        assertNull(AndroidGitRemoteUrl.validatedForm(boundary))
        assertNull(GitFormValidation.evaluate("remote", listOf(boundary)))
        assertFalse(policy(boundary + "a").getBoolean("ok"))
        assertNull(AndroidGitRemoteUrl.validated(boundary + "a"))
    }

    @Test fun nativeRequestSchemaDoesNotIgnoreExtraOrDuplicateUrlFields() {
        for (request in listOf("null", "{}", "{\"url\":42}",
            "{\"url\":\"https://github.com/repo\",\"extra\":true}",
            "{\"url\":\"https://github.com/repo\",\"form\":false}",
            "{\"url\":\"https://github.com/repo\",\"form\":\"true\"}",
            "{\"url\":\"https://github.com/repo\",\"form\":true,\"extra\":true}",
            "{\"url\":\"https://github.com/first\",\"url\":\"https://github.com/second\"}")) {
            val reply = JSONObject(RishAgentCoreNative.gitRemotePolicy(request)!!)
            assertEquals(false, reply.get("ok"))
            assertEquals("E_PROJECT_INVALID", reply.getString("error"))
        }
    }
}
