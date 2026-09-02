package com.orbitterm.android.feature.terminal

import android.content.Context
import android.content.ClipboardManager
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.text.InputType
import android.util.AttributeSet
import android.util.TypedValue
import android.view.KeyEvent
import android.view.ActionMode
import android.view.GestureDetector
import android.view.Menu
import android.view.MenuItem
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputMethodManager
import com.orbitterm.android.domain.settings.TerminalAppearance
import com.orbitterm.android.security.ClipboardContentKind
import com.orbitterm.android.security.SensitiveClipboard
import com.termux.view.TerminalRenderer
import kotlin.math.floor

class RemoteTerminalCanvasView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
) : View(context, attrs) {
    private var appearance = TerminalAppearance()
    private var renderer = createRenderer(appearance.fontSizeSp)

    private var session: ActiveTerminalSession? = null
    private var boundSessionId: String? = null
    private var onSizeChanged: ((columns: Int, rows: Int) -> Unit)? = null
    private var columns = 0
    private var rows = 0
    private val backgroundPaint = Paint().apply { color = Color.BLACK }
    private val scrollIndicatorPaint = Paint().apply { color = Color.argb(150, 255, 255, 255) }
    private val horizontalContentInset = TypedValue.applyDimension(
        TypedValue.COMPLEX_UNIT_DIP,
        HORIZONTAL_CONTENT_INSET_DP,
        resources.displayMetrics,
    ).toInt()
    private var selectionStart: TerminalCell? = null
    private var selectionEnd: TerminalCell? = null
    private var selectionActionMode: ActionMode? = null
    private var topRow = 0
    private var lastTouchY = 0f
    private var scrollRemainder = 0f
    private var isScrolling = false
    private val touchSlop = ViewConfiguration.get(context).scaledTouchSlop
    private val gestureDetector = GestureDetector(context, object : GestureDetector.SimpleOnGestureListener() {
        override fun onDown(event: MotionEvent): Boolean = true

        override fun onLongPress(event: MotionEvent) {
            performLongClick()
            val cell = cellAt(event.x, event.y)
            selectionStart = cell
            selectionEnd = cell
            showSelectionActions()
            invalidate()
        }
    })

    init {
        isFocusable = true
        isFocusableInTouchMode = true
        contentDescription = "远程终端，已连接。轻触可显示键盘；长按可选择、复制或粘贴。"
        setBackgroundColor(Color.BLACK)
    }

    fun bind(session: ActiveTerminalSession, onSizeChanged: (columns: Int, rows: Int) -> Unit) {
        if (boundSessionId != session.id) {
            boundSessionId = session.id
            topRow = 0
            selectionActionMode?.finish()
        }
        this.session = session
        this.onSizeChanged = onSizeChanged
        applyPalette(session)
        clampTopRow()
        invalidate()
        updateTerminalSize()
    }

    fun scrollToBottom() {
        topRow = 0
        invalidate()
    }

    /** Clears the native editor before Compose reveals another destination and its bottom dock. */
    fun dismissKeyboard() {
        clearFocus()
        val token = windowToken ?: return
        context.getSystemService(InputMethodManager::class.java)
            ?.hideSoftInputFromWindow(token, 0)
    }

    /** Rebuild text metrics only when the persisted font size actually changes. */
    fun setAppearance(appearance: TerminalAppearance) {
        val fontSizeChanged = this.appearance.fontSizeSp != appearance.fontSizeSp
        this.appearance = appearance
        if (fontSizeChanged) {
            renderer = createRenderer(appearance.fontSizeSp)
            columns = 0
            rows = 0
        }
        session?.let(::applyPalette)
        backgroundPaint.color = appearance.theme.backgroundArgb
        invalidate()
        updateTerminalSize()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        // AndroidView is hosted inside Compose. Do not use drawColor here: on some
        // hardware-accelerated hosts it clears the parent render target and hides
        // the Compose chrome above this view. Keep every terminal draw scoped to
        // the native view's own bounds instead.
        val saveCount = canvas.save()
        canvas.clipRect(0, 0, width, height)
        canvas.drawRect(0f, 0f, width.toFloat(), height.toFloat(), backgroundPaint)
        session?.let { activeSession ->
            val selection = selectionRange()
            val contentSaveCount = canvas.save()
            canvas.clipRect(horizontalContentInset, 0, width - horizontalContentInset, height)
            canvas.translate(horizontalContentInset.toFloat(), 0f)
            renderer.render(
                activeSession.engine.emulator,
                canvas,
                topRow,
                selection?.start?.row ?: -1,
                selection?.end?.row ?: -1,
                selection?.start?.column ?: -1,
                selection?.end?.column ?: -1,
            )
            canvas.restoreToCount(contentSaveCount)
            drawScrollIndicator(canvas)
        }
        canvas.restoreToCount(saveCount)
    }

    override fun onSizeChanged(width: Int, height: Int, oldWidth: Int, oldHeight: Int) {
        super.onSizeChanged(width, height, oldWidth, oldHeight)
        updateTerminalSize()
    }

    override fun onCheckIsTextEditor(): Boolean = true

    override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection {
        outAttrs.inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
        outAttrs.imeOptions = EditorInfo.IME_ACTION_NONE
        return object : BaseInputConnection(this, false) {
            override fun commitText(text: CharSequence, newCursorPosition: Int): Boolean {
                sendText(text)
                return true
            }

            override fun deleteSurroundingText(beforeLength: Int, afterLength: Int): Boolean {
                if (beforeLength > 0) sendBytes(byteArrayOf(BACKSPACE))
                return true
            }
        }
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        when (keyCode) {
            KeyEvent.KEYCODE_DPAD_UP -> sendCursorKey('A')
            KeyEvent.KEYCODE_DPAD_DOWN -> sendCursorKey('B')
            KeyEvent.KEYCODE_DPAD_RIGHT -> sendCursorKey('C')
            KeyEvent.KEYCODE_DPAD_LEFT -> sendCursorKey('D')
            else -> terminalHardwareKeyBytes(keyCode, event.unicodeChar, event.isCtrlPressed)
                ?.let(::sendBytes)
                ?: return super.onKeyDown(keyCode, event)
        }
        return true
    }

    override fun performClick(): Boolean {
        super.performClick()
        requestFocus()
        context.getSystemService(InputMethodManager::class.java)?.showSoftInput(this, InputMethodManager.SHOW_IMPLICIT)
        return true
    }

    override fun performLongClick(): Boolean {
        super.performLongClick()
        return true
    }

    override fun onDetachedFromWindow() {
        dismissKeyboard()
        super.onDetachedFromWindow()
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        gestureDetector.onTouchEvent(event)
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                lastTouchY = event.y
                scrollRemainder = 0f
                isScrolling = false
            }
            MotionEvent.ACTION_MOVE -> {
                if (selectionStart != null) {
                    selectionEnd = cellAt(event.x, event.y)
                    invalidate()
                } else {
                    val delta = event.y - lastTouchY
                    lastTouchY = event.y
                    scrollRemainder += delta
                    if (!isScrolling && kotlin.math.abs(scrollRemainder) >= touchSlop) isScrolling = true
                    if (isScrolling) scrollByPixels()
                }
            }
            MotionEvent.ACTION_UP -> {
                if (selectionStart == null && !isScrolling) performClick()
                else {
                    if (selectionStart != null) {
                        selectionEnd = cellAt(event.x, event.y)
                        invalidate()
                    }
                }
                scrollRemainder = 0f
            }
        }
        return true
    }

    private fun showSelectionActions() {
        selectionActionMode?.finish()
        selectionActionMode = startActionMode(object : ActionMode.Callback {
            override fun onCreateActionMode(mode: ActionMode, menu: Menu): Boolean {
                menu.add(0, ACTION_COPY, 0, "复制").setShowAsAction(MenuItem.SHOW_AS_ACTION_ALWAYS)
                menu.add(0, ACTION_PASTE, 1, "粘贴").setShowAsAction(MenuItem.SHOW_AS_ACTION_ALWAYS)
                return true
            }

            override fun onPrepareActionMode(mode: ActionMode, menu: Menu): Boolean = false

            override fun onActionItemClicked(mode: ActionMode, item: MenuItem): Boolean = when (item.itemId) {
                ACTION_COPY -> {
                    copySelectionToClipboard()
                    mode.finish()
                    true
                }
                ACTION_PASTE -> {
                    pasteFromClipboard()
                    mode.finish()
                    true
                }
                else -> false
            }

            override fun onDestroyActionMode(mode: ActionMode) {
                selectionActionMode = null
                selectionStart = null
                selectionEnd = null
                invalidate()
            }
        })
    }

    private fun copySelectionToClipboard() {
        val selection = selectionRange() ?: return
        val text = session?.engine?.emulator?.getSelectedText(
            selection.start.column,
            selection.start.row,
            selection.end.column,
            selection.end.row,
        ).orEmpty()
        if (text.isNotEmpty()) {
            SensitiveClipboard.copy(
                context,
                "OrbitTerm terminal",
                text,
                ClipboardContentKind.TERMINAL_OUTPUT,
            )
        }
    }

    private fun pasteFromClipboard() {
        val clipboard = context.getSystemService(ClipboardManager::class.java) ?: return
        val item = clipboard.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0) ?: return
        val text = item.coerceToText(context)?.toString() ?: return
        if (text.toByteArray(Charsets.UTF_8).size <= MAX_PASTE_BYTES) sendText(text)
    }

    private fun cellAt(x: Float, y: Float): TerminalCell = TerminalCell(
        column = floor((x - horizontalContentInset) / renderer.fontWidth)
            .toInt()
            .coerceIn(0, (columns - 1).coerceAtLeast(0)),
        row = (floor(y / renderer.fontLineSpacing).toInt() + topRow).coerceIn(
            -activeTranscriptRows(),
            (rows - 1).coerceAtLeast(0),
        ),
    )

    private fun selectionRange(): TerminalSelection? {
        val start = selectionStart ?: return null
        val end = selectionEnd ?: return null
        return if (start.row < end.row || start.row == end.row && start.column <= end.column) {
            TerminalSelection(start, end)
        } else TerminalSelection(end, start)
    }

    private fun sendCursorKey(code: Char) {
        val applicationMode = session?.engine?.emulator?.isCursorKeysApplicationMode == true
        sendText(if (applicationMode) "\u001BO$code" else "\u001B[$code")
    }

    private fun sendText(text: CharSequence) = sendBytes(text.toString().toByteArray(Charsets.UTF_8))

    private fun sendBytes(bytes: ByteArray) {
        session?.engine?.sendInput(bytes)
    }

    private fun updateTerminalSize() {
        if (width <= 0 || height <= 0) return
        val contentWidth = (width - horizontalContentInset * 2).coerceAtLeast(1)
        val nextColumns = floor(contentWidth / renderer.fontWidth).toInt().coerceAtLeast(2)
        val nextRows = (height / renderer.fontLineSpacing).coerceAtLeast(2)
        if (nextColumns == columns && nextRows == rows) return
        columns = nextColumns
        rows = nextRows
        onSizeChanged?.invoke(nextColumns, nextRows)
    }

    private fun scrollByPixels() {
        val lineSpacing = renderer.fontLineSpacing.toFloat().coerceAtLeast(1f)
        val lineDelta = (scrollRemainder / lineSpacing).toInt()
        if (lineDelta == 0) return
        scrollRemainder -= lineDelta * lineSpacing
        topRow = (topRow + lineDelta).coerceIn(-activeTranscriptRows(), 0)
        invalidate()
    }

    private fun clampTopRow() {
        topRow = topRow.coerceIn(-activeTranscriptRows(), 0)
    }

    private fun activeTranscriptRows(): Int = session?.engine?.emulator?.screen?.activeTranscriptRows ?: 0

    private fun drawScrollIndicator(canvas: Canvas) {
        val transcriptRows = activeTranscriptRows()
        if (transcriptRows == 0 || height == 0) return
        val visibleFraction = rows.toFloat() / (rows + transcriptRows).toFloat()
        val thumbHeight = (height * visibleFraction).coerceIn(MIN_SCROLL_INDICATOR_HEIGHT, height.toFloat())
        val traveledFraction = (topRow + transcriptRows).toFloat() / transcriptRows.toFloat()
        val top = (height - thumbHeight) * traveledFraction
        canvas.drawRoundRect(
            width - horizontalContentInset - SCROLL_INDICATOR_INSET,
            top,
            width - horizontalContentInset - SCROLL_INDICATOR_INSET + SCROLL_INDICATOR_WIDTH,
            top + thumbHeight,
            SCROLL_INDICATOR_WIDTH,
            SCROLL_INDICATOR_WIDTH,
            scrollIndicatorPaint,
        )
    }

    private fun applyPalette(activeSession: ActiveTerminalSession) {
        val colors = activeSession.engine.emulator.mColors.mCurrentColors
        appearance.theme.ansi16.copyInto(colors, destinationOffset = ANSI_START)
        colors[DEFAULT_FOREGROUND] = appearance.theme.foregroundArgb
        colors[DEFAULT_BACKGROUND] = appearance.theme.backgroundArgb
        colors[CURSOR_COLOR] = appearance.theme.foregroundArgb
        backgroundPaint.color = appearance.theme.backgroundArgb
    }

    private fun createRenderer(fontSizeSp: Int): TerminalRenderer = TerminalRenderer(
        TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_SP,
            fontSizeSp.toFloat(),
            resources.displayMetrics,
        ).toInt(),
        Typeface.MONOSPACE,
    )

    private companion object {
        const val ACTION_COPY = 1
        const val ACTION_PASTE = 2
        const val MAX_PASTE_BYTES = 16 * 1024
        const val ANSI_START = 0
        const val DEFAULT_FOREGROUND = 256
        const val DEFAULT_BACKGROUND = 257
        const val CURSOR_COLOR = 258
        const val SCROLL_INDICATOR_WIDTH = 4f
        const val SCROLL_INDICATOR_INSET = 6f
        const val MIN_SCROLL_INDICATOR_HEIGHT = 24f
        const val HORIZONTAL_CONTENT_INSET_DP = 8f
    }

    private data class TerminalCell(val column: Int, val row: Int)
    private data class TerminalSelection(val start: TerminalCell, val end: TerminalCell)
}

/**
 * Maps Android hardware keys to terminal bytes without relying on IME text
 * composition. Ctrl combinations deliberately use key codes, so Ctrl+C/D/L
 * work on physical keyboards even when their Unicode character is zero.
 */
fun terminalHardwareKeyBytes(keyCode: Int, unicodeChar: Int, isCtrlPressed: Boolean): ByteArray? {
    if (isCtrlPressed && keyCode in KeyEvent.KEYCODE_A..KeyEvent.KEYCODE_Z) {
        return byteArrayOf((keyCode - KeyEvent.KEYCODE_A + 1).toByte())
    }
    return when (keyCode) {
        KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER -> byteArrayOf(CARRIAGE_RETURN)
        KeyEvent.KEYCODE_DEL -> byteArrayOf(BACKSPACE)
        KeyEvent.KEYCODE_FORWARD_DEL -> "\u001B[3~".toByteArray()
        KeyEvent.KEYCODE_TAB -> byteArrayOf(TAB)
        KeyEvent.KEYCODE_ESCAPE -> byteArrayOf(ESCAPE)
        KeyEvent.KEYCODE_PAGE_UP -> "\u001B[5~".toByteArray()
        KeyEvent.KEYCODE_PAGE_DOWN -> "\u001B[6~".toByteArray()
        KeyEvent.KEYCODE_MOVE_HOME -> "\u001B[H".toByteArray()
        KeyEvent.KEYCODE_MOVE_END -> "\u001B[F".toByteArray()
        else -> unicodeChar.takeIf { it != 0 }?.let { String(Character.toChars(it)).toByteArray(Charsets.UTF_8) }
    }
}

private const val ESCAPE: Byte = 0x1B
private const val CARRIAGE_RETURN: Byte = 0x0D
private const val BACKSPACE: Byte = 0x7F
private const val TAB: Byte = 0x09
