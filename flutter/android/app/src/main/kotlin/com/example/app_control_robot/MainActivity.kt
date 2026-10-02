package com.example.app_control_robot

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothSocket
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.io.InputStream
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/**
 * Classic Bluetooth (RFCOMM / SPP) host for the Flutter app.
 *
 * There is no third-party plugin for this, so the socket is opened here and
 * exposed over a MethodChannel. Link events travel the other way on an
 * EventChannel, because the Flutter side has to know the moment the socket drops
 * so it can stop the motors.
 *
 * Pairing is deliberately *not* implemented: only the system Bluetooth settings
 * may pair a device, so `openBluetoothSettings` is exposed instead and the UI
 * sends the user there.
 */
class MainActivity : FlutterActivity() {

    private companion object {
        const val METHOD_CHANNEL = "com.example.app_control_robot/bluetooth"
        const val EVENT_CHANNEL = "com.example.app_control_robot/bluetooth/events"
        const val PERMISSION_REQUEST_CODE = 4242

        /** Standard Bluetooth Serial Port Profile service UUID. */
        val SPP_UUID: UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")

        /** RFCOMM read chunk. Commands are two bytes; this only bounds the copy. */
        const val READ_BUFFER_BYTES = 128
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val session = AtomicInteger(0)

    /**
     * Socket writes are pushed here instead of running inline.
     *
     * A MethodChannel call arrives on the platform thread, but writing to an
     * RFCOMM socket blocks for as long as the radio takes to drain it. A held
     * command is resent every 200 ms, so doing that inline would stall the
     * platform thread several times a second and eventually trip an ANR.
     * Single-threaded on purpose: it keeps a command and its keep-alives in
     * the order they were sent.
     */
    private val writer = Executors.newSingleThreadExecutor()

    private var events: EventChannel.EventSink? = null

    @Volatile
    private var socket: BluetoothSocket? = null
    private var readerThread: HandlerThread? = null

    /** Resumes the method call that asked for a runtime permission. */
    private var pendingPermission: ((Boolean) -> Unit)? = null

    /**
     * The local adapter, or null when Bluetooth is unusable.
     *
     * `Context.BLUETOOTH_SERVICE` is a [BluetoothManager], *not* a
     * [BluetoothAdapter]. Casting it straight to [BluetoothAdapter] always
     * fails, so the `as?` silently yields null and every call reports
     * "this device has no Bluetooth" even on a phone that plainly has one.
     * The adapter comes out of the manager instead.
     *
     * `getAdapter()` itself is permission-guarded, so a refusal surfaces as an
     * exception rather than as null; [withReadyBluetooth] folds both into one
     * answer.
     */
    private val adapter: BluetoothAdapter?
        get() = runCatching {
            (getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter
        }.getOrNull()

    /**
     * Whether this phone has Bluetooth hardware at all. Used to tell a genuine
     * permission problem apart from a device that really cannot do Bluetooth,
     * because both arrive here as a null adapter.
     */
    private val hasBluetoothHardware: Boolean
        get() = packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result -> onMethodCall(call, result) }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                    events = sink
                }

                override fun onCancel(arguments: Any?) {
                    events = null
                }
            })
    }

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "ensureReady" -> withReadyBluetooth(result) { ensureReady(result) }
            "pairedDevices" -> withReadyBluetooth(result) { pairedDevices(result) }
            "openBluetoothSettings" -> openBluetoothSettings(result)
            "connect" -> connect(call, result)
            "disconnect" -> {
                closeSession()
                result.success(null)
            }
            "write" -> write(call, result)
            else -> result.notImplemented()
        }
    }

    // ---- Readiness and permissions ----------------------------------------

    /**
     * Runs [body] once Bluetooth is present, enabled, and permitted.
     *
     * Asking for the runtime permission is asynchronous, so the method call
     * cannot be answered inline: the caller's [result] is parked in
     * [pendingPermission] and the system dialog decides whether [body] ever
     * runs.
     */
    private fun withReadyBluetooth(
        result: MethodChannel.Result,
        body: (BluetoothAdapter) -> Unit
    ) {
        val a = adapter
        if (a == null) {
            result.error(
                "no_adapter",
                if (hasBluetoothHardware) {
                    "Không mở được Bluetooth. Cấp quyền \"Thiết bị gần đó\" cho " +
                        "ứng dụng trong Cài đặt rồi thử lại."
                } else {
                    "Máy này không có Bluetooth."
                },
                null
            )
            return
        }
        if (!hasPermissions()) {
            if (pendingPermission != null) {
                result.error("busy", "Đang chờ bạn cấp quyền Bluetooth.", null)
                return
            }
            pendingPermission = { granted ->
                if (granted) {
                    afterPermission(a, result, body)
                } else {
                    result.error(
                        "permission_denied",
                        "Cần cấp quyền Bluetooth để điều khiển robot.",
                        null
                    )
                }
            }
            ActivityCompat.requestPermissions(
                this,
                requiredPermissions(),
                PERMISSION_REQUEST_CODE
            )
            return
        }
        afterPermission(a, result, body)
    }

    private fun afterPermission(
        a: BluetoothAdapter,
        result: MethodChannel.Result,
        body: (BluetoothAdapter) -> Unit
    ) {
        if (!a.isEnabled) {
            result.error("disabled", "Hãy bật Bluetooth rồi thử lại.", null)
            return
        }
        body(a)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != PERMISSION_REQUEST_CODE) {
            return
        }
        val resume = pendingPermission ?: return
        pendingPermission = null
        resume(hasPermissions())
    }

    /**
     * Android 12 split Bluetooth into runtime permissions. Older releases only
     * need a location grant, and only to read the bond list at all — Bluetooth
     * itself is a normal install-time permission there.
     *
     * On 31+ only `BLUETOOTH_CONNECT` is asked for: reading bonded devices and
     * opening a socket to one is "communicating with already-paired devices",
     * which needs CONNECT alone. `BLUETOOTH_SCAN` is deliberately not requested
     * because this app never scans, and requiring it would let a single refusal
     * wedge the whole app with no way for the user to recover.
     */
    private fun requiredPermissions(): Array<String> = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        arrayOf(android.Manifest.permission.BLUETOOTH_CONNECT)
    } else {
        arrayOf(android.Manifest.permission.ACCESS_FINE_LOCATION)
    }

    private fun hasPermissions(): Boolean = requiredPermissions().all { permission ->
        ContextCompat.checkSelfPermission(this, permission) == PackageManager.PERMISSION_GRANTED
    }

    // ---- Method handlers --------------------------------------------------

    private fun ensureReady(result: MethodChannel.Result) {
        if (adapter?.bondedDevices.isNullOrEmpty()) {
            result.error(
                "no_devices",
                "Chưa có robot nào được ghép nối. Mở Cài đặt Bluetooth và ghép nối ESP32_ROBOT (mã 1234).",
                null
            )
            return
        }
        result.success(null)
    }

    private fun pairedDevices(result: MethodChannel.Result) {
        val bonded = adapter?.bondedDevices ?: emptySet()
        val devices = bonded.map { device ->
            mapOf(
                "address" to device.address,
                // Reading the name needs BLUETOOTH_CONNECT on API 31+, which
                // withReadyBluetooth() has already checked. A device with no
                // name reports null and Dart falls back to the address.
                "name" to (runCatching { device.name }.getOrNull() ?: "")
            )
        }
        result.success(devices)
    }

    private fun openBluetoothSettings(result: MethodChannel.Result) {
        try {
            startActivity(Intent(Settings.ACTION_BLUETOOTH_SETTINGS))
            result.success(null)
        } catch (error: Exception) {
            result.error("settings_failed", error.message, null)
        }
    }

    private fun connect(call: MethodCall, result: MethodChannel.Result) {
        val address = call.argument<String>("address")
        if (address.isNullOrBlank()) {
            result.error("bad_address", "Thiết bị không hợp lệ.", null)
            return
        }
        withReadyBluetooth(result) { a -> openSocket(a, address, result) }
    }

    private fun openSocket(a: BluetoothAdapter, address: String, result: MethodChannel.Result) {
        val device = a.bondedDevices.firstOrNull { it.address == address }
        if (device == null) {
            result.error(
                "not_paired",
                "Robot này không còn trong danh sách đã ghép nối.",
                null
            )
            return
        }

        closeSession()
        val id = session.incrementAndGet()

        // BluetoothSocket.connect() blocks for seconds while it pairs and
        // authenticates, so it must never run on the platform thread.
        Thread {
            var opened: BluetoothSocket? = null
            try {
                // Discovery must be off before connecting or the RFCOMM
                // handshake can time out. It is scan-gated on Android 12+, and
                // this app never holds BLUETOOTH_SCAN, so a refusal here is
                // expected and harmless.
                runCatching { a.cancelDiscovery() }
                opened = a.getRemoteDevice(address).createRfcommSocketToServiceRecord(SPP_UUID)
                opened.connect()

                // A newer connect() may have replaced this one while we were
                // blocked; drop the socket we just opened rather than clobber
                // the live one.
                if (id != session.get()) {
                    runCatching { opened.close() }
                    mainHandler.post { result.success(null) }
                    return@Thread
                }

                socket = opened
                startReader(id, opened.inputStream)
                mainHandler.post {
                    emit(mapOf("type" to "message", "text" to "Đã nối $address"))
                    result.success(null)
                }
            } catch (error: IOException) {
                runCatching { opened?.close() }
                if (id == session.get()) {
                    socket = null
                }
                mainHandler.post {
                    result.error(
                        "connect_failed",
                        "Không nối được với robot: ${error.message ?: "bị từ chối"}",
                        null
                    )
                }
            }
        }.start()
    }

    private fun write(call: MethodCall, result: MethodChannel.Result) {
        val data = call.argument<String>("data")
        if (data == null) {
            result.error("bad_command", "Lệnh rỗng.", null)
            return
        }
        val open = socket
        if (open == null) {
            result.error("not_connected", "Chưa nối robot.", null)
            return
        }

        // Captured before queueing: closeSession() bumps the session, so a write
        // that fails because the user asked to disconnect stays quiet.
        val id = session.get()
        val bytes = data.toByteArray(Charsets.UTF_8)

        // A command is two bytes, but the write still waits on the radio, so it
        // must not sit on the platform thread. See [writer].
        val queued = runCatching {
            writer.execute {
                try {
                    open.outputStream.write(bytes)
                    open.outputStream.flush()
                    mainHandler.post { result.success(null) }
                } catch (error: IOException) {
                    mainHandler.post { result.error("write_failed", error.message, null) }
                    if (id == session.get()) {
                        mainHandler.post { emitLinkLost("Mất kết nối Bluetooth.") }
                    }
                }
            }
        }

        if (queued.isFailure) {
            // The executor is already shut down, which only happens while the
            // activity is going away. Answer anyway: a MethodChannel.Result left
            // unanswered hangs the Dart future forever.
            result.error("write_failed", "Ứng dụng đang đóng lại.", null)
        }
    }

    // ---- Bluetooth plumbing -----------------------------------------------

    private fun startReader(id: Int, stream: InputStream) {
        val thread = HandlerThread("bluetooth-reader").apply { start() }
        readerThread = thread
        // Looper.handler is not public API, so build the Handler explicitly.
        // looper is non-null here because start() above created it.
        Handler(checkNotNull(thread.looper)).post {
            val buffer = ByteArray(READ_BUFFER_BYTES)
            try {
                while (id == session.get() && !thread.isInterrupted) {
                    val count = stream.read(buffer)
                    if (count < 0) {
                        break
                    }
                    if (count > 0) {
                        val text = String(buffer, 0, count)
                        mainHandler.post { emit(mapOf("type" to "message", "text" to text)) }
                    }
                }
                if (id == session.get()) {
                    mainHandler.post { emitLinkLost("Robot đã ngắt kết nối.") }
                }
            } catch (error: IOException) {
                if (id == session.get()) {
                    mainHandler.post { emitLinkLost("Mất kết nối Bluetooth.") }
                }
            }
        }
    }

    /**
     * Drops the current socket and stops its reader.
     *
     * Bumping [session] first means a reader blocked in `read()` wakes up, sees
     * a stale id, and stays quiet instead of reporting a link loss the user
     * asked for.
     */
    private fun closeSession() {
        session.incrementAndGet()
        readerThread?.quitSafely()
        readerThread = null
        runCatching { socket?.close() }
        socket = null
    }

    private fun emitLinkLost(reason: String) {
        closeSession()
        emit(mapOf("type" to "linkLost", "reason" to reason))
    }

    private fun emit(event: Map<String, String>) {
        events?.success(event)
    }

    // ---- Lifecycle --------------------------------------------------------

    override fun onDestroy() {
        pendingPermission = null
        closeSession()
        writer.shutdownNow()
        super.onDestroy()
    }
}
