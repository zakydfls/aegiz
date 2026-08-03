#!/bin/sh
set -eu

navigation_limit=${AEGIZ_UI_NAVIGATION_LIMIT_MS:-750}
sheet_open_limit=${AEGIZ_UI_SHEET_OPEN_LIMIT_MS:-1200}
sheet_close_limit=${AEGIZ_UI_SHEET_CLOSE_LIMIT_MS:-900}

if ! pgrep -x Aegiz >/dev/null; then
    echo "Aegiz must be running before the UI latency smoke test." >&2
    exit 1
fi

result=$(
    osascript -l JavaScript <<'JXA'
const app = Application('Aegiz')
const systemEvents = Application('System Events')
app.activate()
delay(0.1)

const process = systemEvents.processes.byName('Aegiz')
process.frontmost = true
const window = process.windows[0]
function sidebarOutline() {
    const windowLeft = window.position()[0]
    const contents = window.entireContents()
    for (const element of contents) {
        try {
            if (element.role() === 'AXOutline'
                && element.position()[0] < windowLeft + 300) return element
        } catch (_) {}
    }
    return null
}

function select(row, expectedTitle) {
    const outline = sidebarOutline()
    if (!outline) throw new Error('Sidebar outline was not found')
    const started = Date.now()
    outline.rows[row].selected = true
    while (Date.now() - started < 3000 && window.name() !== expectedTitle) {
        delay(0.002)
    }
    if (window.name() !== expectedTitle) {
        throw new Error(`Navigation to ${expectedTitle} did not complete`)
    }
    return Date.now() - started
}

const navigation = [
    {target: 'Command Center', elapsed_ms: select(1, 'Command Center')},
    {target: 'Tunnels', elapsed_ms: select(3, 'Tunnels')},
    {target: 'Sessions', elapsed_ms: select(2, 'Sessions')},
    {target: 'Command Center', elapsed_ms: select(1, 'Command Center')},
]

let started = Date.now()
systemEvents.keystroke('t', {using: ['command down', 'shift down']})
while (Date.now() - started < 3000 && window.sheets.length === 0) {
    delay(0.002)
}
const sheetOpen = Date.now() - started
if (window.sheets.length !== 1) {
    throw new Error('New Tunnel sheet did not open')
}

started = Date.now()
systemEvents.keyCode(53)
while (Date.now() - started < 3000 && window.sheets.length !== 0) {
    delay(0.002)
}
const sheetClose = Date.now() - started
if (window.sheets.length !== 0) {
    throw new Error('New Tunnel sheet did not close')
}

JSON.stringify({navigation, sheet_open_ms: sheetOpen, sheet_close_ms: sheetClose})
JXA
)

printf '%s\n' "$result" | jq .

if ! printf '%s\n' "$result" | jq -e \
    --argjson navigation "$navigation_limit" \
    --argjson sheet_open "$sheet_open_limit" \
    --argjson sheet_close "$sheet_close_limit" \
    'all(.navigation[]; .elapsed_ms <= $navigation)
        and .sheet_open_ms <= $sheet_open
        and .sheet_close_ms <= $sheet_close' >/dev/null; then
    echo "Aegiz exceeded a UI latency acceptance limit." >&2
    exit 1
fi

echo "Aegiz UI latency smoke test passed."
