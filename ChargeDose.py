import psutil
import threading
import time
from plyer import notification
from pystray import Icon, MenuItem, Menu
from PIL import Image
import sys
import os
import platform

# Windows-only imports
if platform.system() == "Windows":
    import ctypes
    import winsound

# Constants
CHECK_INTERVAL = 60  # seconds
CHARGE_THRESHOLD = 80
LOW_BATTERY_THRESHOLD = 20

# Base path for asset loading (compatible with PyInstaller)
if getattr(sys, 'frozen', False):
    BASE_DIR = sys._MEIPASS  # PyInstaller temp folder
else:
    BASE_DIR = os.path.dirname(os.path.abspath(__file__))

ICON_PATH = os.path.join(BASE_DIR, "chargedose.ico")
SOUND_PATH = os.path.join(BASE_DIR, "chargedose.wav")

def get_battery_percent():
    battery = psutil.sensors_battery()
    if battery is None:
        return -1
    return battery.percent

def emoji_for(percent):
    if percent >= 80:
        return "🟢"
    elif percent >= 30:
        return "🟡"
    else:
        return "🔴"

def create_image():
    return Image.open(ICON_PATH)

def show_notification(title, message):
    if platform.system() == "Windows":
        # Play the sound asynchronously
        winsound.PlaySound(SOUND_PATH, winsound.SND_FILENAME | winsound.SND_ASYNC)

        # Show blocking MessageBox
        MB_ICONWARNING = 0x30
        ctypes.windll.user32.MessageBoxW(0, message, title, MB_ICONWARNING)

        # Stop the sound immediately after MessageBox is closed
        winsound.PlaySound(None, winsound.SND_PURGE)
    else:
        # For Linux/macOS
        notification.notify(title=title, message=message, timeout=10)

def monitor_battery():
    last_status = None  # To avoid repeated notifications
    while True:
        percent = get_battery_percent()
        icon.battery_percent = percent
        icon.icon = create_image()
        icon.title = f"{emoji_for(percent)}  {percent}%"

        if percent != -1:
            if percent <= LOW_BATTERY_THRESHOLD and last_status != 'low':
                show_notification("ChargeDose Alert", f"⚠️ Battery is dying: {percent}% — Plug In Charger!")
                last_status = 'low'
            elif percent >= CHARGE_THRESHOLD and last_status != 'high':
                show_notification("ChargeDose Alert", f"⚠️ Battery high: {percent}% — Unplug Charger!")
                last_status = 'high'
            elif LOW_BATTERY_THRESHOLD < percent < CHARGE_THRESHOLD:
                last_status = 'normal'

        time.sleep(CHECK_INTERVAL)

def on_exit(icon, item):
    icon.stop()
    sys.exit()

# Initialize tray icon
icon = Icon("ChargeDose")
icon.battery_percent = get_battery_percent()
icon.icon = create_image()
icon.title = "ChargeDose"

# Tray menu (only Exit)
icon.menu = Menu(
    MenuItem("Exit", on_exit)
)

# Start monitoring thread
monitor_thread = threading.Thread(target=monitor_battery, daemon=True)
monitor_thread.start()

# Run tray icon loop
try:
    icon.run()
except KeyboardInterrupt:
    print("ChargeDose exited by user (Ctrl+C).")
    sys.exit()
