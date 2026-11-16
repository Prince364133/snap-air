@file:Suppress("DEPRECATION")

package live.snapy.app

import android.app.Activity
import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.os.Build
import android.os.Bundle
import android.os.CancellationSignal
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.security.keystore.UserNotAuthenticatedException
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.PublicKey
import java.security.SecureRandom
import java.security.spec.MGF1ParameterSpec
import java.security.spec.X509EncodedKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.OAEPParameterSpec
import javax.crypto.spec.PSource
import javax.crypto.spec.SecretKeySpec

/**
 * Ghost-mode vault (docs/ANDROID_NEXT_PLAN.md §8, suggestion 3): the vault's Markdown files
 * (meeting notes with transcripts in files/snapy/vault) are sealed with a Keystore key that
 * needs the user's biometric / device credential, and the vault view opens only after
 * BiometricPrompt.
 *
 * Hybrid scheme so new notes can be sealed while the phone is locked (a meeting saved with the
 * phone in a pocket): RSA-2048 key pair in the Android Keystore with
 * setUserAuthenticationRequired(true); encrypting uses only the PUBLIC key (never needs auth),
 * decrypting needs the private key, usable for [AUTH_WINDOW_S] seconds after the user
 * authenticates. Each file: a random AES-256-GCM key, wrapped with RSA-OAEP(SHA-256, MGF1-SHA1 —
 * the MGF1 digest Keystore supports on every version). File format "<name>.md.enc":
 *   "SNV1" | u16 wrappedLen | wrapped | 12-byte IV | AES-GCM ciphertext+tag
 * Limits: the runtime's live stores (memory.json, notes.json) stay readable by the app so the
 * assistant works offline; Ghost mode gates the vault VIEW, export and clear behind the
 * biometric prompt and encrypts the Markdown copies. Needs a secure lock screen; the key is not
 * invalidated by enrolling a new fingerprint (so sealed notes are not lost).
 */
object GhostVault {
    private const val ALIAS = "snapy_ghost_vault"
    private const val MAGIC = "SNV1"
    const val AUTH_WINDOW_S = 30
    private val oaep = OAEPParameterSpec("SHA-256", "MGF1", MGF1ParameterSpec.SHA1, PSource.PSpecified.DEFAULT)

    fun enabled(ctx: Context) = RcPrefs(ctx).bool("ghost_mode", false)

    private fun ks() = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    private fun ensureKey(ctx: Context) {
        if (ks().containsAlias(ALIAS)) return
        val km = ctx.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
        if (!km.isDeviceSecure) throw IllegalStateException("no_secure_lock")
        val b = KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setKeySize(2048)
            .setDigests(KeyProperties.DIGEST_SHA256, KeyProperties.DIGEST_SHA1)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_RSA_OAEP)
            .setUserAuthenticationRequired(true)
            .setInvalidatedByBiometricEnrollment(false)
        if (Build.VERSION.SDK_INT >= 30) b.setUserAuthenticationParameters(AUTH_WINDOW_S,
            KeyProperties.AUTH_BIOMETRIC_STRONG or KeyProperties.AUTH_DEVICE_CREDENTIAL)
        else b.setUserAuthenticationValidityDurationSeconds(AUTH_WINDOW_S)
        KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_RSA, "AndroidKeyStore").apply { initialize(b.build()) }.generateKeyPair()
    }

    private fun publicKey(): PublicKey {
        val pub = ks().getCertificate(ALIAS).publicKey
        return KeyFactory.getInstance(pub.algorithm).generatePublic(X509EncodedKeySpec(pub.encoded))   // software copy: no auth
    }

    private fun privateKey(): PrivateKey = ks().getKey(ALIAS, null) as PrivateKey

    fun seal(ctx: Context, plain: File): Boolean {
        if (!plain.exists() || plain.name.endsWith(".enc")) return false
        ensureKey(ctx)
        val data = plain.readBytes()
        val aes = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        val rsa = Cipher.getInstance("RSA/ECB/OAEPPadding").apply { init(Cipher.ENCRYPT_MODE, publicKey(), oaep) }
        val wrapped = rsa.doFinal(aes.encoded)
        val iv = ByteArray(12).also { SecureRandom().nextBytes(it) }
        val gcm = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, aes, GCMParameterSpec(128, iv)) }
        val ct = gcm.doFinal(data)
        val out = ByteArrayOutputStream()
        DataOutputStream(out).use { o -> o.write(MAGIC.toByteArray()); o.writeShort(wrapped.size); o.write(wrapped); o.write(iv); o.write(ct) }
        val enc = File(plain.path + ".enc")
        val tmp = File(enc.path + ".tmp")
        tmp.writeBytes(out.toByteArray())
        if (!tmp.renameTo(enc)) { enc.delete(); tmp.renameTo(enc) }
        plain.delete()
        return true
    }

    /** Throws UserNotAuthenticatedException outside the auth window. */
    fun open(enc: File): ByteArray {
        DataInputStream(enc.inputStream()).use { i ->
            val magic = ByteArray(4); i.readFully(magic)
            require(String(magic) == MAGIC) { "not a vault file" }
            val wrapped = ByteArray(i.readUnsignedShort()); i.readFully(wrapped)
            val iv = ByteArray(12); i.readFully(iv)
            val ct = i.readBytes()
            val rsa = Cipher.getInstance("RSA/ECB/OAEPPadding").apply { init(Cipher.DECRYPT_MODE, privateKey(), oaep) }
            val aes = SecretKeySpec(rsa.doFinal(wrapped), "AES")
            return Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.DECRYPT_MODE, aes, GCMParameterSpec(128, iv)) }.doFinal(ct)
        }
    }

    fun openText(enc: File): String? = try { String(open(enc), Charsets.UTF_8) } catch (_: UserNotAuthenticatedException) { null } catch (_: Exception) { null }

    /** Runtime event "vault_file": seal it when Ghost mode is on (off the main thread). */
    fun sealIfEnabled(ctx: Context, path: String) {
        if (!enabled(ctx) || path.isEmpty()) return
        Thread { try { seal(ctx, File(path)) } catch (_: Exception) { } }.start()
    }

    private fun vaultFiles(ctx: Context, enc: Boolean): List<File> =
        File(ctx.filesDir, "snapy/vault").walkTopDown().filter { it.isFile && (if (enc) it.name.endsWith(".md.enc") else it.name.endsWith(".md")) }.toList()

    /** Turn Ghost mode on (seal every vault file) or off (needs a fresh auth: unseal them). */
    fun setEnabled(ctx: Context, on: Boolean): String? = try {
        if (on) {
            ensureKey(ctx)
            vaultFiles(ctx, enc = false).forEach { seal(ctx, it) }
            RcPrefs(ctx).putBool("ghost_mode", true)
        } else {
            for (f in vaultFiles(ctx, enc = true)) {
                val plain = File(f.path.removeSuffix(".enc"))
                plain.writeBytes(open(f)); f.delete()
            }
            RcPrefs(ctx).putBool("ghost_mode", false)
        }
        null
    } catch (_: UserNotAuthenticatedException) { "auth" } catch (e: IllegalStateException) { e.message ?: "error" } catch (e: Exception) { "error" }

    // ------------------------------------------------------------------ biometric gate
    @Volatile private var pending: ((Boolean) -> Unit)? = null
    @Volatile private var authedAt = 0L

    /** Fresh enough to skip a prompt (inside the Keystore auth window). */
    fun recentlyAuthed() = System.currentTimeMillis() - authedAt < (AUTH_WINDOW_S - 5) * 1000L

    /** Opens the system prompt (fingerprint / face / device credential); [done] on the main thread. */
    fun authenticate(ctx: Context, done: (Boolean) -> Unit) {
        if (recentlyAuthed()) { done(true); return }
        pending = done
        try { ctx.startActivity(Intent(ctx, VaultAuthActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
        catch (_: Exception) { pending = null; done(false) }
    }

    internal fun finishAuth(ok: Boolean) {
        if (ok) authedAt = System.currentTimeMillis()
        val p = pending; pending = null
        CoreBridge.mainHandler.post { p?.invoke(ok) }
    }
}

/** A see-through activity hosting the system auth UI (BiometricPrompt on 28+, else the
 *  confirm-device-credential screen), so any caller (Flutter screens included) can ask. */
class VaultAuthActivity : Activity() {
    private var answered = false

    private fun answer(ok: Boolean) { if (!answered) { answered = true; GhostVault.finishAuth(ok) }; finish() }

    private fun t(key: String, fallback: String) = Strings.t(this, key).let { if (it == key) fallback else it }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val title = t("vault.auth_title", "Open your Snapy vault")
        val sub = t("vault.auth_subtitle", "Ghost mode: your notes stay encrypted on this phone")
        if (Build.VERSION.SDK_INT >= 28) {
            val b = BiometricPrompt.Builder(this).setTitle(title).setSubtitle(sub)
            when {
                Build.VERSION.SDK_INT >= 30 -> b.setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG or BiometricManager.Authenticators.DEVICE_CREDENTIAL)
                Build.VERSION.SDK_INT >= 29 -> b.setDeviceCredentialAllowed(true)
                else -> b.setNegativeButton(t("vault.cancel", "Cancel"), mainExecutor) { _, _ -> answer(false) }
            }
            try {
                b.build().authenticate(CancellationSignal(), mainExecutor, object : BiometricPrompt.AuthenticationCallback() {
                    override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult?) = answer(true)
                    override fun onAuthenticationError(errorCode: Int, errString: CharSequence?) = answer(false)
                })
            } catch (_: Exception) { answer(false) }
        } else {
            val km = getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
            val i = km.createConfirmDeviceCredentialIntent(title, sub)
            if (i == null) answer(false) else startActivityForResult(i, 61)
        }
    }

    @Deprecated("framework callback")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == 61) answer(resultCode == RESULT_OK)
    }

    override fun onDestroy() { if (!answered) GhostVault.finishAuth(false); super.onDestroy() }
}
