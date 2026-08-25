import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import qs.Commons

// Alt-Tab with a live image of every window.
//
// Three things are fixed and not configurable:
//
//   1. Only the workspace of the window that has focus NOW. That anchor is read
//      fresh from hyprctl before and after the client list. If the workspace
//      changes along the way, nothing is shown. If you are in a scratchpad,
//      you see that scratchpad. Every accepted client was reported on that
//      workspace in the client snapshot. A client can move after that snapshot;
//      Hyprland's events then close the row, but that IPC path is not a hard
//      zero-frame safeguard.
//      Which workspace that is is never decided by Quickshell's cached IPC
//      objects: they lagged behind and still showed a closed scratchpad. The
//      cache is read for two things that cannot decide it -- the Wayland handle
//      behind an address this snapshot already accepted, and the seed for the
//      first Escape anchor.
//
//   2. The background covers everything. Semitransparency lets the window
//      underneath show through, leaving you looking at two things at once.
//
//   3. Alt-Tab itself stays entirely in Hyprland's stock bindings. This plugin
//      observes the resulting focus event and draws the row; it never schedules
//      or cancels either of Omarchy's switching dispatchers.
//
// The shape -- wide center, angled slices beside it -- comes from Omarchy's own
// image picker, so selection feels the same everywhere.
Item {
  id: root

  property bool opened: false
  // "Loaded" and "on screen" are two different things. A quick tap loads the
  // row and never shows it; only holding Alt past revealDelayTicks reveals it.
  // Hyprland decides that, because Hyprland is what knows the physical key.
  property bool revealed: false
  // Ticks of the 50 ms fallback probe that answered "Alt is still down". Only
  // counted while the in-compositor watcher has not acknowledged.
  property int fallbackAltTicks: 0
  property int selectedIndex: 0

  property var windows: []
  property string currentWorkspace: ""
  property var currentWorkspaceId: null
  property int currentMonitorId: -1
  property int readRevision: 0
  property int runningRevision: 0
  property bool readAgain: false
  property bool readRequested: false
  property bool readStartQueued: false
  property var safetyAltDown: null
  property var safetyEscapeDown: null
  property string observedActiveAddress: ""
  property string previouslyActiveAddress: ""
  property string burstAnchorAddress: ""

  readonly property int count: windows.length
  readonly property var selectedWindow: windows[selectedIndex] || null

  // How long Alt must stay down before the row appears, counted in 50 ms ticks
  // of the watcher that is already running. Four ticks is about 200 ms: long
  // enough that switching between two windows never touches the screen, short
  // enough that a deliberate hold does not feel delayed. The number is taste,
  // not a measurement, so it is one place and not four.
  readonly property int revealDelayTicks: 4

  function findIn(values, key, value) {
    for (var i = 0; i < (values ? values.length : 0); i++)
      if (values[i] && values[i][key] === value) return values[i]
    return null
  }

  // The compositor client snapshot can beat Quickshell's toplevel cache. Keep
  // this lookup in a QML binding instead of freezing a possibly-null Wayland
  // handle into the snapshot; it is reevaluated when the cache changes.
  function toplevelForAddress(address) {
    var needle = root.addressKey(address)
    var values = Hyprland.toplevels ? Hyprland.toplevels.values : []
    for (var i = 0; i < values.length; i++)
      if (values[i] && root.addressKey(values[i].address) === needle) return values[i]
    return null
  }

  // `bring_to_top()` rotates Hyprland's window vector after every native
  // cycle. `hyprctl clients` exposes that vector, so blindly publishing every
  // snapshot would leave the active window at the final index on every press:
  // the label would keep saying N / N and the cards would exchange identities
  // around a stationary selection. Center the first accepted snapshot, then
  // keep that circular order for the rest of the physical Alt hold while still
  // replacing every entry with its freshly read metadata.
  function orderedWindowSnapshot(list, focusedAddress) {
    if (root.opened && root.windows.length === list.length) {
      var freshByAddress = ({})
      for (var i = 0; i < list.length; i++)
        freshByAddress[list[i].address] = list[i]

      var stable = []
      for (var j = 0; j < root.windows.length; j++) {
        var fresh = freshByAddress[root.windows[j].address]
        if (!fresh) {
          stable = []
          break
        }
        stable.push(fresh)
      }
      if (stable.length === list.length) return stable
    }

    var at = list.findIndex(function(w) { return w.address === focusedAddress })
    if (at < 0 || list.length < 2) return list
    var before = Math.min(root.sideSlices, Math.floor((list.length - 1) / 2))
    var start = (at - before + list.length) % list.length
    var centered = []
    for (var k = 0; k < list.length; k++)
      centered.push(list[(start + k) % list.length])
    return centered
  }

  // Only the screen from the accepted snapshot counts. If it is no longer
  // found, the overlay stays hidden instead of appearing on a different screen
  // from the one the row came from.
  readonly property var monitor:
    findIn(Hyprland.monitors ? Hyprland.monitors.values : null, "id", currentMonitorId)
  readonly property var targetScreen:
    monitor ? findIn(Quickshell.screens, "name", monitor.name) : null

  // Dimensions follow the screen, so a preview keeps the same aspect ratio as
  // the window inside it and does not look stretched.
  readonly property real screenAspect: monitor && monitor.height > 0
    ? monitor.width / monitor.height : (16 / 9)
  readonly property int expandedWidth: Math.round(Math.min(860, (monitor ? monitor.width : 1920) * 0.44))
  readonly property int expandedHeight: Math.round(expandedWidth / screenAspect)
  readonly property int sliceWidth: 108
  readonly property int sliceHeight: Math.round(expandedHeight * 0.92)
  readonly property int sliceSpacing: -30
  readonly property int skewOffset: 28
  readonly property int labelHeight: 72
  // The number of slices that fit beside the center; also the limit beyond
  // which a delegate is no longer drawn.
  readonly property int sideSlices: 13

  readonly property color scrim: Util.alpha(Color.background, 0.62)

  // Every hyprctl call gets the same emergency brake: a stuck compositor must
  // not leave the overlay stuck as well.
  function hyprEval(lua) {
    return ["timeout", "--kill-after=0.25s", "1s", "hyprctl", "eval", lua]
  }

  // A Process reports its exit before its StdioCollector has delivered the last
  // stdout. Qt.callLater therefore puts the continuation after that collector --
  // otherwise a restart overwrites the stream that still needs processing.
  // A new run may start between exit and callback; it must not receive the
  // handling for the previous run, hence the second check.
  function whenIdle(proc, then) {
    if (proc.running) return
    Qt.callLater(function() { if (!proc.running) then() })
  }

  // ---------------------------------------------------------------- retrieve
  Process {
    id: readProc
    command: ["bash", "-c", [
      "set -o pipefail",
      "hy() { timeout --kill-after=0.25s 1s hyprctl -j \"$@\"; }",
      "before=$(hy activewindow) || exit",
      "clients=$(hy clients) || exit",
      "after=$(hy activewindow) || exit",
      "jq -cn --argjson b \"$before\" --argjson c \"$clients\" --argjson a \"$after\" "
        + "'select(($b.workspace.name // \"\") != \"\" "
        + "and ($b.workspace.id == $a.workspace.id) "
        + "and ($b.workspace.name == $a.workspace.name)) "
        + "| {active:$a,clients:$c}'"
    ].join("; ")]
    onRunningChanged: root.whenIdle(readProc, root.restartPendingRead)
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // A later press owns the result; briefly showing an older answer can
        // leak exactly the content we hide after a workspace switch.
        // Two guards, which do not mean the same thing: the revision rejects a
        // read started before the latest request; readAgain rejects THIS result
        // because a newer request arrived during the read -- even if a newer
        // read with a fresh revision is already running by then, which would
        // make the two revisions match again.
        //
        // readAgain is the second line, not the first. Measured in Qt 6.11.2:
        // Qt.callLater callbacks queued in one pass run back to back as one
        // batch, and no process exit, collector or IPC message lands inside a
        // batch. Under that rule a newer read can never start between an exit
        // and its collector, so the revision comparison alone already rejects
        // everything readAgain rejects -- modelled over 2.4 million event
        // sequences, identical either way. Keep the flag anyway: if callbacks
        // were ever delivered one at a time instead, the same model publishes a
        // stale snapshot on sequences where readAgain still rejects.
        if (root.readAgain || root.runningRevision !== root.readRevision) return

        var payload
        try { payload = JSON.parse(text || "{}") } catch (e) {
          root.close()
          return
        }

        var active = payload.active || {}
        var workspace = active.workspace || {}
        var workspaceName = String(workspace.name || "")
        var workspaceId = workspace.id
        var monitorId = active.monitor
        if (!workspaceName || workspaceId === undefined
            || typeof monitorId !== "number" || monitorId < 0) {
          root.close()
          return
        }

        var focusedAddress = root.clientAddress(active.address)
        var list = []
        var clients = payload.clients || []
        for (var j = 0; j < clients.length; j++) {
          var c = clients[j]
          if (!c || c.mapped === false) continue
          var clientWorkspace = c.workspace || {}
          if (clientWorkspace.id !== workspaceId
              || String(clientWorkspace.name || "") !== workspaceName) continue
          var addr = root.clientAddress(c.address)
          if (!addr) continue
          list.push({
            address: addr,
            title: String(c.title || ""),
            cls: String(c.class || "")
          })
        }
        // Hyprland's native cycle and `hyprctl clients` use the same circular
        // window vector. Keep one stable rotation of that vector during this
        // Alt hold so the displayed position can actually advance.
        list = root.orderedWindowSnapshot(list, focusedAddress)
        root.currentWorkspace = workspaceName
        root.currentWorkspaceId = workspaceId
        root.currentMonitorId = monitorId
        root.windows = list

        // The selection follows Hyprland; it does not drive it. A window that is
        // no longer in the list (-1) selects the first one, as before.
        var at = list.findIndex(function(w) { return w.address === focusedAddress })
        root.selectedIndex = at < 0 ? 0 : at
        root.opened = list.length > 0
        if (root.opened) safetyTimer.restart()
      }
    }
  }

  // The only place where a read starts.
  function startRead() {
    if (!readRequested) return
    readRequested = false
    runningRevision = readRevision
    readProc.running = true
  }

  // Reusing a Process in the interval between `running == false` and its
  // collector's onStreamFinished would make the old stdout look as if it
  // belonged to the new revision. Starting from inside a Qt.callLater gives
  // that collector its final turn first; a press served straight from the IPC
  // message would start the Process inside that very gap.
  // readStartQueued keeps at most one start pending. It cannot go stale: by the
  // batching measured at the collector guard above, every queued start runs in
  // the same batch it was queued for, so the flag is always cleared again
  // before anything else can happen.
  function scheduleRead() {
    if (readStartQueued) return
    readStartQueued = true
    Qt.callLater(function() {
      root.readStartQueued = false
      if (!readProc.running) root.startRead()
    })
  }

  // A newer notification may arrive while the previous snapshot is running.
  // Its revision already exists, so restart without incrementing it again.
  function restartPendingRead() {
    if (!readAgain && !readRequested) return
    readAgain = false
    startRead()
  }

  function requestWindows() {
    readRevision++
    readRequested = true
    if (readProc.running) readAgain = true
    else scheduleRead()
  }

  // The omarchy-shell contract: summon calls open(), hide calls close(), and
  // `opened` says whether it is open. Internally, close() is also the only
  // teardown -- everything that invalidates the row exits here. Alt-Tab does
  // not travel this way: the key bindings notify the IpcHandler below, so
  // open() is only reached by an explicit `omarchy-shell shell summon`.
  //
  // Every press requests the compositor truth again. A newer press arriving
  // during a read is not coalesced: the intermediate result is discarded and
  // the newest request reads again.
  function open(payloadJson) {
    requestWindows()
    safetyTimer.restart()
  }

  function close(preserveRestore) {
    var invalidatedToken = burstToken
    // Releasing the model first also stops an active screencopy before a gone
    // or moved window can still be used as its source.
    opened = false
    revealed = false
    fallbackAltTicks = 0
    windows = []
    currentWorkspace = ""
    currentWorkspaceId = null
    currentMonitorId = -1
    selectedIndex = 0
    burstToken = ""
    burstOriginToken = ""
    burstAnchorAddress = ""
    pendingWatchToken = ""
    watchRetryUsed = false
    watchNeedsFallback = false
    readAgain = false
    readRequested = false
    readRevision++
    if (readProc.running) readProc.running = false
    if (watchProc.running) watchProc.running = false
    safetyTimer.stop()
    if (altProbe.running) altProbe.running = false
    // An invalidated row must not leave a restore point on the compositor side
    // either. On Escape, the timer already moved that point to cancel_*; only
    // that one controlled restore may still use it.
    if (!preserveRestore)
      clearBurstRestoreState(invalidatedToken)
  }

  function clearBurstRestoreState(token) {
    if (!isBurstToken(token)) return
    Quickshell.execDetached(hyprEval(
      "(function() local s = _G.__m4rone_altswitch;" +
      " if type(s) == 'table' and s.owner == '" + root.watchOwner + "'" +
      "    and (s.token == '" + token + "' or s.cancel_token == '" + token + "') then" +
      root.luaStopTimer("s") +
      "   s.stopped_token = '" + token + "';" +
      root.luaClearBurst("s") +
      root.luaClearCancel("s") +
      " end; return true end)()"))
  }

  // parse(n) splits into at most n fields, so the count has to match the event:
  // activewindowv2 and closewindow send 1 (the address), movewindow 2
  // (+ workspace name), and movewindowv2 3 (+ workspace id). Too low a count
  // returns the address glued to the rest of the payload; addressKey() then
  // rejects it. Any other event has no address for us. Past the switch, event
  // and event.name are both known to be there.
  function eventAddress(event) {
    var fieldCount = 0
    switch (String(event && event.name ? event.name : "")) {
    case "activewindowv2": fieldCount = 1; break
    case "closewindow": fieldCount = 1; break
    case "movewindow": fieldCount = 2; break
    case "movewindowv2": fieldCount = 3; break
    default: return ""
    }
    // parse() throws on a payload that does not have the expected shape; the raw
    // data is then the fallback, and its first field is the address as well.
    try { if (event.parse) return String(event.parse(fieldCount)[0] || "") } catch (e) { }
    return String(event.data || "").split(",")[0]
  }

  // The key is bare hex; `hyprctl clients` writes it with a 0x prefix,
  // Quickshell's toplevels without one.
  function addressKey(value) {
    var hex = String(value || "").match(/^(?:0x)?([0-9A-Fa-f]+)$/)
    return hex ? hex[1].toLowerCase() : ""
  }

  // `hyprctl clients` makes this field directly from a CWindow pointer. Only
  // that form may ever reach a Lua focus command; titles and classes may not.
  function clientAddress(value) {
    var key = String(value || "").match(/^0x[0-9A-Fa-f]+$/) ? addressKey(value) : ""
    return key ? "0x" + key : ""
  }

  // IPC events and Quickshell's cache use bare hexadecimal addresses, while
  // hyprctl JSON uses 0x. Normalize the observer input before it can become an
  // Escape target; clientAddress() remains strict for compositor JSON.
  function observedAddress(value) {
    var key = root.addressKey(value)
    return key ? "0x" + key : ""
  }

  // activewindowv2 arrives after Hyprland has already moved focus, so the
  // event alone cannot say where the sequence started. Holding both sides of
  // the transition does: the address that was active just before it is the
  // candidate anchor for Escape. Only a real change shifts, so a repeated
  // event for the same window cannot push that anchor off the end.
  // An empty address never shifts either. This compositor unfocuses before it
  // focuses, so every focus change arrives as two events -- first an empty
  // one, then the real one. Counting the empty one as a state would make
  // every transition start from "nothing" and leave the previous side blank,
  // which is exactly the field the Escape anchor is built from. A stale
  // address left behind by a genuine focus loss is safe here: every path that
  // uses it re-checks identity, mapped and workspace before moving focus.
  function rememberActiveWindow(value) {
    var address = root.observedAddress(value)
    if (!address || address === root.observedActiveAddress) return
    root.previouslyActiveAddress = root.observedActiveAddress
    root.observedActiveAddress = address
  }

  function hasWindowAddress(address) {
    var needle = addressKey(address)
    if (!needle) return false
    return windows.some(function(w) { return root.addressKey(w.address) === needle })
  }

  // --------------------------------------------------------------- controls
  // Everything a press must do lives here, so the plugin remains one directory
  // and `omarchy plugin add` is enough. This only works because the manifest
  // sets `keepLoaded`: without it, the shell reloads an overlay for every call
  // and this IpcHandler does not exist.
  property string burstToken: ""
  property string burstOriginToken: ""
  property int burstSequence: 0
  readonly property double watchEpoch: Date.now()
  readonly property string watchOwner: String(Quickshell.processId) + "-"
    + String(watchEpoch) + "-" + String(Math.floor(Math.random() * 1000000000))
  property string pendingWatchToken: ""
  property string runningWatchOriginToken: ""
  property bool watchArmSucceeded: false
  property bool watchRetryUsed: false
  property bool watchNeedsFallback: false
  property bool watchStartQueued: false
  Component.onCompleted: {
    // Seed the left side of the first focus transition. This reads
    // Quickshell's cached object, which may lag; that is acceptable here and
    // nowhere else, because the seed can only ever become an Escape anchor
    // candidate and never enters the window list of point 1 above. A stale
    // value simply fails the accepted-list, workspace and stable_id checks
    // that every anchor has to pass before it is focused.
    if (Hyprland.activeToplevel)
      root.observedActiveAddress = root.observedAddress(Hyprland.activeToplevel.address)
    cleanupAltWatch(false)
  }
  Component.onDestruction: cleanupAltWatch(true)

  // Every token that reaches Lua or a command line must have this form: the
  // three numbers of watchOwner (process id, epoch, random) plus a sequence
  // number, nothing else. Four numbers in total, which is the {3} above.
  function isBurstToken(value) {
    return /^\d+(?:-\d+){3}$/.test(String(value))
  }

  // A message from the compositor timer names the sequence it belongs to, and
  // only the sequence that is still running may act on it. After close(),
  // burstToken is "", so a message carrying no token must never match -- that is
  // what the first half rejects. Both IPC handlers below need this exact test,
  // one of them negated, so it is written once instead of twice.
  function ownsBurst(token) {
    return !!token && token === root.burstToken
  }

  IpcHandler {
    target: "m4rone.altswitch"

    // Two names for one body, and they must stay that way. Direction is
    // Hyprland's business: the stock binding has already cycled forward or
    // backward before either of these runs, so the plugin only re-reads the
    // result. They stay separate because they are the public IPC names the two
    // key bindings in README.md call.
    function next(): void { root.notifyNativeCycle() }
    function prev(): void { root.notifyNativeCycle() }

    // Called by the Hyprland timer once Alt has been held past the threshold.
    // The token is the burst token, not the per-Tab one, because the whole
    // point is that this covers one physical Alt hold across every Tab in it.
    // A token from a finished burst matches nothing: close() clears the field.
    function reveal(token: string): void {
      if (!!token && token === root.burstOriginToken) root.revealed = true
    }

    // Called by the Hyprland timer as soon as Alt is actually released. A late
    // message from a previous sequence must not remove the list for a new one.
    function release(token: string): void {
      if (root.ownsBurst(token)) root.close()
    }

    // Escape while holding. Same ownership test: a late message from a previous
    // sequence must not cancel a new one.
    function cancel(token: string): void {
      if (!root.ownsBurst(token)) return
      var allowedAddresses = root.acceptedWindowAddresses()
      // Escape can arrive before the first read lands, and then there is no row
      // to check the target against. Refusing there would strand the user on the
      // window they just switched to, which is the one thing Escape must never
      // do. The anchor is a safe substitute: the compositor froze it together
      // with its workspace, and the restore command re-checks that identity and
      // that workspace before it moves focus.
      // Both candidates go in, for the same reason the arm sends both: which
      // one the compositor froze depends on whether the previous sequence had
      // already ended there. Listing both cannot widen where focus may land --
      // the restore still re-checks identity and workspace before moving it.
      if (allowedAddresses.length === 0) {
        var candidates = [root.clientAddress(root.burstAnchorAddress),
                          root.clientAddress(root.previouslyActiveAddress)]
        allowedAddresses = candidates.filter(function(a) { return a !== "" })
      }
      root.close(true)
      // Native switching has already completed before the notification action.
      // This is the only sequence-driven focus command the plugin still owns.
      Quickshell.execDetached(root.restoreBurstCommand(token, allowedAddresses))
    }

    // Escape arriving as a real key instead of as a poll result. Optional: it
    // exists only if the user bound ALT + ESCAPE, and everything still works
    // without it. Binding it buys two things the poll cannot. Hyprland consumes
    // the key, so it no longer reaches the window underneath; and it fires on
    // the press itself, so an Escape shorter than one 50 ms tick cannot be
    // missed. Pressed outside a sequence this does nothing at all.
    function cancelKey(): void {
      if (!root.isBurstToken(root.burstToken)) return
      var command = root.cancelKeyCommand(root.burstToken)
      root.close(true)
      Quickshell.execDetached(command)
    }
  }

  // The keyboard route cannot lean on the timer's Escape freeze -- that branch
  // never ran. It reads the burst start that was frozen when the sequence
  // began, and applies the same two tests the frozen route applies before it
  // moves anything: the target is still the very same window, and it and the
  // window holding focus are both still on the workspace the sequence started
  // on. Stopping the timer here is what keeps the following Alt release from
  // being read as a choice.
  function cancelKeyCommand(token) {
    if (!isBurstToken(token)) return ["true"]
    return hyprEval(
      "(function() local s = _G.__m4rone_altswitch;" +
      " if type(s) ~= 'table' or s.owner ~= '" + root.watchOwner + "'" +
      "    or s.token ~= '" + token + "' then return false end;" +
      // Two Escape routes exist and either can arrive first, because the key is
      // also physically down while the poll runs. Whichever wins moves the
      // restore point from start_* to cancel_* and clears the original, so
      // reading only one of the two makes the loser find nothing and do
      // nothing -- and the row is already closed by then, so the poll's own
      // message is refused as well. Reading both is what makes them cooperate.
      " local address, stable, wid, wname;" +
      " if s.cancel_token == '" + token + "' and type(s.cancel_address) == 'string'" +
      "    and type(s.cancel_stable_id) == 'number' then" +
      "   address = s.cancel_address; stable = s.cancel_stable_id;" +
      "   wid = s.cancel_workspace_id; wname = s.cancel_workspace_name" +
      " elseif type(s.start_address) == 'string' and type(s.start_stable_id) == 'number' then" +
      "   address = s.start_address; stable = s.start_stable_id;" +
      "   wid = s.start_workspace_id; wname = s.start_workspace_name" +
      " else return false end;" +
      " s.stopped_token = '" + token + "';" +
      root.luaStopTimer("s") +
      root.luaClearCancel("s") +
      root.luaClearBurst("s") +
      " local current = hl.get_active_window();" +
      " local target = hl.get_window('address:' .. address);" +
      " if not current or not current.workspace or not target or not target.mapped" +
      "    or not target.workspace or target.stable_id ~= stable" +
      "    or current.workspace.id ~= wid or current.workspace.name ~= wname" +
      "    or target.workspace.id ~= wid or target.workspace.name ~= wname then return false end;" +
      " hl.dispatch(hl.dsp.focus({ window = 'address:' .. address }));" +
      " return true end)()")
  }

  function notifyNativeCycle() {
    var newBurst = !root.burstToken
    root.burstSequence = (root.burstSequence + 1) % 1000000000
    root.burstToken = root.watchOwner + "-" + root.burstSequence
    if (newBurst) {
      root.burstOriginToken = root.burstToken
      // The stock cycle ran first, so the raw activewindowv2 transition already
      // contains the window from which this physical Alt sequence started.
      root.burstAnchorAddress = root.previouslyActiveAddress
      root.watchRetryUsed = false
      // close() already clears both, and a new burst can only follow a close.
      // Stated again here so the burst start owns its own preconditions.
      root.revealed = false
      root.fallbackAltTicks = 0
    }
    root.requestWindows()
    // Cover the interval before the in-compositor watcher acknowledges that it
    // is armed. If both arm attempts fail, this remains the release watcher.
    root.watchNeedsFallback = true
    safetyTimer.restart()
    root.pendingWatchToken = root.burstToken
    startPendingAltWatch()
  }

  // --------------------------------------------------------- Lua fragments
  // The same idea appeared in four chunks, spelled slightly differently each
  // time. Each idea now appears once; `v` is the state table's name at that
  // point (`s` in the chunks themselves, `c` inside the timer closure).

  // A config reload clears C++ timers but leaves this Lua global behind.
  // pcall distinguishes such expired userdata from a live timer.
  function luaStopTimer(v) {
    return " if " + v + ".timer ~= nil then pcall(function() " + v + ".timer:set_enabled(false) end) end;"
  }

  function luaClearBurst(v) {
    return " " + v + ".burst = nil; " + v + ".start_address = nil; " + v + ".start_stable_id = nil;"
         + " " + v + ".start_workspace_id = nil; " + v + ".start_workspace_name = nil;"
         + " " + v + ".ticks = nil; " + v + ".revealed = nil;"
  }

  function luaClearCancel(v) {
    return " " + v + ".cancel_token = nil; " + v + ".cancel_address = nil; " + v + ".cancel_stable_id = nil;"
         + " " + v + ".cancel_workspace_id = nil; " + v + ".cancel_workspace_name = nil;"
  }

  // Adopt the state, or start a fresh one if it belongs to someone else. A
  // process from before a hot reload must never replace the newer owner and
  // arm an old watcher -- hence the epoch.
  readonly property string luaAdoptState:
    " local s = _G.__m4rone_altswitch;" +
    " if type(s) ~= 'table' then s = {} end;" +
    " if s.owner ~= '" + watchOwner + "' then" +
    "   if type(s.epoch) == 'number' and s.epoch >= " + watchEpoch + " then return false end;" +
    luaStopTimer("s") +
    "   s = {}; s.owner = '" + watchOwner + "'; s.epoch = " + watchEpoch +
    " end;" +
    " _G.__m4rone_altswitch = s;"

  // Deliberately no luaAdoptState: a restore must reject foreign, stale, or
  // already-cleared state rather than adopting it.
  function restoreBurstCommand(token, allowedAddresses) {
    if (!isBurstToken(token)) return ["true"]
    // Only addresses from the accepted row may be targets; remove duplicates.
    var seen = ({})
    var entries = []
    var source = allowedAddresses || []
    for (var i = 0; i < source.length; i++) {
      var candidate = root.clientAddress(source[i])
      if (!candidate || seen[candidate]) continue
      seen[candidate] = true
      entries.push("['" + candidate + "']=true")
    }
    return hyprEval(
      "(function()" +
      " local s = _G.__m4rone_altswitch;" +
      " if type(s) ~= 'table' or s.owner ~= '" + root.watchOwner + "' then return false end;" +
      // The Escape freeze in the timer is the only writer of cancel_*, so this
      // one test establishes both the sequence and the types. The four locals
      // below copy those exact values, and nothing between here and their use
      // can change them -- the clears further down hit the table, not the
      // locals. A second type test on them would therefore always pass.
      " if s.cancel_token ~= '" + token + "'" +
      "    or type(s.cancel_address) ~= 'string'" +
      "    or type(s.cancel_stable_id) ~= 'number' then return false end;" +
      " local address = s.cancel_address; local stable = s.cancel_stable_id;" +
      " local wid = s.cancel_workspace_id; local wname = s.cancel_workspace_name;" +
      " local allowed = {" + entries.join(",") + "};" +
      // Clear first: a new window must never inherit a reused pointer.
      root.luaClearCancel("s") +
      root.luaClearBurst("s") +
      " if not allowed[string.lower(address)] then return false end;" +
      " local current = hl.get_active_window();" +
      " local target = hl.get_window('address:' .. address);" +
      // Both the current and target windows must still be on the original
      // workspace. This way Escape can never reveal another workspace.
      " if not current or not current.workspace or not target or not target.mapped" +
      "    or not target.workspace or target.stable_id ~= stable" +
      "    or current.workspace.id ~= wid or current.workspace.name ~= wname" +
      "    or target.workspace.id ~= wid or target.workspace.name ~= wname then return false end;" +
      " hl.dispatch(hl.dsp.focus({ window = 'address:' .. address }));" +
      " return true end)()")
  }

  // There is no "Alt released" event because the overlay sees no keys (see
  // WlrLayershell.keyboardFocus below). One repeating timer inside the
  // compositor checks it; this costs no process per measurement, whereas a
  // shell loop started twenty per second. Each next press restarts that timer.
  Process {
    id: watchProc
    stdout: StdioCollector {
      waitForEnd: true
      // Only the protocol acknowledgement proves the Lua arm completed; an
      // eval error or outer timeout must stay false so the burst gets its retry.
      onStreamFinished: root.watchArmSucceeded = String(text || "").trim() === "ok"
    }
    onRunningChanged: root.whenIdle(watchProc, root.finishPendingAltWatch)
  }

  function finishPendingAltWatch() {
    var originToken = root.runningWatchOriginToken
    root.runningWatchOriginToken = ""

    // Both outcomes below ask the same two things first, so the pair is tested
    // once: this exit belongs to the burst that is still running, and no newer
    // press has already queued an arm of its own. A queued token supplies that
    // next arm itself, so neither the retry nor switching the fallback off is
    // this exit's business. What is left is one question with two answers.
    if (root.burstOriginToken === originToken
        && !isBurstToken(root.pendingWatchToken)) {
      if (root.watchArmSucceeded) {
        // Only the newest successful arm may turn off the fast external
        // fallback; until one succeeds, that probe is the release watcher.
        root.watchNeedsFallback = false
        if (root.opened) safetyTimer.restart()
      } else if (!root.watchRetryUsed && isBurstToken(root.burstToken)) {
        // One retry for the physical burst repairs a transient IPC failure
        // without looping while the compositor is unreachable.
        root.watchRetryUsed = true
        root.pendingWatchToken = root.burstToken
      }
    }
    root.startPendingAltWatch()
  }

  function startPendingAltWatch() {
    if (watchProc.running || watchStartQueued
        || !isBurstToken(root.pendingWatchToken)) return
    watchStartQueued = true
    // watchProc has the same exit/collector ordering as readProc. Do not let a
    // newer press replace its command or stream in that gap; the old
    // acknowledgement must be consumed first.
    Qt.callLater(function() {
      root.watchStartQueued = false
      root.beginPendingAltWatch()
    })
  }

  function beginPendingAltWatch() {
    if (watchProc.running || !isBurstToken(root.pendingWatchToken)) return
    var token = root.pendingWatchToken
    // Both of these are interpolated into evaluated Lua below, so both pass a
    // gate first -- the anchor through clientAddress(), the origin through the
    // token form. burstOriginToken only ever holds "" or a token this file
    // built itself, so the gate changes nothing today; it is here so the rule
    // "nothing reaches Lua ungated" can be checked at the interpolation site
    // instead of re-derived from every assignment that feeds it.
    var originToken = isBurstToken(root.burstOriginToken) ? root.burstOriginToken : ""
    var anchor = root.clientAddress(root.burstAnchorAddress)
    // Two candidates, because two different mistakes are possible and only the
    // compositor knows which one applies. `anchor` is frozen at burst start and
    // stays right when this arm runs late inside a hold that has already moved
    // on. `freshAnchor` is the newest transition and stays right when the
    // previous hold ended but its release message has not landed yet -- then
    // this press looks like a continuation here while it is a new sequence.
    // Lua picks, using the one fact it has and this side does not: whether its
    // own timer already stopped for that release.
    var freshAnchor = root.clientAddress(root.previouslyActiveAddress)
    root.pendingWatchToken = ""
    root.runningWatchOriginToken = originToken
    root.watchArmSucceeded = false
    watchProc.command = hyprEval(
      "(function()" + root.luaAdoptState +
      // Token publication is observational only: it guards late shell messages
      // and never participates in Hyprland's native focus dispatch.
      " if type(s.cancel_token) == 'string' and s.cancel_token ~= '" + token + "' then" +
      root.luaClearCancel("s") +
      " end;" +
      // A stopped token from some earlier sequence means that sequence really
      // ended here, whatever the shell still believes. Read before the line
      // below clears it, because that line destroys the evidence.
      " local ended = type(s.stopped_token) == 'string' and s.stopped_token ~= '" + token + "';" +
      " if s.stopped_token ~= '" + token + "' then s.stopped_token = nil end;" +
      " s.token = '" + token + "';" +
      // A new physical sequence freezes the previously focused raw-event
      // address together with Hyprland's stable identity and workspace. The
      // later accepted-list check is separate and mandatory.
      " if s.burst ~= '" + originToken + "' then" +
      root.luaClearBurst("s") +
      "   s.burst = '" + originToken + "';" +
      "   local current = hl.get_active_window();" +
      "   local addr = ended and '" + freshAnchor + "' or '" + anchor + "';" +
      "   local w = addr ~= '' and hl.get_window('address:' .. addr) or nil;" +
      "   if current and current.workspace and w and w.mapped and w.workspace" +
      "      and current.workspace.id == w.workspace.id" +
      "      and current.workspace.name == w.workspace.name" +
      "      and type(w.address) == 'string' and type(w.stable_id) == 'number' then" +
      "     s.start_address = w.address; s.start_stable_id = w.stable_id;" +
      "     s.start_workspace_id = w.workspace.id; s.start_workspace_name = w.workspace.name" +
      "   end" +
      " end;" +
      // Same pcall trick as luaStopTimer, but here the result answers
      // "can I reuse this timer?".
      " local reusable = false;" +
      " if s.timer ~= nil then reusable = pcall(function() s.timer:set_enabled(false) end) end;" +
      " if not reusable then" +
      "   s.timer = hl.timer(function()" +
      "     local c = _G.__m4rone_altswitch; if not c or not c.timer then return end;" +
      // Escape first: anyone cancelling does not want the following release to
      // count as a selection. is_key_down reads the physical key, so Escape also
      // reaches the window underneath; that is the price of not grabbing keys.
      "     if hl.is_key_down('Escape') then" +
      // Freezing the restore point here ends the physical sequence immediately.
      // The next Tab then cannot wait for the shell IPC still in transit.
      "       local t = c.token; c.cancel_token = t;" +
      "       c.cancel_address = c.start_address; c.cancel_stable_id = c.start_stable_id;" +
      "       c.cancel_workspace_id = c.start_workspace_id;" +
      "       c.cancel_workspace_name = c.start_workspace_name;" +
      root.luaClearBurst("c") +
      "       c.stopped_token = t; c.timer:set_enabled(false);" +
      "       hl.exec_cmd('omarchy-shell -q m4rone.altswitch cancel ' .. t);" +
      "       return" +
      "     end;" +
      // Alt still down. This is where a hold is told apart from a tap: count
      // ticks against the same clock that watches the key, and send the one
      // reveal message per burst. The burst token is used, not the per-Tab
      // token, so a Tab arriving between the send and its delivery cannot
      // orphan the message.
      "     if hl.is_key_down('Alt_L') or hl.is_key_down('Alt_R') then" +
      "       if not c.revealed then" +
      "         c.ticks = (c.ticks or 0) + 1;" +
      "         if c.ticks >= " + root.revealDelayTicks +
      "            and type(c.burst) == 'string' and c.burst ~= '' then" +
      "           c.revealed = true;" +
      "           hl.exec_cmd('omarchy-shell -q m4rone.altswitch reveal ' .. c.burst)" +
      "         end" +
      "       end;" +
      "       return" +
      "     end;" +
      "     local t = c.token; c.stopped_token = t; c.timer:set_enabled(false);" +
      root.luaClearBurst("c") +
      root.luaClearCancel("c") +
      "     hl.exec_cmd('omarchy-shell -q m4rone.altswitch release ' .. t)" +
      "   end, { timeout = 50, type = 'repeat' });" +
      // A timer that already stopped this token must not be re-enabled by a late
      // watcher process from that same Tab.
      "   if s.stopped_token == s.token then s.timer:set_enabled(false) end" +
      " elseif s.stopped_token ~= s.token then s.timer:set_enabled(true) end;" +
      " return true end)()")
    watchProc.running = true
  }

  // On load, remove a timer from a crashed or old shell. On normal unload, only
  // clear our own timer, so a late destructor process cannot disable a new
  // instance.
  function cleanupAltWatch(ownOnly) {
    var guard = ownOnly
      ? "s.owner == '" + root.watchOwner + "'"
      : "s.owner ~= '" + root.watchOwner + "' and (type(s.epoch) ~= 'number' or s.epoch < "
        + root.watchEpoch + ")"
    Quickshell.execDetached(hyprEval(
      "(function() local s = _G.__m4rone_altswitch;" +
      " if type(s) == 'table' and " + guard + " then" +
      root.luaStopTimer("s") +
      "   _G.__m4rone_altswitch = nil" +
      " end; return true end)()"))
  }

  // The normal watcher lives as a cheap timer in Hyprland. An external probe
  // covers its arm interval and any arm failure at the same 50 ms cadence. Once
  // the watcher acknowledges, this becomes only a slow emergency check. Holding
  // Alt is never treated as a timeout.
  Timer {
    id: safetyTimer
    interval: root.watchNeedsFallback ? 50 : 5000
    onTriggered: {
      if (!root.opened || altProbe.running) return
      root.safetyAltDown = null
      root.safetyEscapeDown = null
      altProbe.running = true
    }
  }

  Process {
    id: altProbe
    // Escape is asked for in the same round trip as Alt. Without it, Escape
    // does nothing at all while the watcher is being armed, and nothing ever
    // if arming fails twice -- the row would then only close on release.
    command: root.hyprEval(
      "error('alt=' .. tostring(hl.is_key_down(\"Alt_L\") or hl.is_key_down(\"Alt_R\"))" +
      " .. ',esc=' .. tostring(hl.is_key_down(\"Escape\")))")
    // The opened check is deliberately at both exit and handling: a probe that
    // arrives after closing must do nothing more.
    onRunningChanged: { if (root.opened) root.whenIdle(altProbe, root.afterAltProbe) }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // Anything but the exact pair leaves both answers null; the reason that
        // matters is at afterAltProbe below. Both must parse or neither counts,
        // so a truncated line cannot be read as "Alt is up".
        var answer = String(text || "").trim()
                       .match(/:\s*alt=(true|false),esc=(true|false)\s*$/)
        if (!answer) return
        root.safetyAltDown = answer[1] === "true"
        root.safetyEscapeDown = answer[2] === "true"
      }
    }
  }

  // Only a hard "no" closes. If no answer arrived (hyprctl timeout),
  // safetyAltDown is null and we wait another round.
  function afterAltProbe() {
    if (!root.opened) return
    // Escape first, exactly as the in-compositor timer orders it: someone who
    // cancels does not want the release that follows to count as a choice.
    // Only while the watcher is not the authority, so an acknowledged watcher
    // keeps sole ownership of cancelling.
    if (root.safetyEscapeDown === true && root.watchNeedsFallback) {
      root.cancelFromFallback()
      return
    }
    if (root.safetyAltDown === false) { root.close(); return }
    // The emergency path must carry the same threshold, or a burst whose
    // watcher failed to arm would flash after all. Only probes from the 50 ms
    // cadence count; the 5 s check that follows an acknowledgement does not.
    if (root.safetyAltDown === true && root.watchNeedsFallback && !root.revealed) {
      root.fallbackAltTicks++
      if (root.fallbackAltTicks >= root.revealDelayTicks) root.revealed = true
    }
    safetyTimer.restart()
  }

  // Escape seen by the emergency probe. The in-compositor watcher never armed,
  // so there is no frozen restore point to lean on and the normal cancel path
  // would refuse. The anchor is read before close() clears it.
  function cancelFromFallback() {
    var anchor = root.clientAddress(root.burstAnchorAddress)
    root.close(true)
    if (anchor) Quickshell.execDetached(root.fallbackRestoreCommand(anchor))
  }

  // The same two guarantees the frozen path gives, established at execution
  // time instead of at Escape time: the target must still be a mapped window,
  // and it must share the workspace of whatever holds focus right now. That
  // second test is what keeps Escape from ever pulling another desktop into
  // view. The stable-id check cannot be made here -- nothing recorded one --
  // so this path trades that for working at all, and the workspace test still
  // bounds where focus can land.
  function fallbackRestoreCommand(address) {
    address = root.clientAddress(address)
    if (!address) return ["true"]
    return hyprEval(
      "(function() local current = hl.get_active_window();" +
      " local target = hl.get_window('address:" + address + "');" +
      " if not current or not current.workspace or not target or not target.mapped" +
      "    or not target.workspace" +
      "    or current.workspace.id ~= target.workspace.id" +
      "    or current.workspace.name ~= target.workspace.name then return false end;" +
      " hl.dispatch(hl.dsp.focus({ window = 'address:" + address + "' }));" +
      " return true end)()")
  }

  function acceptedWindowAddresses() {
    if (!root.opened || typeof root.currentWorkspaceId !== "number") return []
    return root.windows.map(function(w) { return root.clientAddress(w.address) })
                       .filter(function(address) { return address !== "" })
  }

  // Focus cannot follow the selection here: without a keyboard grab there is
  // no key to react to, and with a grab Hyprland refuses to move focus.
  // Instead the selected window is the wide live preview in the middle of the
  // row, the way the image picker expands its selection. You therefore see
  // where you are going, and releasing confirms it.
  function focusWindow(address) {
    address = root.clientAddress(address)
    if (!address || !root.hasWindowAddress(address)
        || typeof root.currentWorkspaceId !== "number") return false
    var workspaceId = root.currentWorkspaceId
    Quickshell.execDetached(hyprEval(
      "(function() local current = hl.get_active_window();" +
      " local target = hl.get_window('address:" + address + "');" +
      " if not current or not current.workspace or not target or not target.mapped" +
      "    or not target.workspace or current.workspace.id ~= " + workspaceId +
      "    or target.workspace.id ~= " + workspaceId + " then return false end;" +
      " hl.dispatch(hl.dsp.focus({ window = 'address:" + address + "' }));" +
      " return true end)()"))
    return true
  }

  // A click is the only control that does not use Omarchy's ALT+TAB. Every
  // preview is an activation target; keyboard browsing remains compositor-owned.
  function activate(index) {
    var window = index >= 0 && index < root.count ? root.windows[index] : null
    if (window) root.focusWindow(window.address)
    root.close()
  }

  onCountChanged: {
    if (opened && count === 0) close()
    else if (selectedIndex >= count) selectedIndex = Math.max(0, count - 1)
  }

  // Everything a compositor change can invalidate: a row on screen, a read that
  // is running, or a model that is not torn down yet. Both watchers below need
  // exactly this, one of them negated, so it is written once.
  // A request whose read has not started yet is deliberately not in here. That
  // window is one event-loop turn wide, and the read it goes on to start reads
  // the compositor AFTER the change, so it can only ever describe the workspace
  // you are on by then -- never the one you left.
  function hasLiveRow() {
    return opened || readProc.running || count > 0
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!event || !event.name) return
      var name = String(event.name)
      // Observe focus continuously, including while the row is closed. The
      // notification binding runs after the stock dispatchers, so this event's
      // previous side is the Escape anchor for a new physical sequence.
      if (name === "activewindowv2")
        root.rememberActiveWindow(root.eventAddress(event))
      if (!root.hasLiveRow()) return
      // After these events, an existing entry may no longer belong to the
      // focused workspace. Close first; only a new press may refresh.
      if (/^(?:workspace|focusedmon|activespecial|monitorremoved|moveworkspace)(?:v2)?$|^configreloaded$/.test(name))
        root.close()
      // During a read, the still unknown snapshot is suspect; afterward, only a
      // source from our own row is reason to close the entire overlay.
      else if (/^(?:movewindow(?:v2)?|closewindow)$/.test(name)
               && (readProc.running || root.hasWindowAddress(root.eventAddress(event))))
        root.close()
    }
  }

  Connections {
    target: Quickshell
    function onScreensChanged() {
      if (root.hasLiveRow()) root.close()
    }
  }

  // ----------------------------------------------------------------- image
  // The parallelogram that makes the slices interlock like cards. Needed twice
  // per slice: as a mask for the image and as a border over it.
  component SkewedSlice: Shape {
    id: slice
    property real skew: 0
    property color fill: "transparent"
    property color stroke: "transparent"
    property real thickness: 1
    antialiasing: true
    preferredRendererType: Shape.CurveRenderer
    ShapePath {
      fillColor: slice.fill
      strokeColor: slice.stroke
      strokeWidth: slice.thickness
      startX: slice.skew; startY: 0
      PathLine { x: slice.width; y: 0 }
      PathLine { x: slice.width - slice.skew; y: slice.height }
      PathLine { x: 0; y: slice.height }
      PathLine { x: slice.skew; y: 0 }
    }
  }

  PanelWindow {
    id: panel

    screen: root.targetScreen
    visible: root.opened && root.revealed && root.count > 0 && root.targetScreen !== null
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "m4rone-altswitch"
    WlrLayershell.layer: WlrLayer.Overlay
    // No keyboard grab, which is the pivot of the design. With the keyboard
    // grabbed, Hyprland refused to move window focus and nothing switched --
    // measured. Switching therefore remains in the stock in-compositor
    // bindings; this overlay is only the list laid over it.
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    // Dim only. The window underneath is the window you are now on, because
    // Hyprland has already switched; it should therefore remain visible.
    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    Item {
      id: card
      anchors.centerIn: parent
      width: Math.min(parent.width - 80, carousel.width + 40)
      height: root.expandedHeight + root.labelHeight

      // Swallows clicks on the card itself, so they do not reach the closing
      // MouseArea underneath.
      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: carousel
        anchors.top: parent.top
        anchors.horizontalCenter: parent.horizontalCenter
        width: root.expandedWidth + root.sideSlices * itemStep
        height: root.expandedHeight

        readonly property real itemStep: root.sliceWidth + root.sliceSpacing
        readonly property real previewX: (width - root.expandedWidth) / 2

        Repeater {
          model: root.opened && root.revealed ? root.count : 0

          delegate: Item {
            id: item
            required property int index

            readonly property var entry: root.windows[index]
            readonly property var captureToplevel:
              entry ? root.toplevelForAddress(entry.address) : null
            readonly property bool selected: index === root.selectedIndex
            readonly property int relativeIndex: index - root.selectedIndex
            readonly property bool nearby: Math.abs(relativeIndex) <= root.sideSlices

            visible: nearby
            width: selected ? root.expandedWidth : root.sliceWidth
            height: selected ? root.expandedHeight : root.sliceHeight
            y: selected ? 0 : (root.expandedHeight - root.sliceHeight) / 2
            z: selected ? 100 : 50 - Math.min(Math.abs(relativeIndex), 40)
            // Everything is measured from the center: left one step per position,
            // right from the far edge of that center on.
            x: carousel.previewX + (selected ? 0
               : relativeIndex < 0 ? relativeIndex * carousel.itemStep
               : root.expandedWidth + root.sliceSpacing + (relativeIndex - 1) * carousel.itemStep)

            Behavior on x { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
            Behavior on width { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
            Behavior on height { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }

            Item {
              id: maskShape
              anchors.fill: parent
              visible: false
              layer.enabled: true

              SkewedSlice { anchors.fill: parent; skew: root.skewOffset; fill: "white" }
            }

            Item {
              anchors.fill: parent
              layer.enabled: true
              layer.smooth: true
              layer.effect: MultiEffect {
                maskEnabled: true
                maskSource: maskShape
                maskThresholdMin: 0.3
                maskSpreadAtMin: 0.3
              }

              // Alpha 1.0 on purpose: a translucent theme background would let
              // the desktop show through the preview (point 2 at the top).
              Rectangle { anchors.fill: parent; color: Util.alpha(Color.background, 1.0) }

              // The live image of the window itself. Only the selected slice
              // refreshes; otherwise the rest costs an image per frame without
              // benefiting anyone.
              ScreencopyView {
                anchors.fill: parent
                captureSource: item.captureToplevel ? item.captureToplevel.wayland : null
                live: item.selected && root.opened && root.revealed
                paintCursor: false
              }

              // Dim unselected slices so the center draws the eye.
              Rectangle {
                anchors.fill: parent
                color: Util.alpha(Color.background, item.selected ? 0 : 0.45)
              }
            }

            SkewedSlice {
              anchors.fill: parent
              skew: root.skewOffset
              stroke: item.selected ? Color.accent : Util.alpha(Color.foreground, 0.22)
              thickness: item.selected ? 3 : 1
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.activate(item.index)
            }
          }
        }
      }

      // Window names are external text: always show them as plain text, never as
      // markup.
      Text {
        id: titleLabel
        anchors.top: carousel.bottom
        anchors.topMargin: 20
        anchors.horizontalCenter: parent.horizontalCenter
        width: root.expandedWidth
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideRight
        maximumLineCount: 1
        textFormat: Text.PlainText
        text: root.selectedWindow
          ? (root.selectedWindow.title || root.selectedWindow.cls) : ""
        color: Color.foreground
        font.pixelSize: 15
        font.bold: true
        renderType: Text.NativeRendering
      }

      Text {
        anchors.top: titleLabel.bottom
        anchors.topMargin: 6
        anchors.horizontalCenter: parent.horizontalCenter
        textFormat: Text.PlainText
        text: root.count > 0
          ? (root.selectedIndex + 1) + " / " + root.count
            + (root.currentWorkspace ? "     " + root.currentWorkspace : "")
          : ""
        color: Util.alpha(Color.foreground, 0.5)
        font.pixelSize: 12
        renderType: Text.NativeRendering
      }
    }
  }
}
