package com.galleontrack.app

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.CallLog
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private var pending: MethodChannel.Result? = null
    private val reqCode = 7001

    private fun granted() = ContextCompat.checkSelfPermission(this, Manifest.permission.READ_CALL_LOG) ==
        PackageManager.PERMISSION_GRANTED

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "galleontrack/native")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasPermission" -> result.success(granted())
                    "requestPermission" -> {
                        if (granted()) result.success(true) else {
                            pending = result
                            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.READ_CALL_LOG), reqCode)
                        }
                    }
                    "getCalls" -> {
                        if (!granted()) { result.error("DENIED", "READ_CALL_LOG not granted", null); return@setMethodCallHandler }
                        val since = (call.argument<Number>("since") ?: 0).toLong()
                        Thread {
                            try {
                                val out = ArrayList<Map<String, Any?>>()
                                val cols = arrayOf(CallLog.Calls._ID, CallLog.Calls.NUMBER, CallLog.Calls.CACHED_NAME,
                                    CallLog.Calls.TYPE, CallLog.Calls.DATE, CallLog.Calls.DURATION)
                                // >= since so same-millisecond calls are not missed; Dart de-duplicates.
                                contentResolver.query(CallLog.Calls.CONTENT_URI, cols, "${CallLog.Calls.DATE} >= ?",
                                    arrayOf(since.toString()), "${CallLog.Calls.DATE} ASC")?.use { c ->
                                    while (c.moveToNext()) {
                                        out.add(mapOf(
                                            "id" to c.getLong(0).toString(), "number" to c.getString(1),
                                            "name" to c.getString(2), "type" to c.getInt(3),
                                            "date" to c.getLong(4), "duration" to c.getLong(5)))
                                    }
                                }
                                runOnUiThread { result.success(out) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("READ_FAILED", e.message, null) }
                            }
                        }.start()
                    }
                    "dial" -> {
                        // ACTION_DIAL only opens the dialer; the user presses call.
                        val n = call.argument<String>("number") ?: ""
                        startActivity(Intent(Intent.ACTION_DIAL, Uri.parse("tel:" + Uri.encode(n))))
                        result.success(null)
                    }
                    "shareFile" -> {
                        try {
                            val f = File(call.argument<String>("path")!!)
                            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", f)
                            val i = Intent(Intent.ACTION_SEND).apply {
                                type = call.argument<String>("mime") ?: "*/*"
                                putExtra(Intent.EXTRA_STREAM, uri)
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            }
                            startActivity(Intent.createChooser(i, "Share"))
                            result.success(null)
                        } catch (e: Exception) { result.error("SHARE_FAILED", e.message, null) }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == reqCode) {
            pending?.success(grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED)
            pending = null
        }
    }
}
