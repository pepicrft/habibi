package fyi.habibi.app

import android.content.Intent
import android.content.res.ColorStateList
import android.net.Uri
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.LinearLayout
import androidx.appcompat.app.AlertDialog
import androidx.core.graphics.ColorUtils
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.widget.NestedScrollView
import com.google.android.material.bottomsheet.BottomSheetBehavior
import com.google.android.material.bottomsheet.BottomSheetDialog
import com.google.android.material.bottomsheet.BottomSheetDragHandleView
import com.google.android.material.button.MaterialButton
import com.google.android.material.dialog.MaterialAlertDialogBuilder

/** Activity-owned window, application-owned authorization. Pausing for the browser
 * never dismisses/cancels; explicit dismissal invalidates even a queued auth start. */
internal class GitHubDetailSheet(
    private val activity: MainActivity,
    private val session: HabibiSession,
    startingAuthorization: Boolean,
    private val dismissed: () -> Unit,
    private val navigate: (String) -> Unit,
) {
    private val dialog = DismissAwareSheet(activity)
    private var confirmation: AlertDialog? = null
    private var pending: String? = if (startingAuthorization) STARTING else null
    val startingAuthorization get() = pending == STARTING
    private var signature: List<Any?>? = null
    private val state = activity.column(0)
    private val details = activity.column(0).apply { visibility = View.GONE; tag = "github_details" }
    private val disclosure = activity.label("Before connecting: the conversation agent can read your GitHub profile and public repositories. Sanitized results go to your inference provider and encrypted conversation. Credentials stay private in your vault, never sent to that provider or Kit guests. Host/provider retention, terms and charges apply.", 14f, true).apply { tag = "github_disclosure" }

    init {
        val body = activity.column().apply {
            tag = "github_detail"
            isSaveEnabled = false
            setPadding(activity.dp(24), 0, activity.dp(24), activity.dp(24))
            addView(activity.kitIcon(true, 72).apply { (layoutParams as LinearLayout.LayoutParams).gravity = Gravity.CENTER_HORIZONTAL })
            val page = runCatching { session.kitPage("github") }.getOrElse {
                org.json.JSONObject().put("fallback", "GitHub\nKit presentation unavailable. You can still manage this connection below.")
            }
            addView(KitPageView(activity, page))
            addView(activity.label("Host permission · read:user · Authenticate on GitHub in your browser.", 13f, true))
            addView(state)
            addView(activity.kitTextButton("Recovery and revocation details", "github_details_toggle") {
                val expanded = details.visibility != View.VISIBLE
                details.visibility = if (expanded) View.VISIBLE else View.GONE
                val toggle = findViewWithTag<MaterialButton>("github_details_toggle")
                toggle.setIconResource(if (expanded) com.google.android.material.R.drawable.mtrl_ic_arrow_drop_up else com.google.android.material.R.drawable.mtrl_ic_arrow_drop_down)
                ViewCompat.setStateDescription(toggle, if (expanded) "Expanded" else "Collapsed")
            }.apply {
                setIconResource(com.google.android.material.R.drawable.mtrl_ic_arrow_drop_down)
                iconGravity = MaterialButton.ICON_GRAVITY_TEXT_END
                iconTint = ColorStateList.valueOf(activity.color(R.color.primary))
                ViewCompat.setStateDescription(this, "Collapsed")
            })
            details.addView(activity.label("Connections are encrypted inside your vault, recovery backups and manual encrypted sync snapshots. On another device, import the same encrypted recovery backup and its separate recovery key, then sync manually. Habibi account sign-in does not recover vault keys or GitHub access.", 14f, true))
            details.addView(activity.label("Disconnect is local until you sync. Other devices and old backups retain tokens. For actual revocation, use GitHub Settings → Applications → Authorized OAuth Apps (or Authorized GitHub Apps) and revoke the app. Expired or revoked access requires reconnecting; Habibi never stores or rotates refresh tokens.", 14f, true))
            details.addView(activity.kitTextButton("Encrypted sync", "github_sync") { navigate("sync") })
            details.addView(activity.kitTextButton("Recovery and backups", "github_recovery") { navigate("recovery") })
            addView(details)
        }
        dialog.setContentView(activity.column(0).apply {
            addView(FrameLayout(activity).apply {
                addView(BottomSheetDragHandleView(activity).apply {
                    imageTintList = ColorStateList.valueOf(activity.color(R.color.secondary))
                }, FrameLayout.LayoutParams(activity.dp(48), activity.dp(48), Gravity.CENTER))
                addView(activity.kitTextButton("Close", "github_close") { dialog.dismiss() }.apply {
                    contentDescription = "Close GitHub details"
                }, FrameLayout.LayoutParams(-2, activity.dp(48), Gravity.END).apply { marginEnd = activity.dp(12) })
            }, LinearLayout.LayoutParams(-1, activity.dp(48)))
            addView(NestedScrollView(activity).apply {
                isFillViewport = false; isSaveEnabled = false; addView(body)
            }, LinearLayout.LayoutParams(-1, 0, 1f))
        }, ViewGroup.LayoutParams(-1, (activity.resources.displayMetrics.heightPixels * .92).toInt()))
        dialog.window?.apply {
            addFlags(WindowManager.LayoutParams.FLAG_SECURE)
            setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE or WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_HIDDEN)
            statusBarColor = activity.color(R.color.paper)
            navigationBarColor = activity.color(R.color.paper)
            val light = ColorUtils.calculateLuminance(activity.color(R.color.paper)) > .5
            WindowCompat.getInsetsController(this, decorView).apply {
                isAppearanceLightStatusBars = light; isAppearanceLightNavigationBars = light
            }
        }
        dialog.behavior.apply {
            maxWidth = activity.dp(640)
            maxHeight = (activity.resources.displayMetrics.heightPixels * .92).toInt()
            peekHeight = activity.resources.displayMetrics.heightPixels / 2
            skipCollapsed = false
        }
        dialog.explicitDismissal = {
            confirmation?.dismiss(); confirmation = null
            val cancel = session.kitAuthorizing || pending == STARTING
            dismissed() // Clear Activity's open flag before cancellation publishes a render.
            if (cancel) session.cancelGitHubAuthorization()
        }
    }

    fun show() {
        render(); dialog.show()
        dialog.findViewById<View>(com.google.android.material.R.id.design_bottom_sheet)?.apply {
            backgroundTintList = ColorStateList.valueOf(activity.color(R.color.paper))
        }
        dialog.behavior.state = BottomSheetBehavior.STATE_COLLAPSED
    }

    fun dismiss() = dialog.dismiss()

    /** Rotation/theme recreation must remove windows without cancelling the app's flow. */
    fun dispose() {
        dialog.explicitDismissal = null
        confirmation?.dismiss(); confirmation = null
        dialog.dismiss()
    }

    private fun run(label: String, action: () -> Unit) {
        pending = label; action(); render()
    }

    fun render() {
        if (!session.busy) pending = null
        val account = session.githubAccount
        val authorizing = session.kitAuthorizing
        val code = session.githubAuthorization?.code
        val next = listOf(account, authorizing, code, session.githubMessage, session.githubConfigured,
            session.canManageConnections, session.busy, session.error, pending)
        if (signature == next) return
        signature = next
        state.removeAllViews()
        val status = activity.label(session.error ?: pending ?: session.githubMessage, 15f).apply {
            tag = "github_status"; isSaveEnabled = false
            accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
        }
        if (authorizing) {
            state.addView(status)
            code?.let {
                state.addView(activity.heading(it).apply { tag = "github_device_code"; isSaveEnabled = false; gravity = Gravity.CENTER })
                state.addView(activity.label("Enter this one-use code at github.com/login/device. Approval is checked automatically. Return here after approval; the code expires automatically.", 14f, true))
                state.addView(activity.button("Open GitHub in system browser", "github_open_browser", true) {
                    session.openGitHubVerification { url ->
                        try { activity.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addCategory(Intent.CATEGORY_BROWSABLE)) }
                        catch (_: Exception) { session.cancelGitHubAuthorization() }
                    }
                })
            }
            state.addView(activity.button("Cancel authorization", "github_cancel") { session.cancelGitHubAuthorization() })
            return
        }
        if (account != null) {
            state.addView(activity.heading(account.login, 20f).apply { tag = "github_account"; isSaveEnabled = false })
            state.addView(activity.label(if (account.expired) "Connection expired. Reconnect to continue." else "Connected account · encrypted with this vault.", 14f, true))
        }
        if (!session.githubConfigured) state.addView(activity.label("The publisher hasn't configured GitHub for this build. Connect is unavailable.", 14f, true).apply { tag = "github_unconfigured" })
        state.addView(disclosure)
        state.addView(activity.button(if (account == null) "Connect GitHub" else "Reconnect GitHub", "github_connect", true) {
            run(STARTING) { session.beginGitHubAuthorization() }
        }.apply {
            isEnabled = session.canManageConnections && session.githubConfigured
            backgroundTintList = ColorStateList(arrayOf(intArrayOf(-android.R.attr.state_enabled), intArrayOf()),
                intArrayOf(ColorUtils.setAlphaComponent(activity.color(R.color.ink), 31), activity.color(R.color.primary)))
        })
        state.addView(status)
        if (account != null) {
            state.addView(activity.button("Check connection", "github_check") {
                run("Checking connection…") { session.checkGitHubConnection() }
            }.apply { isEnabled = session.canManageConnections && !account.expired })
            state.addView(activity.label("Check connection verifies the account only here. It does not send results to inference.", 13f, true))
            state.addView(activity.kitTextButton("Disconnect GitHub…", "github_disconnect") { confirmDisconnect() }
                .apply { isEnabled = session.canManageConnections })
        }
        if (!session.canManageConnections) state.addView(activity.label("Finish replies, Kit reviews, sync and authorization before managing connections. Save any open personalization or entry forms first.", 14f, true))
    }

    private fun confirmDisconnect() {
        if (confirmation?.isShowing == true) return
        confirmation = MaterialAlertDialogBuilder(activity).setTitle("Disconnect GitHub on this device?")
            .setMessage("Save a local removal, then sync manually to share it. Old backups and other devices may still contain working tokens. This does not revoke access at GitHub. To invalidate them, revoke the app in GitHub Settings → Applications → Authorized OAuth Apps (or Authorized GitHub Apps).")
            .setNegativeButton("Keep connection", null)
            .setPositiveButton("Disconnect locally") { _, _ -> run("Disconnecting locally…") { session.disconnectGitHub() } }
            .create().also {
                it.window?.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                it.setOnDismissListener { confirmation = null }
                it.show()
            }
    }

    private companion object { const val STARTING = "Starting authorization…" }
}

/** Dialog's normal dismiss listener is queued. Invalidate authorization at the
 * dismissal itself, before a worker can commit a late token response. */
private class DismissAwareSheet(activity: MainActivity) : BottomSheetDialog(activity) {
    var explicitDismissal: (() -> Unit)? = null
    private fun notifyDismissal() {
        val callback = explicitDismissal; explicitDismissal = null
        callback?.invoke()
    }
    override fun dismiss() { notifyDismissal(); super.dismiss() }
    override fun cancel() { notifyDismissal(); super.cancel() }
}
