#!/usr/bin/env python3
"""mt2d - Magic Trackpad 2 userspace driver for Linux.

Runs alongside the in-kernel hid-magicmouse driver and adds what it lacks:
pressure-based clicking with adjustable click force, haptic strength, silent
clicking, force click, on-demand haptic pulses and battery status.

Two modes:
  host      (default) the firmware stops clicking on its own; mt2d grabs the
            kernel evdev node, re-emits it through an identical uinput clone
            (so libinput/KDE gestures, clickfinger, palm rejection keep
            working) and injects BTN_LEFT from the real force curve, firing
            the actuator itself.
  firmware  the firmware keeps clicking; mt2d only stores the click/release
            feel. No force click.

Protocol (MagicTrackpad2ForWindows, dos1, LinuxMagicForce):
  feature 0xF2 [0x21, on]  host-click mode: firmware stops clicking, the
                           pressure byte becomes a usable force value
  feature 0xF2 [0x22|0x23, 01, S, 78, 02, B, 24, 30, 06, 01, C, 18, 48, 13]
                           stored click (0x22) / release (0x23) feel, 0xCCBBSS
  output  0xF2 [0x53, ... same layout ..., 0x12]
                           fires the actuator once; needs SET_REPORT (HIDIOCSOUTPUT)
"""

import argparse
import errno
import fcntl
import glob
import json
import os
import queue
import select
import signal
import socket
import sys
import threading
import time
import tomllib

import evdev
from evdev import ecodes

# (bus, vendor, product): Lightning MT2 and USB-C MT2, over USB and Bluetooth
SUPPORTED = {
    (0x0003, 0x05AC, 0x0265), (0x0003, 0x05AC, 0x0324),
    (0x0005, 0x004C, 0x0265), (0x0005, 0x004C, 0x0324),
}

# Same presets as the Windows control panel: (click, release) in 0xCCBBSS
STRENGTH = {
    "light":  (0x040415, 0x000010),
    "medium": (0x060617, 0x000014),
    "firm":   (0x08081E, 0x020218),
    "max":    (0xFFFFFF, 0xFFFFFF),
    "off":    (0x000000, 0x000000),
}
FORCE_PULSE = 0x060622

PULSE = {"weak": 0x040415, "medium": 0x060617, "strong": 0x08081E, "max": 0x202026}

DEFAULT_CONFIG = {
    "mode": "host",
    "haptics": {"strength": "medium", "silent": False},
    "click": {
        "threshold": 90,        # peak pressure (0..253) that clicks
        "release": 60,          # pressure below which the click releases
    },
    "force_click": {
        "enabled": True,
        "threshold": 250,       # pressure that force-clicks...
        "dwell_ms": 60,         # ...held this long
        "release": 200,         # must drop below this to force-click again
        "replace_click": True,  # hold the left click back so a force click replaces it
        "pending_ms": 150,      # how long the left click is held back
        "pending_motion": 40,   # finger movement that commits the left click early
        "action": ["BTN_MIDDLE"],  # evdev key names, pressed in order, released reversed
    },
}

CONFIG_PATH = os.path.join(
    os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config")), "mt2d", "config.toml")
SOCKET_PATH = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "mt2d.sock")


def _ioc(nr, size):
    return (3 << 30) | (size << 16) | (ord("H") << 8) | nr


def HIDIOCSFEATURE(n):
    return _ioc(0x06, n)


def HIDIOCSOUTPUT(n):
    return _ioc(0x0B, n)


def haptic_report(kind, value, tail):
    return bytes([0xF2, kind, 0x01, value & 0xFF, 0x78, 0x02, (value >> 8) & 0xFF,
                  0x24, 0x30, 0x06, 0x01, (value >> 16) & 0xFF, 0x18, 0x48, tail])


def merge(dst, src):
    for k, v in src.items():
        if isinstance(v, dict) and isinstance(dst.get(k), dict):
            merge(dst[k], v)
        else:
            dst[k] = v
    return dst


def load_config():
    cfg = json.loads(json.dumps(DEFAULT_CONFIG))
    try:
        with open(CONFIG_PATH, "rb") as f:
            merge(cfg, tomllib.load(f))
    except FileNotFoundError:
        pass
    return cfg


def feel(cfg):
    h = cfg["haptics"]
    click, release = STRENGTH[h["strength"]]
    if h.get("silent"):
        click &= 0xFF
        release &= 0xFF
    return click, release


class Trackpad:
    def __init__(self, hidraw, event, battery):
        self.hidraw_path = hidraw
        self.hid = os.open(hidraw, os.O_RDWR)
        self.dev = evdev.InputDevice(event)
        self.battery = battery
        self.pulses = queue.Queue()
        # Each pulse is a SET_REPORT round trip over Bluetooth; keep it off the event loop
        threading.Thread(target=self._pulse_worker, daemon=True).start()

    def close(self):
        self.pulses.put(None)
        for f in (lambda: os.close(self.hid), self.dev.close):
            try:
                f()
            except OSError:
                pass

    def set_feature(self, buf):
        fcntl.ioctl(self.hid, HIDIOCSFEATURE(len(buf)), buf)

    def host_click(self, on):
        self.set_feature(bytes([0xF2, 0x21, 0x01 if on else 0x00]))

    def set_feel(self, click, release):
        self.set_feature(haptic_report(0x22, click, 0x13))
        self.set_feature(haptic_report(0x23, release, 0x13))

    def pulse(self, value):
        if value & 0xFFFF00:
            self.pulses.put(value)

    def pulse_now(self, value):
        # Cap the amplifier bytes like the Windows driver: higher is hardware-stress territory
        value = (value & 0xFF) | min((value >> 8) & 0xFF, 0x20) << 8 | min((value >> 16) & 0xFF, 0x40) << 16
        buf = haptic_report(0x53, value, 0x12)
        fcntl.ioctl(self.hid, HIDIOCSOUTPUT(len(buf)), buf)

    def _pulse_worker(self):
        while (value := self.pulses.get()) is not None:
            try:
                self.pulse_now(value)
            except OSError:
                pass


def hid_ids(hid_sysfs):
    with open(os.path.join(hid_sysfs, "uevent")) as f:
        for line in f:
            if line.startswith("HID_ID="):
                return tuple(int(x, 16) for x in line.strip()[7:].split(":"))
    return None


def find_trackpad():
    for hidraw in sorted(glob.glob("/sys/class/hidraw/hidraw*")):
        hid = os.path.realpath(os.path.join(hidraw, "device"))
        if hid_ids(hid) not in SUPPORTED:
            continue
        events = glob.glob(os.path.join(hid, "input", "input*", "event*"))
        if not events:
            continue
        batteries = glob.glob(os.path.join(hid, "power_supply", "*", "capacity"))
        return Trackpad("/dev/" + os.path.basename(hidraw),
                        "/dev/input/" + os.path.basename(events[0]),
                        batteries[0] if batteries else None)
    return None


def key_codes(names):
    codes = []
    for name in names:
        code = ecodes.ecodes.get(name)
        if code is None:
            raise ValueError(f"unknown key name: {name}")
        codes.append(code)
    return codes


class Clicker:
    """Turns the per-frame peak pressure into left clicks and force clicks."""

    IDLE, PENDING, DOWN, FORCED = range(4)

    def __init__(self, daemon):
        self.d = daemon
        self.state = self.IDLE
        self.left = False
        self.since = 0.0         # when the click began
        self.force_since = None  # when pressure first crossed the force threshold
        self.origin = None       # finger position when the click began

    def set_left(self, out, down):
        if self.left != down:
            self.left = down
            out.append((ecodes.EV_KEY, ecodes.BTN_LEFT, int(down)))

    def frame(self, now, peak, pos, out):
        cfg = self.d.cfg
        click, release = feel(cfg)
        c, fc = cfg["click"], cfg["force_click"]
        force_on = fc["enabled"]

        if self.state == self.IDLE:
            if peak >= c["threshold"]:
                self.d.pad.pulse(click)
                self.since, self.origin, self.force_since = now, pos, None
                if force_on and fc["replace_click"]:
                    self.state = self.PENDING
                else:
                    self.state = self.DOWN
                    self.set_left(out, True)
            return

        if peak < c["release"]:
            if self.state == self.PENDING:
                # Quick click that never reached force: deliver it now
                self.set_left(out, True)
                out.append(None)
            self.set_left(out, False)
            self.d.pad.pulse(release)
            self.state = self.IDLE
            return

        if self.state == self.FORCED:
            if peak < fc["release"]:
                self.state = self.DOWN
            return

        if force_on:
            if peak >= fc["threshold"]:
                self.force_since = self.force_since or now
                if (now - self.force_since) * 1000 >= fc["dwell_ms"]:
                    self.state = self.FORCED
                    self.d.pad.pulse(FORCE_PULSE if click & 0xFFFF00 else 0)
                    self.d.force_action()
                    self.d.log(f"force click (pressure {peak})")
                    return
            else:
                self.force_since = None

        if self.state == self.PENDING:
            moved = pos and self.origin and max(abs(pos[0] - self.origin[0]),
                                                abs(pos[1] - self.origin[1])) > fc["pending_motion"]
            if moved or (now - self.since) * 1000 >= fc["pending_ms"]:
                self.state = self.DOWN
                self.set_left(out, True)

    def reset(self, out):
        self.set_left(out, False)
        self.state = self.IDLE


class Daemon:
    def __init__(self):
        self.cfg = load_config()
        self.pad = None
        self.clone = None
        self.actions = None
        self.running = True
        if os.path.exists(SOCKET_PATH):
            os.unlink(SOCKET_PATH)
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        self.sock.bind(SOCKET_PATH)
        os.chmod(SOCKET_PATH, 0o600)

    def log(self, msg):
        print(msg, flush=True)

    # -- device lifecycle -------------------------------------------------

    def setup_actions(self):
        if self.actions:
            self.actions.close()
        self.action = key_codes(self.cfg["force_click"]["action"])
        self.actions = evdev.UInput({ecodes.EV_KEY: self.action}, name="mt2d force click")

    def apply(self):
        click, release = feel(self.cfg)
        # Firmware feel also covers the moments mt2d is not running
        self.pad.set_feel(click, release)
        host = self.cfg["mode"] == "host"
        self.pad.host_click(host)
        if host and not self.clone:
            dev = self.pad.dev
            self.clone = evdev.UInput.from_device(
                dev, name=dev.name, vendor=dev.info.vendor, product=dev.info.product,
                version=dev.info.version, bustype=dev.info.bustype, phys="mt2d",
                input_props=dev.input_props())
            dev.grab()
        elif not host and self.clone:
            self.release_clone()
        self.log(f"mode {self.cfg['mode']}, haptics {self.cfg['haptics']['strength']}"
                 f"{' silent' if self.cfg['haptics'].get('silent') else ''}")

    def release_clone(self):
        if self.clone:
            out = []
            self.clicker.reset(out)
            self.emit(out)
            try:
                self.pad.dev.ungrab()
            except OSError:
                pass
            self.clone.close()
            self.clone = None

    def connect(self):
        self.pad = find_trackpad()
        if not self.pad:
            return False
        self.log(f"connected: {self.pad.dev.name} ({self.pad.hidraw_path}, {self.pad.dev.path})")
        self.clicker = Clicker(self)
        self.pressure, self.pos, self.slot = {}, {}, 0
        try:
            self.apply()
        except OSError as e:
            self.log(f"setup failed: {e}")
            self.pad.close()
            self.pad = None
            return False
        return True

    def disconnect(self):
        self.log("disconnected")
        if self.clone:
            out = []
            self.clicker.reset(out)
            self.emit(out)
            self.clone.close()
            self.clone = None
        self.pad.close()
        self.pad = None

    def shutdown(self):
        if self.pad:
            try:
                self.release_clone()
                self.pad.host_click(False)
            except OSError:
                pass
            self.pad.close()
        self.log("stopped, firmware clicking restored")

    # -- events -----------------------------------------------------------

    def emit(self, events):
        for e in events:
            if e is None:
                self.clone.syn()
            else:
                self.clone.write(*e)

    def force_action(self):
        for code in self.action:
            self.actions.write(ecodes.EV_KEY, code, 1)
        self.actions.syn()
        for code in reversed(self.action):
            self.actions.write(ecodes.EV_KEY, code, 0)
        self.actions.syn()

    def on_event(self, ev):
        if not self.clone:
            return
        if ev.type == ecodes.EV_ABS:
            if ev.code == ecodes.ABS_MT_SLOT:
                self.slot = ev.value
            elif ev.code == ecodes.ABS_MT_PRESSURE:
                self.pressure[self.slot] = ev.value
            elif ev.code == ecodes.ABS_MT_POSITION_X:
                self.pos[self.slot] = (ev.value, self.pos.get(self.slot, (0, 0))[1])
            elif ev.code == ecodes.ABS_MT_POSITION_Y:
                self.pos[self.slot] = (self.pos.get(self.slot, (0, 0))[0], ev.value)
            elif ev.code == ecodes.ABS_MT_TRACKING_ID and ev.value == -1:
                self.pressure.pop(self.slot, None)
                self.pos.pop(self.slot, None)
        elif ev.type == ecodes.EV_KEY and ev.code == ecodes.BTN_LEFT:
            return  # the firmware's own button is ignored in host mode
        elif ev.type == ecodes.EV_SYN and ev.code == ecodes.SYN_REPORT:
            out = []
            peak = max(self.pressure.values(), default=0)
            pos = self.pos.get(min(self.pos)) if self.pos else None
            self.clicker.frame(time.monotonic(), peak, pos, out)
            self.emit(out)
        self.clone.write_event(ev)

    def on_command(self, data, addr):
        try:
            cmd = json.loads(data)
            op = cmd["op"]
            if op == "reload":
                self.cfg = load_config()
                self.setup_actions()
                if self.pad:
                    self.apply()
                reply = {"ok": True}
            elif not self.pad:
                reply = {"ok": False, "error": "trackpad not connected"}
            elif op == "pulse":
                value = cmd.get("value", "medium")
                self.pad.pulse(PULSE[value] if value in PULSE else int(value, 0))
                reply = {"ok": True}
            elif op == "status":
                battery = None
                if self.pad.battery:
                    with open(self.pad.battery) as f:
                        battery = int(f.read())
                reply = {"ok": True, "name": self.pad.dev.name, "battery": battery,
                         "hidraw": self.pad.hidraw_path, "event": self.pad.dev.path,
                         "config": self.cfg}
            else:
                reply = {"ok": False, "error": f"unknown op {op}"}
        except Exception as e:  # never let a bad command kill the daemon
            reply = {"ok": False, "error": str(e)}
        if addr:
            self.sock.sendto(json.dumps(reply).encode(), addr)

    def run(self):
        def stop(*_):
            self.running = False
        signal.signal(signal.SIGTERM, stop)
        signal.signal(signal.SIGINT, stop)
        self.setup_actions()
        self.log(f"mt2d running, control socket {SOCKET_PATH}")
        try:
            while self.running:
                if not self.pad and not self.connect():
                    r = self.wait([self.sock], 2.0)
                    if r:
                        self.on_command(*self.sock.recvfrom(4096))
                    continue
                r = self.wait([self.sock, self.pad.dev.fd], None)
                if self.sock in r:
                    self.on_command(*self.sock.recvfrom(4096))
                if self.pad and self.pad.dev.fd in r:
                    try:
                        for ev in self.pad.dev.read():
                            self.on_event(ev)
                    except OSError as e:
                        if e.errno not in (errno.ENODEV, errno.EIO):
                            raise
                        self.disconnect()
        finally:
            self.shutdown()

    def wait(self, fds, timeout):
        try:
            return select.select(fds, [], [], timeout)[0]
        except InterruptedError:
            return []


def send(cmd):
    client = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    path = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), f"mt2ctl-{os.getpid()}.sock")
    client.bind(path)
    try:
        client.settimeout(3)
        client.sendto(json.dumps(cmd).encode(), SOCKET_PATH)
        reply = json.loads(client.recv(65536))
    except (FileNotFoundError, ConnectionRefusedError):
        sys.exit("mt2d is not running (systemctl --user start mt2d)")
    finally:
        os.unlink(path)
    if not reply.get("ok"):
        sys.exit(reply.get("error"))
    return reply


def restore():
    """Put the firmware back in charge of clicking (used by systemd after a crash)."""
    pad = find_trackpad()
    if pad:
        pad.host_click(False)
        pad.close()


def monitor():
    pad = find_trackpad()
    if not pad:
        sys.exit("trackpad not found")
    print("live peak pressure (only meaningful while mt2d runs in host mode); Ctrl-C to stop")
    pressure, slot = {}, 0
    for ev in pad.dev.read_loop():
        if ev.type == ecodes.EV_ABS and ev.code == ecodes.ABS_MT_SLOT:
            slot = ev.value
        elif ev.type == ecodes.EV_ABS and ev.code == ecodes.ABS_MT_PRESSURE:
            pressure[slot] = ev.value
        elif ev.type == ecodes.EV_ABS and ev.code == ecodes.ABS_MT_TRACKING_ID and ev.value == -1:
            pressure.pop(slot, None)
        elif ev.type == ecodes.EV_SYN:
            peak = max(pressure.values(), default=0)
            print(f"\r{peak:3d} {'#' * (peak * 50 // 253):<50}", end="", flush=True)


def main():
    p = argparse.ArgumentParser(prog="mt2d", description="Magic Trackpad 2 driver")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("daemon", help="run the driver daemon")
    sub.add_parser("status", help="show trackpad and battery state")
    sub.add_parser("reload", help="re-read the config file")
    sub.add_parser("monitor", help="live pressure meter (for tuning thresholds)")
    sub.add_parser("restore", help="give clicking back to the firmware")
    pp = sub.add_parser("pulse", help="fire the haptic actuator once")
    pp.add_argument("value", nargs="?", default="medium",
                    help="weak|medium|strong|max or raw 0xCCBBSS")
    a = p.parse_args()

    if a.cmd == "daemon":
        Daemon().run()
    elif a.cmd == "monitor":
        try:
            monitor()
        except KeyboardInterrupt:
            print()
    elif a.cmd == "restore":
        restore()
    elif a.cmd == "pulse":
        send({"op": "pulse", "value": a.value})
    elif a.cmd == "reload":
        send({"op": "reload"})
    elif a.cmd == "status":
        r = send({"op": "status"})
        print(f"{r['name']}  battery: {r['battery']}%  ({r['hidraw']}, {r['event']})")
        print(json.dumps(r["config"], indent=2))


if __name__ == "__main__":
    main()
