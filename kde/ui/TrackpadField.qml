import QtQuick
import org.kde.kirigami as Kirigami

// Live view of the trackpad surface: fingers glow, a click sends out a small
// dotted ripple, a force click a bigger multi-ring one. Everything is clipped
// to the field.
Item {
    id: field

    property var touches: []
    property color accent: Qt.rgba(0.24, 0.56, 0.98, 1)
    property var waves: []

    implicitWidth: Kirigami.Units.gridUnit * 22
    implicitHeight: width * 115 / 160   // Magic Trackpad 2 aspect ratio

    readonly property real radius: width * 0.06

    function ripple(force) {
        const t = touches.length > 0 ? touches[0] : { x: 0.5, y: 0.5 };
        const now = Date.now();
        const list = waves.filter(w => now - w.start < w.duration + w.delay);
        if (force) {
            for (let i = 0; i < 3; i++) {
                list.push({ x: t.x, y: t.y, start: now, delay: i * 190, duration: 1200, reach: 0.95, dot: 2.6 });
            }
        } else {
            list.push({ x: t.x, y: t.y, start: now, delay: 0, duration: 650, reach: 0.28, dot: 1.8 });
        }
        waves = list;
        canvas.requestPaint();
    }

    onTouchesChanged: canvas.requestPaint()

    FrameAnimation {
        running: field.waves.length > 0
        onTriggered: canvas.requestPaint()
    }

    Canvas {
        id: canvas
        anchors.fill: parent
        renderStrategy: Canvas.Cooperative

        function roundRect(ctx, x, y, w, h, r) {
            ctx.beginPath();
            ctx.moveTo(x + r, y);
            ctx.arcTo(x + w, y, x + w, y + h, r);
            ctx.arcTo(x + w, y + h, x, y + h, r);
            ctx.arcTo(x, y + h, x, y, r);
            ctx.arcTo(x, y, x + w, y, r);
            ctx.closePath();
        }

        function rgba(c, a) {
            return Qt.rgba(c.r, c.g, c.b, a);
        }

        onPaint: {
            const ctx = getContext("2d");
            const w = width, h = height, a = field.accent;
            ctx.reset();

            // Surface
            roundRect(ctx, 0.5, 0.5, w - 1, h - 1, field.radius);
            ctx.fillStyle = Kirigami.Theme.alternateBackgroundColor;
            ctx.fill();
            ctx.strokeStyle = rgba(Kirigami.Theme.textColor, 0.15);
            ctx.lineWidth = 1;
            ctx.stroke();

            ctx.save();
            roundRect(ctx, 0.5, 0.5, w - 1, h - 1, field.radius);
            ctx.clip();

            // Faint dot grid
            ctx.fillStyle = rgba(a, 0.22);
            const step = Math.max(12, w / 28);
            for (let gx = step / 2; gx < w; gx += step) {
                for (let gy = step / 2; gy < h; gy += step) {
                    ctx.fillRect(gx - 1, gy - 1, 2, 2);
                }
            }

            // Ripples: rings made of dots, eased out and fading
            const now = Date.now();
            const alive = [];
            for (const wave of field.waves) {
                const age = now - wave.start - wave.delay;
                if (age > wave.duration) {
                    continue;
                }
                alive.push(wave);
                if (age < 0) {
                    continue;
                }
                const t = age / wave.duration;
                const ease = 1 - Math.pow(1 - t, 2);
                const r = 6 + ease * wave.reach * w;
                const n = Math.max(12, Math.floor(2 * Math.PI * r / 9));
                ctx.fillStyle = rgba(a, Math.pow(1 - t, 1.4) * 0.9);
                const dot = wave.dot * (1 - 0.4 * t);
                for (let i = 0; i < n; i++) {
                    const ang = i / n * 2 * Math.PI;
                    ctx.beginPath();
                    ctx.arc(wave.x * w + Math.cos(ang) * r, wave.y * h + Math.sin(ang) * r, dot, 0, 2 * Math.PI);
                    ctx.fill();
                }
            }
            if (alive.length !== field.waves.length) {
                field.waves = alive;
            }

            // Fingers: soft glow growing with pressure
            for (const touch of field.touches) {
                const x = touch.x * w, y = touch.y * h;
                const r = 10 + touch.p / 253 * 22;
                const g = ctx.createRadialGradient(x, y, 0, x, y, r);
                g.addColorStop(0, rgba(a, 0.85));
                g.addColorStop(0.35, rgba(a, 0.45));
                g.addColorStop(1, rgba(a, 0));
                ctx.fillStyle = g;
                ctx.beginPath();
                ctx.arc(x, y, r, 0, 2 * Math.PI);
                ctx.fill();
            }
            ctx.restore();
        }
    }
}
