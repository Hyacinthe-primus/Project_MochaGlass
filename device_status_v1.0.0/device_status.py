import json
import os
import shutil
import subprocess
import tempfile
import time
import serial.tools.list_ports

BOARDS = {
    ("1A86", "55D3"): {"name": "ESP32-S3", "icon": "\uec19", "color": "#f9e2af"},
    ("2341", "0043"): {"name": "Arduino Uno", "icon": "\ue266", "color": "#89b4fa"},
}
DEFAULT = {"icon": "\uf2db", "color": "#cdd6f4"}

PHONE_ICONS = {
    "iphone": {"icon": "\uf8ff", "color": "#f38ba8"},
    "android": {"icon": "\ue70e", "color": "#a6e3a1"},
}

DRIVE_ICONS = {
    "usb_drive": {"icon": chr(0xF129F), "color": "#94e2d5"},
    "external_hdd": {"icon": chr(0xF02CA), "color": "#fab387"},
}

_PWSH = shutil.which("pwsh") or shutil.which("powershell") or "powershell"

_PS_SCRIPT = (
    "$phones = Get-PnpDevice -PresentOnly | "
    "Where-Object { $_.Class -in @('WPD','AppleUSB') } | "
    "Select-Object FriendlyName, Class, InstanceId; "
    "$drives = Get-CimInstance Win32_DiskDrive | "
    "Where-Object { $_.InterfaceType -eq 'USB' } | ForEach-Object { "
    "  $disk = $_; "
    "  Get-Partition -DiskNumber $disk.Index -ErrorAction SilentlyContinue | "
    "  Where-Object DriveLetter | ForEach-Object { "
    "    $vol = Get-Volume -DriveLetter $_.DriveLetter -ErrorAction SilentlyContinue; "
    "    [PSCustomObject]@{ "
    "      DriveLetter = $_.DriveLetter; "
    "      Label = $vol.FileSystemLabel; "
    "      SizeGB = [math]::Round($disk.Size/1GB,1); "
    "      MediaType = $disk.MediaType; "
    "      Model = $disk.Model "
    "    } "
    "  } "
    "}; "
    "@{ phones = $phones; drives = $drives } | ConvertTo-Json -Compress -Depth 4"
)

EXTRAS_CACHE_PATH = os.path.join(tempfile.gettempdir(), "device_status_extras_cache.json")
EXTRAS_INTERVAL_SECONDS = 10

_STARTF_FORCEOFFFEEDBACK = 0x00000080


def resolve(p):
    vid = f"{p.vid:04X}" if p.vid else None
    pid = f"{p.pid:04X}" if p.pid else None
    known = BOARDS.get((vid, pid))
    name = known["name"] if known else (p.product or p.description or "Unknown board")
    icon = known["icon"] if known else DEFAULT["icon"]
    color = known["color"] if known else DEFAULT["color"]
    return {
        "port": p.device, "name": name, "icon": icon, "color": color,
        "vid": vid or "?", "pid": pid or "?",
        "manufacturer": p.manufacturer or "?", "description": p.description or "?",
    }


def _classify_phone(friendly_name, pnp_class):
    name = friendly_name or ""
    if "iphone" in name.lower() or "apple" in name.lower() or pnp_class == "AppleUSB":
        return "iphone"
    return "android"


def _extract_vid_pid(instance_id):
    vid = pid = "?"
    for part in instance_id.split("\\"):
        if part.startswith("VID_"):
            for seg in part.split("&"):
                if seg.startswith("VID_"):
                    vid = seg[4:]
                elif seg.startswith("PID_"):
                    pid = seg[4:]
    return vid, pid


def _classify_drive(media_type):
    if media_type and "removable" in media_type.lower():
        return "usb_drive"
    return "external_hdd"


def _quiet_startupinfo():
    si = subprocess.STARTUPINFO()
    si.dwFlags |= subprocess.STARTF_USESHOWWINDOW | _STARTF_FORCEOFFFEEDBACK
    si.wShowWindow = subprocess.SW_HIDE
    return si


def detect_usb_extras():
    try:
        result = subprocess.run(
            [_PWSH, "-NoProfile", "-NonInteractive", "-Command", _PS_SCRIPT],
            capture_output=True, text=True, timeout=5,
            creationflags=subprocess.CREATE_NO_WINDOW,
            startupinfo=_quiet_startupinfo(),
        )
    except (OSError, subprocess.TimeoutExpired):
        return []

    raw = result.stdout.strip()
    if not raw:
        return []

    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return []

    if not isinstance(data, dict):
        return []

    devices = []

    drive_entries = data.get("drives") or []
    if isinstance(drive_entries, dict):
        drive_entries = [drive_entries]
    drive_names = set()
    for entry in drive_entries:
        letter = entry.get("DriveLetter") or "?"
        label = entry.get("Label") or entry.get("Model") or "USB Drive"
        media_type = entry.get("MediaType") or ""
        style = DRIVE_ICONS[_classify_drive(media_type)]
        size_gb = entry.get("SizeGB")
        size_str = f"{size_gb} GB" if size_gb is not None else "?"
        devices.append({
            "port": f"{letter}:",
            "name": label,
            "icon": style["icon"],
            "color": style["color"],
            "vid": size_str, "pid": "USB",
            "manufacturer": "?", "description": media_type or "?",
        })
        drive_names.add(label.strip().lower())

    phone_entries = data.get("phones") or []
    if isinstance(phone_entries, dict):
        phone_entries = [phone_entries]
    for entry in phone_entries:
        friendly_name = entry.get("FriendlyName") or "Unknown device"
        if friendly_name.strip().lower() in drive_names:
            continue  # composite bootable USB media, already counted as a drive
        pnp_class = entry.get("Class")
        style = PHONE_ICONS[_classify_phone(friendly_name, pnp_class)]
        vid, pid = _extract_vid_pid(entry.get("InstanceId", ""))
        devices.append({
            "port": "",
            "name": friendly_name,
            "icon": style["icon"],
            "color": style["color"],
            "vid": vid, "pid": pid,
            "manufacturer": "?", "description": pnp_class or "?",
        })

    return devices


def get_usb_extras_throttled():
    now = time.time()
    try:
        with open(EXTRAS_CACHE_PATH, "r", encoding="utf-8") as f:
            cached = json.load(f)
        if now - cached.get("timestamp", 0) < EXTRAS_INTERVAL_SECONDS:
            return cached["devices"]
    except (OSError, json.JSONDecodeError, KeyError):
        pass

    devices = detect_usb_extras()
    try:
        with open(EXTRAS_CACHE_PATH, "w", encoding="utf-8") as f:
            json.dump({"timestamp": now, "devices": devices}, f)
    except OSError:
        pass

    return devices


def main():
    devices = [resolve(p) for p in serial.tools.list_ports.comports()]
    devices += get_usb_extras_throttled()

    if not devices:
        out = {"compact": "No device", "count": 0, "tooltip": "No device detected"}
    else:
        def label(d):
            return f"{d['name']} ({d['port']})" if d['port'] else d['name']

        compact = " • ".join(
            f"<span style='color:{d['color']}'>{d['icon']} {label(d)}</span>"
            for d in devices
        )
        tooltip = "\n\n".join(
            f"{label(d)}\n"
            f"  Manufacturer : {d['manufacturer']}\n"
            f"  VID:PID   : {d['vid']}:{d['pid']}\n"
            f"  Description : {d['description']}"
            for d in devices
        )
        out = {"compact": compact, "count": len(devices), "tooltip": tooltip}

    print(json.dumps(out))


if __name__ == "__main__":
    main()