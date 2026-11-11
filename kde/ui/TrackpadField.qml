import QtQuick
import org.kde.kirigami as Kirigami

// Live view of the trackpad surface, rendered by a fragment shader
// (shaders/ripple.glsl): a dense dot texture, fingers light the dots under
// them, a click sends a small ripple through it, a force click a big one.
Item {
    id: field

    property var touches: []

    implicitWidth: Kirigami.Units.gridUnit * 22
    implicitHeight: width * 115 / 160   // Magic Trackpad 2 aspect ratio

    readonly property real epoch: Date.now()
    property int nextWave: 0
    property real lastWaveEnd: 0

    function now() {
        return (Date.now() - epoch) / 1000;
    }

    function ripple(force) {
        const t = touches.length > 0 ? touches[0] : { x: 0.5, y: 0.5 };
        const start = now();
        shader["w" + nextWave] = Qt.vector4d(t.x * width, t.y * height, start, force ? 2 : 1);
        nextWave = (nextWave + 1) % 8;
        lastWaveEnd = Math.max(lastWaveEnd, start + (force ? 2.4 : 1.3));
        shader.time = start;
    }

    onTouchesChanged: updateTouches()
    onWidthChanged: updateTouches()
    onHeightChanged: updateTouches()

    function updateTouches() {
        for (let i = 0; i < 5; i++) {
            const t = touches[i];
            shader["t" + i] = t ? Qt.vector4d(t.x * width, t.y * height, t.p / 253, 1) : Qt.vector4d(0, 0, 0, 0);
        }
        shader.time = now();
    }

    // Repaint only while something moves
    FrameAnimation {
        running: field.visible && field.lastWaveEnd > shader.time
        onTriggered: shader.time = field.now()
    }

    ShaderEffect {
        id: shader
        anchors.fill: parent
        blending: true
        fragmentShader: "qrc:/mt2d/ripple.frag.qsb"

        property size fieldSize: Qt.size(width, height)
        property real time: 0
        property vector4d w0; property vector4d w1; property vector4d w2; property vector4d w3
        property vector4d w4; property vector4d w5; property vector4d w6; property vector4d w7
        property vector4d t0; property vector4d t1; property vector4d t2; property vector4d t3
        property vector4d t4
    }
}
