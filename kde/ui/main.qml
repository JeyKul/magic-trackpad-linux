import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

KCM.SimpleKCM {
    id: root

    readonly property var strengths: [
        { key: "light", label: i18nc("@item:inlistbox haptic feedback strength", "Light") },
        { key: "medium", label: i18nc("@item:inlistbox haptic feedback strength", "Medium") },
        { key: "firm", label: i18nc("@item:inlistbox haptic feedback strength", "Firm") },
        { key: "max", label: i18nc("@item:inlistbox haptic feedback strength", "Maximum (loud)") },
        { key: "off", label: i18nc("@item:inlistbox haptic feedback strength", "Off (silent clicks)") },
    ]
    readonly property var releases: [
        { key: "auto", label: i18nc("@item:inlistbox release click", "Match haptic feedback") },
        { key: "firm", label: i18nc("@item:inlistbox release click", "Firm") },
        { key: "medium", label: i18nc("@item:inlistbox release click", "Medium") },
        { key: "light", label: i18nc("@item:inlistbox release click", "Light") },
        { key: "off", label: i18nc("@item:inlistbox release click", "Off") },
    ]
    readonly property var actions: [
        { keys: ["BTN_MIDDLE"], label: i18nc("@item:inlistbox force click action", "Middle click") },
        { keys: ["BTN_RIGHT"], label: i18nc("@item:inlistbox force click action", "Right click") },
        { keys: ["KEY_BACK"], label: i18nc("@item:inlistbox force click action", "Go back") },
        { keys: ["KEY_FORWARD"], label: i18nc("@item:inlistbox force click action", "Go forward") },
        { keys: ["KEY_LEFTMETA", "KEY_W"], label: i18nc("@item:inlistbox force click action", "Show Overview") },
        { keys: null, label: i18nc("@item:inlistbox force click action", "Custom keys") },
    ]

    // saved: what mt2d runs with; draft: what the page shows until Apply
    property var saved: null
    property var draft: null
    property var defaultConfig: null
    property bool daemonRunning: true
    property bool customAction: false
    property var live: ({ connected: false, pressure: 0, clicked: false, battery: null, touches: [] })
    property int lastClicks: -1
    property int lastForces: -1

    readonly property bool ready: draft !== null
    readonly property bool hostMode: ready && draft.mode === "host"
    readonly property bool forceActive: hostMode && draft.force_click.enabled

    function copy(o) {
        return JSON.parse(JSON.stringify(o));
    }

    function changeDraft(section, key, value) {
        const d = copy(draft);
        if (key === null) {
            d[section] = value;
        } else {
            d[section][key] = value;
        }
        draft = d;
        updateState();
    }

    function updateState() {
        kcm.needsSave = ready && saved !== null && JSON.stringify(draft) !== JSON.stringify(saved);
        kcm.representsDefaults = ready && defaultConfig !== null && JSON.stringify(draft) === JSON.stringify(defaultConfig);
    }

    function isDefault(section, key) {
        if (!ready || defaultConfig === null) {
            return true;
        }
        const a = key === null ? draft[section] : draft[section][key];
        const b = key === null ? defaultConfig[section] : defaultConfig[section][key];
        return JSON.stringify(a) === JSON.stringify(b);
    }

    function load() {
        const r = kcm.call({ op: "get" });
        daemonRunning = r.ok;
        if (!r.ok) {
            return;
        }
        // Defaults merged over the current config keep the same keys and order
        defaultConfig = Object.assign(copy(r.config), copy(r.defaults));
        saved = r.config;
        draft = copy(r.config);
        const want = JSON.stringify(draft.force_click.action);
        customAction = !actions.some(a => a.keys !== null && JSON.stringify(a.keys) === want);
        updateState();
    }

    Connections {
        target: kcm
        function onLoadRequested() { root.load(); }
        function onDefaultsRequested() {
            if (root.defaultConfig !== null) {
                root.draft = root.copy(root.defaultConfig);
                root.customAction = false;
                root.updateState();
            }
        }
        function onSaveRequested() {
            const r = kcm.call({ op: "set", config: root.draft });
            if (r.ok) {
                root.saved = r.config;
                root.draft = root.copy(r.config);
                saveError.visible = false;
            } else {
                saveError.text = i18n("The settings could not be applied: %1", r.error);
                saveError.visible = true;
            }
            root.updateState();
        }
    }

    Component.onCompleted: load()

    Timer {
        interval: 16
        running: root.visible
        repeat: true
        onTriggered: {
            const r = kcm.call({ op: "live" });
            if (!r.ok) {
                root.daemonRunning = false;
                return;
            }
            if (!root.daemonRunning || root.draft === null) {
                root.load();
            }
            root.live = r;
            // Respect the global animation speed setting: no ripples when animations are off
            if (Kirigami.Units.longDuration > 0) {
                if (root.lastForces >= 0 && r.forces > root.lastForces) {
                    field.ripple(true);
                } else if (root.lastClicks >= 0 && r.clicks > root.lastClicks) {
                    field.ripple(false);
                }
            }
            root.lastClicks = r.clicks;
            root.lastForces = r.forces;
        }
    }

    header: ColumnLayout {
        spacing: 0

        Kirigami.InlineMessage {
            Layout.fillWidth: true
            position: Kirigami.InlineMessage.Position.Header
            type: Kirigami.MessageType.Error
            visible: !root.daemonRunning
            text: i18n("The Magic Trackpad service is not running, so clicking and haptics are handled by the trackpad alone.")
            actions: Kirigami.Action {
                icon.name: "media-playback-start"
                text: i18nc("@action:button", "Start Service")
                onTriggered: kcm.startService()
            }
        }

        Kirigami.InlineMessage {
            Layout.fillWidth: true
            position: Kirigami.InlineMessage.Position.Header
            type: Kirigami.MessageType.Information
            visible: root.daemonRunning && root.ready && !root.live.connected
            text: i18n("No Magic Trackpad is connected. Turn it on, or pair it in the Bluetooth settings.")
            actions: Kirigami.Action {
                icon.name: "preferences-system-bluetooth"
                text: i18nc("@action:button", "Bluetooth Settings…")
                onTriggered: KCM.KCMLauncher.openSystemSettings("kcm_bluetooth")
            }
        }

        Kirigami.InlineMessage {
            Layout.fillWidth: true
            position: Kirigami.InlineMessage.Position.Header
            type: Kirigami.MessageType.Warning
            visible: root.live.connected && root.live.battery !== null && root.live.battery <= 15
            text: i18n("The trackpad battery is low (%1%). Charge it soon.", root.live.battery)
        }

        Kirigami.InlineMessage {
            id: saveError
            Layout.fillWidth: true
            position: Kirigami.InlineMessage.Position.Header
            type: Kirigami.MessageType.Error
            showCloseButton: true
            visible: false
        }
    }

    Kirigami.FormLayout {
        enabled: root.ready

        QQC2.Label {
            Kirigami.FormData.label: i18nc("@label", "Status:")
            text: !root.live.connected ? i18nc("@info trackpad status", "Not connected")
                : root.live.battery !== null ? i18nc("@info trackpad status", "Connected, battery at %1%", root.live.battery)
                : i18nc("@info trackpad status", "Connected")
        }

        Item {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: i18nc("@title:group", "Clicking")
        }

        QQC2.RadioButton {
            id: pressureMode
            Kirigami.FormData.label: i18nc("@label", "Click detection:")
            text: i18nc("@option:radio", "Pressure-sensitive")
            checked: root.hostMode
            onToggled: root.changeDraft("mode", null, "host")
            KCM.SettingHighlighter { highlight: !root.isDefault("mode", null) }
        }
        RowLayout {
            spacing: Kirigami.Units.smallSpacing
            QQC2.RadioButton {
                text: i18nc("@option:radio", "Built into the trackpad")
                checked: root.ready && !root.hostMode
                onToggled: root.changeDraft("mode", null, "firmware")
            }
            Kirigami.ContextualHelpButton {
                toolTipText: xi18nc("@info:tooltip",
                    "<para><emphasis>Pressure-sensitive</emphasis>: clicks are detected from how hard the trackpad is pressed. This allows choosing the click force and using force click.</para>"
                    + "<para><emphasis>Built into the trackpad</emphasis>: the trackpad decides when to click on its own. Only the strength of the haptic feedback can be changed.</para>")
            }
        }

        RowLayout {
            Kirigami.FormData.label: i18nc("@label:slider", "Click force:")
            enabled: root.hostMode
            spacing: Kirigami.Units.smallSpacing

            ColumnLayout {
                Layout.fillWidth: false
                spacing: 0
                QQC2.Slider {
                    id: clickForce
                    Layout.preferredWidth: Kirigami.Units.gridUnit * 12
                    from: 40; to: 200; stepSize: 10
                    value: root.ready ? root.draft.click.threshold : 90
                    Accessible.name: i18nc("@label:slider accessible", "Click force")
                    onMoved: root.setClickForce(Math.round(value))
                    KCM.SettingHighlighter { highlight: !root.isDefault("click", "threshold") }
                }
                RowLayout {
                    Layout.maximumWidth: clickForce.width
                    QQC2.Label {
                        text: i18nc("@label click force", "Light")
                        font: Kirigami.Theme.smallFont
                        Layout.fillWidth: true
                    }
                    QQC2.Label {
                        text: i18nc("@label click force", "Firm")
                        font: Kirigami.Theme.smallFont
                    }
                }
            }
            QQC2.SpinBox {
                Layout.alignment: Qt.AlignTop
                from: 40; to: 200; stepSize: 5
                value: root.ready ? root.draft.click.threshold : 90
                Accessible.name: i18nc("@label:spinbox accessible", "Click force")
                onValueModified: root.setClickForce(value)
            }
        }

        QQC2.ComboBox {
            Kirigami.FormData.label: i18nc("@label:listbox", "Haptic feedback:")
            model: root.strengths.map(s => s.label)
            currentIndex: root.ready ? root.strengths.findIndex(s => s.key === root.draft.haptics.strength) : 1
            onActivated: index => {
                root.changeDraft("haptics", "strength", root.strengths[index].key);
                // A separate silent flag would only duplicate "Off"
                if (root.draft.haptics.silent) {
                    root.changeDraft("haptics", "silent", false);
                }
            }
            KCM.SettingHighlighter { highlight: !root.isDefault("haptics", "strength") }
        }

        QQC2.ComboBox {
            Kirigami.FormData.label: i18nc("@label:listbox", "Release click:")
            enabled: root.ready && root.draft.haptics.strength !== "off"
            model: root.releases.map(r => r.label)
            currentIndex: root.ready ? Math.max(0, root.releases.findIndex(r => r.key === (root.draft.haptics.release || "auto"))) : 0
            onActivated: index => root.changeDraft("haptics", "release", root.releases[index].key)
            KCM.SettingHighlighter { highlight: !root.isDefault("haptics", "release") }
        }

        RowLayout {
            Kirigami.FormData.label: i18nc("@label", "Test feedback:")
            enabled: root.live.connected
            spacing: Kirigami.Units.smallSpacing
            Repeater {
                model: [
                    ["weak", i18nc("@action:button haptic pulse strength", "Weak")],
                    ["medium", i18nc("@action:button haptic pulse strength", "Medium")],
                    ["strong", i18nc("@action:button haptic pulse strength", "Strong")],
                ]
                QQC2.Button {
                    required property var modelData
                    text: modelData[1]
                    onClicked: kcm.call({ op: "pulse", value: modelData[0] })
                }
            }
        }

        Item {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: i18nc("@title:group", "Force Click")
        }

        QQC2.CheckBox {
            Kirigami.FormData.label: i18nc("@label", "Force click:")
            enabled: root.hostMode
            text: i18nc("@option:check", "Trigger an action by pressing harder")
            checked: root.ready && root.draft.force_click.enabled
            onToggled: root.changeDraft("force_click", "enabled", checked)
            KCM.SettingHighlighter { highlight: !root.isDefault("force_click", "enabled") }
        }

        RowLayout {
            Kirigami.FormData.label: i18nc("@label:slider", "Pressure needed:")
            enabled: root.forceActive
            spacing: Kirigami.Units.smallSpacing
            QQC2.Slider {
                Layout.preferredWidth: Kirigami.Units.gridUnit * 12
                from: 150; to: 253; stepSize: 1
                value: root.ready ? root.draft.force_click.threshold : 250
                Accessible.name: i18nc("@label:slider accessible", "Force click pressure")
                onMoved: root.setForcePressure(Math.round(value))
                KCM.SettingHighlighter { highlight: !root.isDefault("force_click", "threshold") }
            }
            QQC2.SpinBox {
                from: 150; to: 253
                value: root.ready ? root.draft.force_click.threshold : 250
                Accessible.name: i18nc("@label:spinbox accessible", "Force click pressure")
                onValueModified: root.setForcePressure(value)
            }
        }

        QQC2.SpinBox {
            Kirigami.FormData.label: i18nc("@label:spinbox", "Hold for:")
            enabled: root.forceActive
            from: 0; to: 500; stepSize: 10
            value: root.ready ? root.draft.force_click.dwell_ms : 60
            textFromValue: (value, locale) => i18ncp("@item:valuesuffix", "%1 millisecond", "%1 milliseconds", value)
            valueFromText: (text, locale) => parseInt(text) || 0
            onValueModified: root.changeDraft("force_click", "dwell_ms", value)
            KCM.SettingHighlighter { highlight: !root.isDefault("force_click", "dwell_ms") }
        }

        QQC2.ComboBox {
            id: actionBox
            Kirigami.FormData.label: i18nc("@label:listbox", "Action:")
            enabled: root.forceActive
            model: root.actions.map(a => a.label)
            currentIndex: {
                if (!root.ready || root.customAction) {
                    return root.actions.length - 1;
                }
                const want = JSON.stringify(root.draft.force_click.action);
                return root.actions.findIndex(a => a.keys !== null && JSON.stringify(a.keys) === want);
            }
            onActivated: index => {
                const keys = root.actions[index].keys;
                root.customAction = keys === null;
                if (keys !== null) {
                    root.changeDraft("force_click", "action", keys);
                }
            }
            KCM.SettingHighlighter { highlight: !root.isDefault("force_click", "action") }
        }

        QQC2.TextField {
            Kirigami.FormData.label: i18nc("@label:textbox", "Keys:")
            visible: root.customAction
            enabled: root.forceActive
            Layout.preferredWidth: Kirigami.Units.gridUnit * 14
            placeholderText: "KEY_LEFTMETA KEY_W"
            text: root.ready ? root.draft.force_click.action.join(" ") : ""
            onEditingFinished: {
                const keys = text.split(/\s+/).filter(k => k.length > 0);
                if (keys.length > 0) {
                    root.changeDraft("force_click", "action", keys);
                }
            }
        }

        QQC2.CheckBox {
            enabled: root.forceActive
            text: i18nc("@option:check", "Skip the normal click when force clicking")
            checked: root.ready && root.draft.force_click.replace_click
            onToggled: root.changeDraft("force_click", "replace_click", checked)
            KCM.SettingHighlighter { highlight: !root.isDefault("force_click", "replace_click") }
        }

        Item {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: i18nc("@title:group", "Live Preview")
        }

        ColumnLayout {
            Kirigami.FormData.label: i18nc("@label", "Touch the trackpad:")
            Layout.preferredWidth: Kirigami.Units.gridUnit * 20
            spacing: Kirigami.Units.smallSpacing

            TrackpadField {
                id: field
                Layout.fillWidth: true
                Layout.preferredHeight: width * 115 / 160
                touches: root.live.touches || []
                Accessible.name: i18nc("@info accessible", "Live view of fingers on the trackpad")
            }
            QQC2.ProgressBar {
                Layout.fillWidth: true
                from: 0; to: 253
                value: root.live.pressure || 0
                Accessible.name: i18nc("@info accessible", "Current pressure")
            }
            QQC2.Label {
                Layout.fillWidth: true
                font: Kirigami.Theme.smallFont
                color: Kirigami.Theme.disabledTextColor
                wrapMode: Text.Wrap
                text: !root.ready ? "" : root.hostMode
                    ? i18nc("@info", "Pressure %1 · clicks at %2 · force click at %3",
                            root.live.pressure || 0, root.draft.click.threshold, root.draft.force_click.threshold)
                    : i18nc("@info", "Pressure %1", root.live.pressure || 0)
            }
        }
    }

    function setClickForce(v) {
        const d = copy(draft);
        d.click.threshold = v;
        d.click.release = Math.max(20, v - 30);
        draft = d;
        updateState();
    }

    function setForcePressure(v) {
        const d = copy(draft);
        d.force_click.threshold = v;
        d.force_click.release = Math.max(100, v - 50);
        draft = d;
        updateState();
    }
}
