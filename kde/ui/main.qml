import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

KCM.SimpleKCM {
    id: root

    readonly property var strengths: [
        { key: "light", label: i18n("Light") },
        { key: "medium", label: i18n("Medium") },
        { key: "firm", label: i18n("Firm") },
        { key: "max", label: i18n("Maximum (loud)") },
        { key: "off", label: i18n("Off") },
    ]
    readonly property var actions: [
        { keys: ["BTN_MIDDLE"], label: i18n("Middle click") },
        { keys: ["BTN_RIGHT"], label: i18n("Right click") },
        { keys: ["KEY_BACK"], label: i18n("Back") },
        { keys: ["KEY_FORWARD"], label: i18n("Forward") },
        { keys: ["KEY_LEFTMETA", "KEY_W"], label: i18n("Overview") },
        { keys: null, label: i18n("Custom keys") },
    ]

    property var cfg: null
    property bool loading: true
    property var pending: ({})
    property var live: ({ connected: false, pressure: 0, clicked: false, battery: null, touches: [] })
    property int lastClicks: -1
    property int lastForces: -1
    readonly property bool hostMode: cfg !== null && cfg.mode === "host"

    function call(cmd) {
        const r = kcm.call(cmd);
        if (!r.ok && cmd.op !== "live") {
            errorMessage.text = r.error;
            errorMessage.visible = true;
        } else if (r.ok) {
            errorMessage.visible = false;
        }
        return r;
    }

    function load() {
        const r = call({ op: "get" });
        if (!r.ok) {
            return;
        }
        loading = true;
        cfg = r.config;
        modeBox.currentIndex = cfg.mode === "host" ? 0 : 1;
        clickForce.value = cfg.click.threshold;
        strengthBox.currentIndex = strengths.findIndex(s => s.key === cfg.haptics.strength);
        silent.checked = cfg.haptics.silent;
        forceOn.checked = cfg.force_click.enabled;
        forceForce.value = cfg.force_click.threshold;
        replace.checked = cfg.force_click.replace_click;
        dwell.value = cfg.force_click.dwell_ms;
        const want = JSON.stringify(cfg.force_click.action);
        let idx = actions.findIndex(a => a.keys !== null && JSON.stringify(a.keys) === want);
        actionBox.currentIndex = idx < 0 ? actions.length - 1 : idx;
        customKeys.text = cfg.force_click.action.join(" ");
        loading = false;
    }

    // Merge a partial change and save it shortly after the last edit
    function queue(change) {
        if (loading) {
            return;
        }
        for (const section in change) {
            if (typeof change[section] === "object" && !Array.isArray(change[section])) {
                pending[section] = Object.assign(pending[section] || {}, change[section]);
            } else {
                pending[section] = change[section];
            }
        }
        saveTimer.restart();
    }

    Timer {
        id: saveTimer
        interval: 250
        onTriggered: {
            const change = root.pending;
            root.pending = {};
            const r = root.call({ op: "set", config: change });
            if (r.ok) {
                root.cfg = r.config;
            }
        }
    }

    Timer {
        interval: 16
        running: true
        repeat: true
        onTriggered: {
            const r = kcm.call({ op: "live" });
            if (r.ok) {
                root.live = r;
                if (root.lastForces >= 0 && r.forces > root.lastForces) {
                    field.ripple(true);
                } else if (root.lastClicks >= 0 && r.clicks > root.lastClicks) {
                    field.ripple(false);
                }
                root.lastClicks = r.clicks;
                root.lastForces = r.forces;
                if (root.cfg === null) {
                    root.load();
                }
            } else {
                root.live = { connected: false, pressure: 0, clicked: false, battery: null, touches: [], error: r.error };
            }
        }
    }

    Component.onCompleted: load()

    header: Kirigami.InlineMessage {
        id: errorMessage
        type: Kirigami.MessageType.Error
        showCloseButton: true
        visible: false
    }

    Kirigami.FormLayout {
        QQC2.Label {
            Kirigami.FormData.label: i18n("Trackpad:")
            text: root.live.error ? root.live.error
                : root.live.connected ? (root.live.battery !== null
                    ? i18n("Connected, battery %1%", root.live.battery) : i18n("Connected"))
                : i18n("Not connected")
        }

        Item { Kirigami.FormData.isSection: true; Kirigami.FormData.label: i18n("Clicking") }

        QQC2.ComboBox {
            id: modeBox
            Kirigami.FormData.label: i18n("Click mode:")
            model: [i18n("Pressure"), i18n("Firmware")]
            onActivated: root.queue({ mode: currentIndex === 0 ? "host" : "firmware" })
        }
        QQC2.Label {
            Layout.maximumWidth: Kirigami.Units.gridUnit * 22
            wrapMode: Text.Wrap
            font: Kirigami.Theme.smallFont
            opacity: 0.7
            text: root.hostMode
                ? i18n("mt2d decides clicks from the real force curve. Enables click force and force click.")
                : i18n("The trackpad clicks on its own. Only the haptic feel is applied.")
        }

        RowLayout {
            Kirigami.FormData.label: i18n("Click force:")
            enabled: root.hostMode
            QQC2.Label { text: i18nc("click force", "Light") }
            QQC2.Slider {
                id: clickForce
                from: 40; to: 200; stepSize: 5
                Layout.preferredWidth: Kirigami.Units.gridUnit * 14
                onMoved: root.queue({ click: { threshold: value, release: Math.max(20, value - 30) } })
            }
            QQC2.Label { text: i18nc("click force", "Firm") }
            QQC2.Label { text: clickForce.value; opacity: 0.7 }
        }

        QQC2.ComboBox {
            id: strengthBox
            Kirigami.FormData.label: i18n("Haptic feedback:")
            model: root.strengths.map(s => s.label)
            onActivated: root.queue({ haptics: { strength: root.strengths[currentIndex].key } })
        }

        QQC2.CheckBox {
            id: silent
            text: i18n("Silent clicking")
            onToggled: root.queue({ haptics: { silent: checked } })
        }

        RowLayout {
            Kirigami.FormData.label: i18n("Test haptics:")
            Repeater {
                model: [["weak", i18n("Weak")], ["medium", i18n("Medium")], ["strong", i18n("Strong")]]
                QQC2.Button {
                    required property var modelData
                    text: modelData[1]
                    onClicked: root.call({ op: "pulse", value: modelData[0] })
                }
            }
        }

        Item { Kirigami.FormData.isSection: true; Kirigami.FormData.label: i18n("Force click") }

        QQC2.CheckBox {
            id: forceOn
            Kirigami.FormData.label: i18n("Force click:")
            enabled: root.hostMode
            text: i18n("Press harder after clicking to trigger an action")
            onToggled: root.queue({ force_click: { enabled: checked } })
        }

        RowLayout {
            Kirigami.FormData.label: i18n("Force click pressure:")
            enabled: root.hostMode && forceOn.checked
            QQC2.Slider {
                id: forceForce
                from: 150; to: 253; stepSize: 1
                Layout.preferredWidth: Kirigami.Units.gridUnit * 14
                onMoved: root.queue({ force_click: { threshold: value, release: Math.max(100, value - 50) } })
            }
            QQC2.Label { text: forceForce.value; opacity: 0.7 }
        }

        QQC2.ComboBox {
            id: actionBox
            Kirigami.FormData.label: i18n("Action:")
            enabled: root.hostMode && forceOn.checked
            model: root.actions.map(a => a.label)
            onActivated: {
                const keys = root.actions[currentIndex].keys;
                if (keys !== null) {
                    root.queue({ force_click: { action: keys } });
                }
            }
        }

        QQC2.TextField {
            id: customKeys
            Kirigami.FormData.label: i18n("Keys:")
            visible: actionBox.currentIndex === root.actions.length - 1
            enabled: root.hostMode && forceOn.checked
            placeholderText: "KEY_LEFTMETA KEY_W"
            Layout.preferredWidth: Kirigami.Units.gridUnit * 14
            onEditingFinished: {
                const keys = text.split(/\s+/).filter(k => k.length > 0);
                if (keys.length > 0) {
                    root.queue({ force_click: { action: keys } });
                }
            }
        }

        QQC2.CheckBox {
            id: replace
            enabled: root.hostMode && forceOn.checked
            text: i18n("Force click replaces the normal click")
            onToggled: root.queue({ force_click: { replace_click: checked } })
        }

        QQC2.SpinBox {
            id: dwell
            Kirigami.FormData.label: i18n("Hold time (ms):")
            enabled: root.hostMode && forceOn.checked
            from: 0; to: 500; stepSize: 10
            onValueModified: root.queue({ force_click: { dwell_ms: value } })
        }

        Item { Kirigami.FormData.isSection: true; Kirigami.FormData.label: i18n("Pressure") }

        ColumnLayout {
            Kirigami.FormData.label: i18n("Live:")
            TrackpadField {
                id: field
                Layout.fillWidth: true
                Layout.preferredHeight: width * 115 / 160
                touches: root.live.touches || []
            }
            QQC2.ProgressBar {
                Layout.fillWidth: true
                from: 0; to: 253
                value: root.live.pressure || 0
            }
            QQC2.Label {
                opacity: 0.7
                text: root.cfg === null ? "" : i18n("%1   click at %2, force at %3   %4",
                    root.live.pressure || 0, root.cfg.click.threshold, root.cfg.force_click.threshold,
                    root.live.clicked ? i18n("clicked") : "")
            }
        }
    }
}
