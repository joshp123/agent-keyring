"""Capture the Mac design screens on the Mac mini.

Written by AI on 2026.10.31 by model Claude Opus 5.5.

Runs on the MacBook and shows nothing there. Copies the design gallery to the
mini, shows each screen there, and screenshots it over Screen Sharing (VNC).
Unlocks the mini's screen first if needed, by typing its login password over
Screen Sharing. Reads that password from stdin. script/capture_mac_design_screens.sh is the entry
point.

usage: python3 capture_mac_design_screens.py GALLERY_APP OUT_DIR [SCREEN ...]
"""
import os
import subprocess
import sys
import time

from vncdotool import api

MINI = "mac-mini::5900"
USER = "josh"
PASSWORD_FIELD = (960, 980)  # the mini's 1920x1080 lock screen
REMOTE_DIR = "/tmp/agent-keyring-design-gallery"
MARGIN = 28  # room for the window shadow
SCREENS = ["approval", "approvalReply", "approvalApproved", "approvalDenied", "approvalAgentProcess",
           "menuBar", "menuBarQuiet", "rules", "rulesAll", "rulesConfirm"]


def ssh(command):
    return subprocess.run(["ssh", "-o", "ConnectTimeout=15", "mac-mini", command],
                          capture_output=True, text=True, check=True).stdout


def locked():
    ioreg = ssh("ioreg -n Root -d1 -a")
    marker = ioreg.find("CGSSessionScreenIsLocked")
    return marker != -1 and "<true/>" in ioreg[marker:marker + 80]


def unlock(client, password):
    client.keyPress("shift")
    time.sleep(2)
    client.mouseMove(*PASSWORD_FIELD)
    client.mousePress(1)
    time.sleep(1)
    client.keyPress("super-a")
    client.keyPress("bsp")
    for character in password:
        client.keyPress(character)
    client.keyPress("enter")
    time.sleep(4)


def capture(client, app, screen, appearance, out_dir):
    frame_file = f"{REMOTE_DIR}/frame.txt"
    ssh(f"rm -f {frame_file}; open -n --stdout {frame_file} {app} --args {screen} {appearance}")
    frame = None
    for _ in range(40):
        time.sleep(0.25)
        text = ssh(f"cat {frame_file} 2>/dev/null || true")
        if text.startswith("FRAME"):
            frame = [int(value) for value in text.split()[1:5]]
            break
    time.sleep(0.6)
    try:
        if frame is None:
            raise RuntimeError(f"{screen}: the gallery never reported its window")
        x, y, width, height = frame
        left, top = max(0, x - MARGIN), max(0, y - MARGIN)
        path = os.path.join(out_dir, f"{screen}-{appearance}.png")
        client.mouseMove(1919, 1079)  # keep the pointer out of the shot
        client.captureRegion(path, left, top, width + 2 * MARGIN, height + 2 * MARGIN)
        print(path, flush=True)
    finally:
        ssh("pkill -f AgentKeyringDesignGallery || true")
        time.sleep(0.5)


def main():
    app, out_dir = sys.argv[1], sys.argv[2]
    screens = sys.argv[3:] or SCREENS
    password = sys.stdin.read().rstrip("\r\n")
    client = api.connect(MINI, username=USER, password=password, timeout=25)
    was_locked = locked()
    try:
        if was_locked:
            unlock(client, password)
            if locked():
                sys.exit("The mini is still locked after typing the password.")
        for appearance in ["light", "dark"]:
            for screen in screens:
                capture(client, app, screen, appearance, out_dir)
    finally:
        password = None
        client.factory.password = None
        client.disconnect()
        api.shutdown()
        if was_locked:
            # Closing Screen Sharing doesn't relock the mini; sleeping the display does.
            ssh("pmset displaysleepnow")


main()
