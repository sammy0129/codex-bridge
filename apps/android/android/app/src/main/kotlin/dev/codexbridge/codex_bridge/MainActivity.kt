package dev.codexbridge.codex_bridge

import android.hardware.display.DisplayManager
import android.view.Display
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        applyPreferredRefreshRate()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) applyPreferredRefreshRate()
    }

    private fun applyPreferredRefreshRate() {
        val display = getSystemService(DisplayManager::class.java)
            ?.getDisplay(Display.DEFAULT_DISPLAY)
            ?: return
        val refreshRate = display.supportedModes
            .maxOfOrNull { it.refreshRate }
            ?: return
        if (refreshRate <= 60f) return
        window.attributes = window.attributes.apply {
            preferredRefreshRate = refreshRate
        }
    }
}
