package fyi.habibi.app

import android.app.Activity
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle

// Aliases must not own MainActivity's task: Android finishes activities launched
// through a disabled alias even when DONT_KILL_APP keeps the process alive.
class IconLauncherActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        startActivity(Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        finish()
    }
}

/** Launcher state is the source of truth; icon choice is not a vault preference. */
internal enum class AppIcon(val id: String, val title: String, val resource: Int) {
    FOREST("forest", "Forest", R.mipmap.ic_launcher),
    MIDNIGHT("midnight", "Midnight", R.mipmap.ic_launcher_midnight),
    BLOSSOM("blossom", "Blossom", R.mipmap.ic_launcher_blossom);

    private fun component(context: Context) = ComponentName(context, "${context.packageName}.Launcher$title")

    fun select(context: Context) {
        val manager = context.packageManager
        if (Build.VERSION.SDK_INT >= 33) {
            manager.setComponentEnabledSettings(entries.map { icon ->
                PackageManager.ComponentEnabledSetting(icon.component(context),
                    if (icon == this) PackageManager.COMPONENT_ENABLED_STATE_ENABLED else PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                    PackageManager.DONT_KILL_APP)
            })
        } else {
            // Enable first so older Android versions never lose the launcher entry.
            manager.setComponentEnabledSetting(component(context), PackageManager.COMPONENT_ENABLED_STATE_ENABLED, PackageManager.DONT_KILL_APP)
            entries.filter { it != this }.forEach {
                manager.setComponentEnabledSetting(it.component(context), PackageManager.COMPONENT_ENABLED_STATE_DISABLED, PackageManager.DONT_KILL_APP)
            }
        }
    }

    companion object {
        fun current(context: Context): AppIcon = entries.firstOrNull { icon ->
            when (context.packageManager.getComponentEnabledSetting(icon.component(context))) {
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED -> true
                PackageManager.COMPONENT_ENABLED_STATE_DEFAULT -> icon == FOREST
                else -> false
            }
        } ?: FOREST
    }
}
