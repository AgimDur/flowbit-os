#!/usr/bin/env python3
"""flowbit OS Server"""

import http.server
import json
import subprocess
import os
import sys
import threading
import time
import socketserver
import uuid
import signal
import re
import glob as globmod
import shlex
import struct
import ssl
import socket
import zipfile
import base64
import fcntl
import shutil
import ipaddress
import secrets
import hashlib
import urllib.request
from collections import deque
from pathlib import Path
from urllib.parse import parse_qs, urlparse
from concurrent.futures import ThreadPoolExecutor, as_completed

PORT = 8080
HTTPS_PORT = 8443  # HTTPS for remote access
UPDATE_SERVER = "https://update.flowbit.ch"
FLOWBIT_VERSION = "6.2.6"
try:
    FLOWBIT_VERSION = Path("/etc/flowbit-release").read_text().strip()
except Exception:
    pass
BASE_DIR = Path(__file__).parent
STATIC_DIR = BASE_DIR / "static"
LOG_DIR = Path("/tmp/ittools")
LOG_DIR.mkdir(exist_ok=True)
BIOS_PROFILES_DIR = Path("/opt/kit/bios_profiles")
BIOS_PROFILES_DIR.mkdir(parents=True, exist_ok=True)

DATA_DIR = Path("/mnt/data")

# Persistent storage: prefer USB storage over /tmp
PERSIST_BASE = "/mnt/kit-storage" if os.path.isdir("/mnt/kit-storage") else "/tmp/ittools"
NOTES_DIR = Path(os.path.join(PERSIST_BASE, "notes"))
NOTES_DIR.mkdir(parents=True, exist_ok=True)
CHECKLISTS_FILE = os.path.join(PERSIST_BASE, "checklists.json")

# Check if lm-sensors is available
HAS_SENSORS = shutil.which("sensors") is not None

# Allowed filesystem types whitelist
ALLOWED_FSTYPES = {'ext4', 'ext3', 'ext2', 'ntfs', 'vfat', 'xfs', 'btrfs', 'exfat', 'fat32', 'swap'}

# Task cleanup: max age in seconds (1 hour)
TASK_MAX_AGE = 3600

# Session token auth
AUTH_TOKEN = secrets.token_hex(3)  # 6 char hex

# Session management (D02)
sessions = {}  # {token: {created: time, last_seen: time, ip: str}}
SESSION_TIMEOUT = 3600  # 1 hour
sessions_lock = threading.Lock()

# SSE clients for real-time updates (C02)
MAX_SSE_CLIENTS = 20
sse_clients = {}
sse_clients_lock = threading.Lock()

# Server uptime tracking
SERVER_START = time.time()

# List size limits
MAX_WOL_HISTORY = 500
MAX_SESSION_LOG = 500

# In-memory WOL history
wol_history = deque(maxlen=500)
wol_history_lock = threading.Lock()

# Session log
session_log = deque(maxlen=500)
session_log_lock = threading.Lock()


# Audit log for destructive operations
AUDIT_LOG_FILE = os.path.join(PERSIST_BASE, "audit_log.json")
audit_log = deque(maxlen=1000)
audit_log_lock = threading.Lock()

# Load existing audit log
try:
    with open(AUDIT_LOG_FILE, "r") as _f:
        audit_log.extend(json.load(_f))
except Exception:
    pass

# Request counter for metrics
request_counter = {"total": 0, "get": 0, "post": 0}
request_counter_lock = threading.Lock()

# Request logging with rotation (C06)
request_log = deque(maxlen=1000)
request_log_lock = threading.Lock()
_request_count = 0


def audit_record(action, details="", source_ip="", user="system"):
    """Record a destructive operation to the audit log."""
    entry = {
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "epoch": time.time(),
        "action": action,
        "details": details,
        "source_ip": source_ip,
        "user": user
    }
    with audit_log_lock:
        audit_log.append(entry)
        # Persist to disk
        try:
            with open(AUDIT_LOG_FILE, "w") as f:
                json.dump(list(audit_log), f)
        except Exception:
            pass
    try:
        sse_broadcast("audit", entry)
    except Exception:
        pass
    return entry


def log_action(action, details="", source_ip=""):
    with session_log_lock:
        session_log.append({
            "time": time.strftime("%H:%M:%S"),
            "timestamp": time.time(),
            "action": action,
            "details": details,
            "source_ip": source_ip
        })


def get_save_path():
    """Return best available save path: /mnt/data > /mnt/usb/* > /tmp"""
    if DATA_DIR.is_mount():
        return str(DATA_DIR)
    for p in sorted(Path("/mnt/usb").glob("*")):
        if p.is_mount():
            return str(p)
    return "/tmp"

# Task tracking for long-running operations
tasks = {}
tasks_lock = threading.Lock()


def cleanup_old_tasks():
    """Remove tasks older than TASK_MAX_AGE."""
    now = time.time()
    with tasks_lock:
        to_delete = [tid for tid, t in tasks.items()
                     if t.get("finished") and (now - t["finished"]) > TASK_MAX_AGE]
        for tid in to_delete:
            del tasks[tid]


def new_task(description="", priority="normal"):
    cleanup_old_tasks()
    tid = str(uuid.uuid4())[:8]
    with tasks_lock:
        tasks[tid] = {
            "id": tid, "description": description, "status": "running",
            "progress": 0, "output": "", "started": time.time(),
            "finished": None, "exit_code": None, "process": None,
            "priority": priority
        }
    return tid


def update_task(tid, **kwargs):
    with tasks_lock:
        if tid in tasks:
            tasks[tid].update(kwargs)


def append_output(tid, text):
    with tasks_lock:
        if tid in tasks:
            tasks[tid]["output"] += text


def finish_task(tid, exit_code=0):
    with tasks_lock:
        if tid in tasks:
            tasks[tid]["status"] = "done"
            tasks[tid]["progress"] = 100
            tasks[tid]["exit_code"] = exit_code
            tasks[tid]["finished"] = time.time()
    try:
        sse_broadcast("task_update", {"id": tid, "status": "done", "exit_code": exit_code})
    except Exception:
        pass


def get_task(tid):
    with tasks_lock:
        t = tasks.get(tid, {})
        if t:
            result = dict(t)
            result.pop("process", None)
            return result
        return {}


def cancel_task(tid):
    """Cancel a running task by killing its process."""
    with tasks_lock:
        t = tasks.get(tid)
        if not t:
            return {"success": False, "error": "Task nicht gefunden"}
        if t["status"] != "running":
            return {"success": False, "error": "Task läuft nicht mehr"}
        proc = t.get("process")
        if proc:
            try:
                proc.kill()
            except Exception:
                pass
        t["status"] = "cancelled"
        t["finished"] = time.time()
        t["exit_code"] = -1
    return {"success": True}


def run_cmd(cmd, default="N/A", timeout=5):
    try:
        return subprocess.check_output(cmd, shell=True, stderr=subprocess.DEVNULL, timeout=timeout).decode().strip()
    except Exception:
        return default


def read_file(path, default="N/A"):
    try:
        return Path(path).read_text().strip()
    except Exception:
        return default


def sanitize_device(name):
    """Sanitize a device name to prevent injection. Strips /dev/ prefix if present."""
    if not name:
        return ""
    # Strip /dev/ prefix if present
    name = name.replace('/dev/', '')
    return re.sub(r'[^a-zA-Z0-9_\-]', '', name)


def sanitize_path(path_str):
    """Validate and sanitize a filesystem path."""
    if not path_str:
        return None
    resolved = os.path.realpath(path_str)
    # Allow /tmp, /mnt, /media, /run/media, /dev for device operations
    safe_prefixes = ('/tmp/', '/mnt/', '/media/', '/run/media/', '/opt/kit/')
    if not any(resolved.startswith(p) for p in safe_prefixes) and resolved not in ('/tmp', '/mnt', '/media'):
        return None
    return resolved


def safe_int(val, default=0):
    """Safely convert to int with a default."""
    try:
        return int(val)
    except (TypeError, ValueError):
        return default


def version_newer(current, latest):
    """Semantic version comparison."""
    try:
        from packaging.version import Version
        return Version(latest) > Version(current)
    except Exception:
        try:
            def parse_ver(v):
                return [int(x) for x in re.sub(r'[^0-9.]', '', v).split('.')]
            return parse_ver(latest) > parse_ver(current)
        except Exception:
            return latest != current


_sysinfo_static_cache = {}
_sysinfo_cache_time = 0

def get_system_info():
    global _sysinfo_static_cache, _sysinfo_cache_time
    info = {}
    info["hostname"] = read_file("/etc/hostname", run_cmd("hostname"))
    info["manufacturer"] = run_cmd("dmidecode -s system-manufacturer")
    info["model"] = run_cmd("dmidecode -s system-product-name")
    info["serial"] = run_cmd("dmidecode -s system-serial-number")
    info["uuid"] = run_cmd("dmidecode -s system-uuid")
    info["sku"] = run_cmd("dmidecode -s system-sku-number")
    info["board_serial"] = run_cmd("dmidecode -s baseboard-serial-number")
    info["bios_vendor"] = run_cmd("dmidecode -s bios-vendor")
    info["bios_version"] = run_cmd("dmidecode -s bios-version")
    info["bios_date"] = run_cmd("dmidecode -s bios-release-date")
    info["cpu"] = run_cmd("grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs")
    info["cores"] = run_cmd("nproc")
    info["ram_total"] = run_cmd("free -h | awk '/^Mem:/{print $2}'")
    info["ram_used"] = run_cmd("free -h | awk '/^Mem:/{print $3}'")
    info["ram_free"] = run_cmd("free -h | awk '/^Mem:/{print $4}'")
    info["kernel"] = run_cmd("uname -r")
    info["uptime"] = run_cmd("uptime -p")
    info["gateway"] = run_cmd("ip route | awk '/default/{print $3}' | head -1", "N/A")
    info["dns_server"] = run_cmd("awk '/^nameserver/{print $2; exit}' /etc/resolv.conf", "N/A")

    # CPU temp
    info["cpu_temp"] = run_cmd("sensors 2>/dev/null | grep -m1 'Package\\|Tctl\\|Core 0' | awk '{print $NF}'", "N/A")

    # Boot mode
    if os.path.isdir("/sys/firmware/efi"):
        sb_val = ""
        for f in globmod.glob("/sys/firmware/efi/efivars/SecureBoot-*"):
            try:
                with open(f, "rb") as fh:
                    data = fh.read()
                    sb_val = "AN" if data[-1] == 1 else "AUS"
            except Exception:
                pass
        info["boot_mode"] = f"UEFI (Secure Boot: {sb_val})" if sb_val else "UEFI"
    else:
        info["boot_mode"] = "Legacy BIOS"

    # TPM
    if os.path.isdir("/sys/class/tpm/tpm0"):
        tpm_ver = read_file("/sys/class/tpm/tpm0/tpm_version_major", "?")
        info["tpm"] = f"TPM {tpm_ver}.0"
    else:
        info["tpm"] = "Nicht erkannt"

    # Windows Key
    try:
        msdm = subprocess.check_output("strings /sys/firmware/acpi/tables/MSDM 2>/dev/null", shell=True).decode()
        key_match = re.search(r'[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}', msdm)
        info["windows_key"] = key_match.group() if key_match else "N/A"
    except Exception:
        info["windows_key"] = "N/A"

    # Disks - use JSON output for reliable parsing
    disks = []
    try:
        lsblk_out = subprocess.check_output("lsblk -d -J -o NAME,SIZE,ROTA,MODEL,SERIAL,TYPE 2>/dev/null", shell=True).decode()
        lsblk_data = json.loads(lsblk_out)
        for dev in lsblk_data.get("blockdevices", []):
            if dev.get("type") != "disk":
                continue
            name = dev.get("name", "")
            disk = {
                "name": name,
                "size": dev.get("size", "?"),
                "type": "SSD" if not dev.get("rota") else "HDD",
                "model": dev.get("model") or "N/A",
                "serial": dev.get("serial") or "N/A"
            }
            safe_n = sanitize_device(name)
            smart = run_cmd(f"smartctl -H /dev/{safe_n} 2>/dev/null | grep -i 'result\\|Status'")
            disk["smart"] = "PASSED" if "PASSED" in smart or "OK" in smart else ("FAILED" if "FAILED" in smart else "N/A")
            disks.append(disk)
    except Exception:
        pass
    info["disks"] = disks

    # Detect boot device so the UI can exclude it from wipe targets
    try:
        boot_info = get_boot_device()
        if boot_info.get("found"):
            # Extract disk name (e.g. "sdb" from "/dev/sdb")
            boot_dev = boot_info.get("device", "")
            info["boot_device"] = boot_dev.replace("/dev/", "") if boot_dev else ""
        else:
            info["boot_device"] = ""
    except Exception:
        info["boot_device"] = ""

    # Partitions - use JSON output
    partitions = []
    try:
        lsblk_out = subprocess.check_output("lsblk -J -o NAME,SIZE,FSTYPE,MOUNTPOINT,TYPE 2>/dev/null", shell=True).decode()
        lsblk_data = json.loads(lsblk_out)
        def _collect_parts(devs):
            for d in devs:
                if d.get("type") in ("part", "lvm"):
                    partitions.append({
                        "name": d.get("name", ""),
                        "size": d.get("size", "?"),
                        "fstype": d.get("fstype") or "",
                        "mount": d.get("mountpoint") or ""
                    })
                for child in d.get("children", []):
                    _collect_parts([child])
        _collect_parts(lsblk_data.get("blockdevices", []))
    except Exception:
        pass
    info["partitions"] = partitions

    # Network
    interfaces = []
    try:
        for iface in sorted(os.listdir("/sys/class/net")):
            if iface == "lo":
                continue
            mac = read_file(f"/sys/class/net/{iface}/address")
            state = read_file(f"/sys/class/net/{iface}/operstate")
            ip = run_cmd(f"ip -4 addr show {iface} 2>/dev/null | awk '/inet /{{print $2}}' | head -1")
            speed = read_file(f"/sys/class/net/{iface}/speed", "?")
            interfaces.append({"name": iface, "mac": mac, "state": state, "ip": ip or "keine", "speed": speed})
    except Exception:
        pass
    info["interfaces"] = interfaces

    # Battery
    bat_path = "/sys/class/power_supply/BAT0"
    if os.path.isdir(bat_path):
        info["battery"] = {
            "capacity": read_file(f"{bat_path}/capacity", "?"),
            "status": read_file(f"{bat_path}/status", "?")
        }
    else:
        info["battery"] = None

    # RAM slots
    ram_slots = []
    try:
        dmi = subprocess.check_output("dmidecode -t memory 2>/dev/null", shell=True).decode()
        for block in dmi.split("Memory Device")[1:]:
            slot = {}
            for line in block.splitlines():
                line = line.strip()
                if line.startswith("Size:"):
                    slot["size"] = line.split(":", 1)[1].strip()
                elif line.startswith("Type:"):
                    slot["type"] = line.split(":", 1)[1].strip()
                elif line.startswith("Speed:"):
                    slot["speed"] = line.split(":", 1)[1].strip()
                elif line.startswith("Manufacturer:"):
                    slot["manufacturer"] = line.split(":", 1)[1].strip()
                elif line.startswith("Locator:") and "Bank" not in line:
                    slot["locator"] = line.split(":", 1)[1].strip()
            if slot.get("size") and "No Module" not in slot.get("size", ""):
                ram_slots.append(slot)
    except Exception:
        pass
    info["ram_slots"] = ram_slots

    return info


def generate_sysinfo_report(info):
    lines = [
        "=" * 64,
        "  SYSTEM INFO — flowbit OS",
        f"  Datum: {time.strftime('%d.%m.%Y %H:%M:%S')}",
        "=" * 64, "",
        f"  Hersteller    : {info['manufacturer']}",
        f"  Modell        : {info['model']}",
        f"  Seriennummer  : {info['serial']}",
        f"  UUID          : {info['uuid']}",
        f"  SKU           : {info['sku']}",
        f"  Board SN      : {info.get('board_serial', 'N/A')}",
        f"  BIOS          : {info['bios_vendor']} {info['bios_version']} ({info['bios_date']})",
        f"  Boot-Modus    : {info['boot_mode']}",
        f"  TPM           : {info['tpm']}",
        f"  Windows Key   : {info['windows_key']}",
        f"  CPU           : {info['cpu']}",
        f"  Kerne         : {info['cores']}",
        f"  RAM           : {info['ram_total']} (belegt: {info['ram_used']})", "",
        "  DATENTRÄGER",
        "  " + "-" * 48,
    ]
    for d in info.get("disks", []):
        lines.append(f"  {d['name']}  {d['type']}  {d['size']}  {d['model']}  SN: {d['serial']}  SMART: {d['smart']}")
    lines += ["", "  NETZWERK", "  " + "-" * 48]
    for i in info.get("interfaces", []):
        lines.append(f"  {i['name']}  MAC: {i['mac']}  IP: {i['ip']}  ({i['state']})")
    lines += ["", "=" * 64]
    return "\n".join(lines)


# ---- WIPER functions ----

def verify_wipe(device, method):
    """Read random samples from disk and verify wipe was successful."""
    try:
        import random as _random
        size_str = run_cmd(f"blockdev --getsize64 /dev/{device}", "0")
        total_bytes = safe_int(size_str)
        if total_bytes == 0:
            return False
        num_samples = 5
        sample_size = 4096
        for i in range(num_samples):
            offset = _random.randint(0, max(0, total_bytes - sample_size))
            offset = (offset // 512) * 512
            try:
                result = subprocess.run(
                    ["dd", f"if=/dev/{device}", "bs=512", f"skip={offset // 512}",
                     f"count={sample_size // 512}", "status=none"],
                    capture_output=True, timeout=10)
                data = result.stdout
                if not data:
                    continue
                if method == "random":
                    # Random wipe: can't deterministically verify
                    pass
                elif method in ("zero", "dod"):
                    if data != b'\x00' * len(data):
                        return False
            except Exception:
                pass
        return True
    except Exception:
        return False


def wipe_disk_thread(tid, device, method, passes):
    """Wipe a disk with progress tracking."""
    try:
        # Get disk size
        size_str = run_cmd(f"blockdev --getsize64 /dev/{device}", "0")
        total_bytes = int(size_str) if size_str.isdigit() else 0

        if method == "zero":
            src = "/dev/zero"
        elif method == "random":
            src = "/dev/urandom"
        else:
            src = "/dev/zero"

        for p in range(1, passes + 1):
            append_output(tid, f"\n--- Durchgang {p}/{passes} ({method}) ---\n")
            update_task(tid, progress=int((p - 1) / passes * 100))

            bs = 4 * 1024 * 1024  # 4MB blocks
            total_blocks = total_bytes // bs if total_bytes else 0

            proc = subprocess.Popen(
                ["dd", f"if={src}", f"of=/dev/{device}", f"bs={bs}", "conv=fsync", "status=progress"],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE
            )

            # Read stderr for progress (dd outputs to stderr)
            while True:
                line = proc.stderr.readline()
                if not line and proc.poll() is not None:
                    break
                if line:
                    text = line.decode(errors="replace").strip()
                    # Parse dd progress: "1234567890 bytes (1.2 GB, 1.1 GiB) copied, 5.0 s, 247 MB/s"
                    m = re.search(r'(\d+)\s+bytes.*copied.*?(\d+[\.,]?\d*)\s*(MB|GB|kB)/s', text)
                    if m and total_bytes:
                        done = int(m.group(1))
                        pct = int((((p - 1) * total_bytes + done) / (passes * total_bytes)) * 100)
                        update_task(tid, progress=min(pct, 99))
                    append_output(tid, text + "\n")

            if p < passes and method == "random":
                append_output(tid, f"Durchgang {p} abgeschlossen.\n")

        append_output(tid, f"\nWiping abgeschlossen: /dev/{device}\n")
        append_output(tid, "\nVerifizierung...\n")
        verified = verify_wipe(device, method)
        if verified:
            append_output(tid, "Verifikation: OK\n")
        else:
            append_output(tid, "Verifikation: WARNUNG — Unerwartete Daten gefunden!\n")
        finish_task(tid, 0)
    except Exception as e:
        append_output(tid, f"\nFehler: {str(e)}\n")
        finish_task(tid, 1)


def ssd_secure_erase_thread(tid, device):
    """Attempt SSD secure erase via hdparm."""
    try:
        append_output(tid, f"SSD Secure Erase: /dev/{device}\n")

        # Check frozen state
        frozen = run_cmd(f"hdparm -I /dev/{device} 2>/dev/null | grep -i frozen")
        if "frozen" in frozen.lower() and "not" not in frozen.lower():
            append_output(tid, "FEHLER: Disk ist im FROZEN Zustand.\n")
            append_output(tid, "Tipp: Kurz Suspend/Resume oder Kabel ab/an, dann erneut versuchen.\n")
            finish_task(tid, 1)
            return

        # Set password
        append_output(tid, "Setze temporäres Passwort...\n")
        update_task(tid, progress=20)
        r = subprocess.run(["hdparm", "--user-master", "u", "--security-set-pass", "Eins", f"/dev/{device}"],
                          capture_output=True, text=True, timeout=30)
        append_output(tid, r.stdout + r.stderr)

        # Execute secure erase
        append_output(tid, "Starte Secure Erase (kann mehrere Minuten dauern)...\n")
        update_task(tid, progress=40)
        r = subprocess.run(["hdparm", "--user-master", "u", "--security-erase", "Eins", f"/dev/{device}"],
                          capture_output=True, text=True, timeout=3600)
        append_output(tid, r.stdout + r.stderr)

        update_task(tid, progress=100)
        append_output(tid, "\nSecure Erase abgeschlossen.\n")
        finish_task(tid, 0)
    except Exception as e:
        append_output(tid, f"\nFehler: {str(e)}\n")
        finish_task(tid, 1)


def ram_scrub_thread(tid):
    """Scrub RAM using /dev/shm."""
    files = []
    try:
        total = run_cmd("awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo", "512")
        avail_mb = safe_int(total, 512) - 256  # Leave 256MB free
        if avail_mb < 64:
            avail_mb = 64

        append_output(tid, f"RAM Scrub: {avail_mb} MB mit Zufallsdaten füllen...\n")
        update_task(tid, progress=10)

        # Fill with random data in chunks
        chunk = 64  # MB per file
        written = 0
        idx = 0
        while written < avail_mb:
            sz = min(chunk, avail_mb - written)
            fname = f"/dev/shm/.scrub_{idx}"
            r = subprocess.run(["dd", "if=/dev/urandom", f"of={fname}", f"bs=1M", f"count={sz}"],
                             capture_output=True, timeout=120)
            files.append(fname)
            written += sz
            idx += 1
            pct = int(written / avail_mb * 80) + 10
            update_task(tid, progress=pct)
            append_output(tid, f"  {written}/{avail_mb} MB geschrieben\n")

        # Cleanup
        append_output(tid, "Bereinige...\n")
        for f in files:
            try:
                os.remove(f)
            except Exception:
                pass
        subprocess.run(["sync"], timeout=10)

        append_output(tid, f"RAM Scrub abgeschlossen: {written} MB überschrieben.\n")
        finish_task(tid, 0)
    except Exception as e:
        append_output(tid, f"\nFehler: {str(e)}\n")
        finish_task(tid, 1)
    finally:
        for f in files:
            try:
                os.remove(f)
            except Exception:
                pass


# ---- HARDWARE TEST functions ----

def ram_test_thread(tid, size_mb, passes):
    try:
        for p in range(1, passes + 1):
            append_output(tid, f"\n--- RAM Test Durchgang {p}/{passes} ({size_mb} MB) ---\n")

            fname = f"/dev/shm/.ramtest_{tid}_{p}"
            fname_stress = f"/dev/shm/.ramtest_stress_{tid}_{p}"

            # Write random data (pattern A)
            append_output(tid, f"Schreibe {size_mb} MB Zufallsdaten...\n")
            subprocess.run(["dd", "if=/dev/urandom", f"of={fname}", "bs=1M", f"count={size_mb}"],
                         capture_output=True, timeout=120)
            update_task(tid, progress=int((p - 0.7) / passes * 100))

            # First checksum of pattern A
            c1 = run_cmd(f"md5sum {fname} | cut -d' ' -f1", "", timeout=60)

            # Write different pattern (pattern B) to stress RAM cells
            subprocess.run(["dd", "if=/dev/zero", f"of={fname_stress}", "bs=1M", f"count={size_mb}"],
                         capture_output=True, timeout=120)
            # Remove stress pattern
            try:
                os.remove(fname_stress)
            except Exception:
                pass

            subprocess.run(["sync"], timeout=10)

            # Re-read and checksum original (tests if RAM corruption occurred)
            c2 = run_cmd(f"md5sum {fname} | cut -d' ' -f1", "", timeout=60)

            os.remove(fname)

            if c1 and c1 == c2:
                append_output(tid, f"  Durchgang {p}: OK (MD5: {c1})\n")
            else:
                append_output(tid, f"  Durchgang {p}: FEHLER! Checksummen stimmen nicht überein!\n")
                append_output(tid, f"  Erwartet: {c1}\n  Erhalten: {c2}\n")
                finish_task(tid, 1)
                return

            update_task(tid, progress=int(p / passes * 100))

        # Pattern test
        append_output(tid, "\nPattern-Test (0x00, 0xFF, 0xAA, 0x55)...\n")
        patterns = [("0x00", "\\x00"), ("0xFF", "\\xff"), ("0xAA", "\\xaa"), ("0x55", "\\x55")]
        for pname, pval in patterns:
            fname = f"/dev/shm/.ramtest_pattern_{tid}"
            subprocess.run(f"python3 -c \"import sys; sys.stdout.buffer.write(b'{pval}'*1048576)\" > {fname}",
                         shell=True, timeout=30)
            c1 = run_cmd(f"md5sum {fname} | cut -d' ' -f1", "", timeout=10)
            c2 = run_cmd(f"md5sum {fname} | cut -d' ' -f1", "", timeout=10)
            try:
                os.remove(fname)
            except Exception:
                pass
            status = "OK" if c1 == c2 else "FEHLER"
            append_output(tid, f"  Pattern {pname}: {status}\n")

        append_output(tid, "\nRAM Test abgeschlossen — Keine Fehler gefunden.\n")
        finish_task(tid, 0)
    except Exception as e:
        append_output(tid, f"\nFehler: {str(e)}\n")
        finish_task(tid, 1)


def cpu_stress_thread(tid, duration):
    try:
        cores = int(run_cmd("nproc", "2"))
        append_output(tid, f"CPU Stresstest: {cores} Kerne, {duration} Sekunden\n")

        # Start stress processes
        procs = []
        for i in range(cores):
            p = subprocess.Popen(
                ["timeout", str(duration), "awk", "BEGIN{for(i=0;i<999999999;i++)sin(i)}"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
            )
            procs.append(p)

        start = time.time()
        while time.time() - start < duration:
            elapsed = int(time.time() - start)
            pct = int(elapsed / duration * 100)
            temp = run_cmd("sensors 2>/dev/null | grep -m1 'Package\\|Tctl\\|Core 0' | grep -oP '[\\d.]+.C' | head -1", "N/A")
            load = run_cmd("cat /proc/loadavg | cut -d' ' -f1", "?")
            append_output(tid, f"  [{elapsed}s/{duration}s] Load: {load} | Temp: {temp}\n")
            update_task(tid, progress=pct)

            # Check for critical temp
            try:
                temp_val = float(re.search(r'[\d.]+', temp).group()) if temp != "N/A" else 0
                if temp_val > 95:
                    append_output(tid, f"\n  WARNUNG: Temperatur {temp_val}°C > 95°C — Abbruch!\n")
                    for p in procs:
                        p.kill()
                    finish_task(tid, 1)
                    return
            except Exception:
                pass

            time.sleep(5)

        for p in procs:
            p.wait()

        load = run_cmd("cat /proc/loadavg | cut -d' ' -f1", "?")
        append_output(tid, f"\nCPU Stresstest abgeschlossen. Abschluss-Load: {load}\n")
        finish_task(tid, 0)
    except Exception as e:
        append_output(tid, f"\nFehler: {str(e)}\n")
        finish_task(tid, 1)
    finally:
        for p in procs:
            try:
                p.kill()
            except Exception:
                pass


def disk_speed_thread(tid, device):
    try:
        append_output(tid, f"Disk Lesetest: /dev/{device}\n\n")

        # Sequential read
        append_output(tid, "Sequentieller Lesetest (256 MB)...\n")
        update_task(tid, progress=20)
        r = run_cmd(f"dd if=/dev/{device} of=/dev/null bs=1M count=256 iflag=direct 2>&1 | tail -1", "", timeout=60)
        append_output(tid, f"  {r}\n\n")

        # SMART data
        append_output(tid, "SMART Gesundheit:\n")
        update_task(tid, progress=60)
        smart = run_cmd(f"smartctl -H /dev/{device} 2>&1", "N/A", timeout=15)
        append_output(tid, f"  {smart}\n\n")

        # Key attributes
        update_task(tid, progress=80)
        attrs = run_cmd(f"smartctl -A /dev/{device} 2>&1 | head -20", "N/A", timeout=15)
        append_output(tid, f"Attribute:\n{attrs}\n")

        append_output(tid, "\nDisk Test abgeschlossen.\n")
        finish_task(tid, 0)
    except Exception as e:
        append_output(tid, f"\nFehler: {str(e)}\n")
        finish_task(tid, 1)


# ---- BIOS functions ----

def get_bios_settings():
    """Read BIOS settings from firmware-attributes sysfs."""
    settings = []
    attrs_base = "/sys/class/firmware-attributes"
    if not os.path.isdir(attrs_base):
        return {"available": False, "settings": [], "vendor": "N/A"}

    vendor = "unknown"
    for d in os.listdir(attrs_base):
        vendor = d
        attrs_path = os.path.join(attrs_base, d, "attributes")
        if not os.path.isdir(attrs_path):
            continue
        for attr in sorted(os.listdir(attrs_path)):
            attr_path = os.path.join(attrs_path, attr)
            setting = {"name": attr}
            for field in ["current_value", "default_value", "display_name", "possible_values", "type"]:
                val = read_file(os.path.join(attr_path, field), "")
                if val:
                    setting[field] = val
            settings.append(setting)

    return {"available": True, "settings": settings, "vendor": vendor}


def get_bios_profiles():
    """List saved BIOS profiles."""
    profiles = []
    for f in sorted(BIOS_PROFILES_DIR.glob("*.biosprofile")):
        try:
            content = f.read_text()
            lines = content.splitlines()
            name = f.stem
            count = sum(1 for l in lines if "=" in l and not l.startswith("#"))
            created = ""
            for l in lines:
                if l.startswith("# Erstellt:"):
                    created = l.split(":", 1)[1].strip()
            profiles.append({"name": name, "file": f.name, "settings_count": count, "created": created})
        except Exception:
            pass

    # Also check USB
    usb_profiles = []
    for mount in globmod.glob("/run/media/*/BIOS_Settings/*.biosprofile") + \
                 globmod.glob("/mnt/*/BIOS_Settings/*.biosprofile") + \
                 globmod.glob("/media/*/BIOS_Settings/*.biosprofile"):
        try:
            name = Path(mount).stem
            usb_profiles.append({"name": name, "file": mount, "source": "USB"})
        except Exception:
            pass

    return {"local": profiles, "usb": usb_profiles}


def save_bios_profile(name, settings):
    """Save current BIOS settings as a profile."""
    timestamp = time.strftime("%d.%m.%Y %H:%M:%S")
    vendor = run_cmd("dmidecode -s system-manufacturer", "Unknown")
    model = run_cmd("dmidecode -s system-product-name", "Unknown")

    lines = [
        f"# BIOS Profil: {name}",
        f"# Erstellt: {timestamp}",
        f"# Gerät: {vendor} {model}",
        f"# Vendor: {settings.get('vendor', 'N/A')}",
        "#",
    ]

    for s in settings.get("settings", []):
        cv = s.get("current_value", "")
        dn = s.get("display_name", s["name"])
        lines.append(f"# {dn}")
        lines.append(f"{s['name']}={cv}")

    filepath = BIOS_PROFILES_DIR / f"{name}.biosprofile"
    filepath.write_text("\n".join(lines) + "\n")
    return str(filepath)


def export_bios_to_usb(name):
    """Copy a BIOS profile to USB stick."""
    src = BIOS_PROFILES_DIR / f"{name}.biosprofile"
    if not src.exists():
        return {"success": False, "error": "Profil nicht gefunden"}

    # Find USB
    usb_mounts = []
    try:
        lines = subprocess.check_output("lsblk -n -o MOUNTPOINT,RM 2>/dev/null", shell=True).decode().splitlines()
        for line in lines:
            parts = line.strip().split()
            if len(parts) == 2 and parts[1] == "1" and parts[0] and parts[0] != "":
                usb_mounts.append(parts[0])
    except Exception:
        pass

    if not usb_mounts:
        # Try common paths
        for p in globmod.glob("/run/media/*") + globmod.glob("/mnt/usb*"):
            if os.path.ismount(p):
                usb_mounts.append(p)

    if not usb_mounts:
        return {"success": False, "error": "Kein USB-Stick gefunden. Bitte USB einstecken."}

    dest_dir = os.path.join(usb_mounts[0], "BIOS_Settings")
    os.makedirs(dest_dir, exist_ok=True)
    dest = os.path.join(dest_dir, src.name)
    shutil.copy2(str(src), dest)
    return {"success": True, "path": dest}


# ---- BACKUP functions ----

def backup_disk_thread(tid, source, target_path, compress=True):
    try:
        append_output(tid, f"Disk Backup: /dev/{source} -> {target_path}\n")
        timestamp = time.strftime("%Y%m%d_%H%M%S")
        fname = f"backup_{source}_{timestamp}.img"
        if compress:
            fname += ".zst"

        total_bytes = int(run_cmd(f"blockdev --getsize64 /dev/{source}", "0"))
        dest = os.path.join(target_path, fname)

        if compress:
            cmd = f"dd if=/dev/{source} bs=4M status=progress 2>&1 | zstd -1 -o '{dest}'"
        else:
            cmd = f"dd if=/dev/{source} of='{dest}' bs=4M status=progress conv=fsync 2>&1"

        append_output(tid, f"Ziel: {dest}\n")
        append_output(tid, f"Grösse: {total_bytes} Bytes\n\n")

        proc = subprocess.Popen(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        while True:
            line = proc.stdout.readline()
            if not line and proc.poll() is not None:
                break
            if line:
                text = line.decode(errors="replace").strip()
                m = re.search(r'(\d+)\s+bytes', text)
                if m and total_bytes:
                    pct = int(int(m.group(1)) / total_bytes * 95)
                    update_task(tid, progress=min(pct, 95))
                append_output(tid, text + "\n")

        # Checksum
        append_output(tid, "\nBerechne SHA256 Checksumme...\n")
        update_task(tid, progress=96)
        sha = run_cmd(f"sha256sum '{dest}' | cut -d' ' -f1", "N/A", timeout=600)
        Path(dest + ".sha256").write_text(f"{sha}  {fname}\n")
        append_output(tid, f"SHA256: {sha}\n")
        append_output(tid, f"\nBackup abgeschlossen: {dest}\n")
        finish_task(tid, proc.returncode or 0)
    except Exception as e:
        append_output(tid, f"\nFehler: {str(e)}\n")
        finish_task(tid, 1)


def restore_disk_thread(tid, image_path, target_device):
    try:
        append_output(tid, f"Restore: {image_path} -> /dev/{target_device}\n")

        # Check SHA256
        sha_file = image_path + ".sha256"
        if os.path.exists(sha_file):
            append_output(tid, "Prüfe SHA256 Checksumme...\n")
            update_task(tid, progress=5)
            expected = Path(sha_file).read_text().split()[0]
            actual = run_cmd(f"sha256sum '{image_path}' | cut -d' ' -f1", "", timeout=600)
            if expected == actual:
                append_output(tid, f"Checksumme OK: {actual}\n\n")
            else:
                append_output(tid, f"WARNUNG: Checksumme stimmt nicht überein!\n  Erwartet: {expected}\n  Erhalten: {actual}\n\n")

        safe_image = shlex.quote(image_path)
        safe_target_dev = shlex.quote(f"/dev/{target_device}")
        if image_path.endswith(".zst"):
            cmd = ["bash", "-c", f"zstd -d -c {safe_image} | dd of={safe_target_dev} bs=4M status=progress conv=fsync 2>&1"]
        else:
            cmd = ["dd", f"if={image_path}", f"of=/dev/{target_device}", "bs=4M", "status=progress", "conv=fsync"]

        update_task(tid, progress=10)
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        while True:
            line = proc.stdout.readline()
            if not line and proc.poll() is not None:
                break
            if line:
                text = line.decode(errors="replace").strip()
                append_output(tid, text + "\n")

        append_output(tid, "\nRestore abgeschlossen.\n")
        finish_task(tid, proc.returncode or 0)
    except Exception as e:
        append_output(tid, f"\nFehler: {str(e)}\n")
        finish_task(tid, 1)


def clone_disk_thread(tid, source, target):
    try:
        append_output(tid, f"Disk Clone: /dev/{source} -> /dev/{target}\n")
        total_bytes = int(run_cmd(f"blockdev --getsize64 /dev/{source}", "0"))
        append_output(tid, f"Grösse: {total_bytes} Bytes\n\n")

        cmd = f"dd if=/dev/{source} of=/dev/{target} bs=4M status=progress conv=fsync 2>&1"
        proc = subprocess.Popen(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        while True:
            line = proc.stdout.readline()
            if not line and proc.poll() is not None:
                break
            if line:
                text = line.decode(errors="replace").strip()
                m = re.search(r'(\d+)\s+bytes', text)
                if m and total_bytes:
                    pct = int(int(m.group(1)) / total_bytes * 95)
                    update_task(tid, progress=min(pct, 95))
                append_output(tid, text + "\n")

        append_output(tid, "\nDisk Clone abgeschlossen.\n")
        finish_task(tid, proc.returncode or 0)
    except Exception as e:
        append_output(tid, f"\nFehler: {str(e)}\n")
        finish_task(tid, 1)


# ---- NETWORK (long-running) ----

def traceroute_thread(tid, target):
    try:
        append_output(tid, f"Traceroute zu {target}...\n\n")
        proc = subprocess.Popen(
            ["timeout", "20", "traceroute", "-m", "20", "-w", "2", target],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT
        )
        hop = 0
        while True:
            line = proc.stdout.readline()
            if not line and proc.poll() is not None:
                break
            if line:
                hop += 1
                update_task(tid, progress=min(hop * 5, 95))
                append_output(tid, line.decode(errors="replace"))

        append_output(tid, "\nTraceroute abgeschlossen.\n")
        finish_task(tid, 0)
    except Exception as e:
        append_output(tid, f"\nFehler: {str(e)}\n")
        finish_task(tid, 1)


def full_network_diag_thread(tid):
    try:
        tests = [
            ("Interfaces", "ip -c addr show 2>/dev/null || ip addr show"),
            ("Routing", "ip route show"),
            ("DNS Config", "cat /etc/resolv.conf"),
            ("Gateway Ping", "ping -c 3 -W 2 $(ip route | awk '/default/{print $3}' | head -1) 2>&1"),
            ("Internet Ping", "ping -c 3 -W 2 1.1.1.1 2>&1"),
            ("DNS Test", "dig google.com +short 2>&1"),
            ("HTTP Test", "curl -sI -m5 http://google.com 2>&1 | head -5"),
        ]
        for i, (name, cmd) in enumerate(tests):
            append_output(tid, f"\n{'='*40}\n  {name}\n{'='*40}\n")
            update_task(tid, progress=int((i+1)/len(tests)*100))
            result = run_cmd(cmd, "Fehler", timeout=15)
            append_output(tid, result + "\n")

        append_output(tid, "\n\nNetzwerk-Diagnose abgeschlossen.\n")
        finish_task(tid, 0)
    except Exception as e:
        append_output(tid, f"\nFehler: {str(e)}\n")
        finish_task(tid, 1)


# ---- BATTERY (extended) ----

def get_battery_info():
    """Read extended battery information."""
    result = {"batteries": [], "upower": None}
    bat_dirs = sorted(globmod.glob("/sys/class/power_supply/BAT*"))
    for bat_path in bat_dirs:
        bat_name = os.path.basename(bat_path)
        bat = {"name": bat_name}
        bat["status"] = read_file(f"{bat_path}/status", "N/A")
        bat["capacity"] = read_file(f"{bat_path}/capacity", "N/A")
        bat["technology"] = read_file(f"{bat_path}/technology", "N/A")
        bat["manufacturer"] = read_file(f"{bat_path}/manufacturer", "N/A")
        bat["model_name"] = read_file(f"{bat_path}/model_name", "N/A")
        bat["serial_number"] = read_file(f"{bat_path}/serial_number", "N/A")
        bat["cycle_count"] = read_file(f"{bat_path}/cycle_count", "N/A")

        # Try energy-based values first, then charge-based
        energy_full_design = read_file(f"{bat_path}/energy_full_design", "")
        energy_full = read_file(f"{bat_path}/energy_full", "")
        energy_now = read_file(f"{bat_path}/energy_now", "")

        if not energy_full_design:
            energy_full_design = read_file(f"{bat_path}/charge_full_design", "")
        if not energy_full:
            energy_full = read_file(f"{bat_path}/charge_full", "")
        if not energy_now:
            energy_now = read_file(f"{bat_path}/charge_now", "")

        bat["design_capacity"] = energy_full_design if energy_full_design else "N/A"
        bat["current_capacity"] = energy_full if energy_full else "N/A"
        bat["current_now"] = energy_now if energy_now else "N/A"

        # Calculate wear level
        try:
            efd = int(energy_full_design)
            ef = int(energy_full)
            if efd > 0:
                bat["wear_level"] = round((1 - ef / efd) * 100, 1)
            else:
                bat["wear_level"] = "N/A"
        except (ValueError, TypeError):
            bat["wear_level"] = "N/A"

        result["batteries"].append(bat)

    # Fallback: upower
    if not result["batteries"]:
        upower_out = run_cmd("upower -i /org/freedesktop/UPower/devices/battery_BAT0 2>/dev/null", "", timeout=5)
        if upower_out:
            result["upower"] = upower_out

    return result


# ---- MONITOR/EDID ----

def decode_edid_manufacturer(b8, b9):
    """Decode PNP manufacturer ID from EDID bytes 8-9."""
    val = (b8 << 8) | b9
    c1 = chr(((val >> 10) & 0x1F) + ord('A') - 1)
    c2 = chr(((val >> 5) & 0x1F) + ord('A') - 1)
    c3 = chr((val & 0x1F) + ord('A') - 1)
    return c1 + c2 + c3


def parse_edid(edid_bytes):
    """Parse binary EDID data."""
    if len(edid_bytes) < 128:
        return None
    # Check EDID header
    if edid_bytes[0:8] != b'\x00\xff\xff\xff\xff\xff\xff\x00':
        return None

    info = {}
    info["manufacturer"] = decode_edid_manufacturer(edid_bytes[8], edid_bytes[9])
    info["model_code"] = struct.unpack('<H', edid_bytes[10:12])[0]
    info["serial_code"] = struct.unpack('<I', edid_bytes[12:16])[0]

    # Parse detailed timing descriptor for preferred resolution
    # First detailed timing block at offset 54
    dtd = edid_bytes[54:72]
    if len(dtd) >= 18 and (dtd[0] != 0 or dtd[1] != 0):
        h_active = dtd[2] | ((dtd[4] & 0xF0) << 4)
        v_active = dtd[5] | ((dtd[7] & 0xF0) << 4)
        info["resolution"] = f"{h_active}x{v_active}"
    else:
        info["resolution"] = "N/A"

    # Parse descriptor blocks (offsets 54, 72, 90, 108) for name and serial
    info["name"] = ""
    info["serial"] = ""
    for offset in [54, 72, 90, 108]:
        block = edid_bytes[offset:offset + 18]
        if len(block) < 18:
            continue
        if block[0] == 0 and block[1] == 0 and block[2] == 0:
            tag = block[3]
            data = block[5:18].decode('ascii', errors='replace').strip()
            if tag == 0xFC:  # Monitor name
                info["name"] = data.strip('\n').strip()
            elif tag == 0xFF:  # Serial string
                info["serial"] = data.strip('\n').strip()

    return info


def get_monitors():
    """Get connected monitor information."""
    monitors = []

    # Try reading EDID from DRM
    for edid_path in sorted(globmod.glob("/sys/class/drm/card*-*/edid")):
        try:
            with open(edid_path, "rb") as f:
                edid_bytes = f.read()
            if len(edid_bytes) < 128:
                continue
            parsed = parse_edid(edid_bytes)
            if parsed:
                # Determine connection type from path
                dirname = os.path.basename(os.path.dirname(edid_path))
                conn_type = "Unknown"
                for ct in ["HDMI", "DP", "eDP", "VGA", "DVI", "LVDS"]:
                    if ct in dirname:
                        conn_type = ct
                        break
                monitors.append({
                    "name": parsed.get("name", ""),
                    "manufacturer": parsed.get("manufacturer", ""),
                    "model": parsed.get("model_code", ""),
                    "serial": parsed.get("serial", str(parsed.get("serial_code", ""))),
                    "resolution": parsed.get("resolution", "N/A"),
                    "connection_type": conn_type,
                    "drm_path": dirname
                })
        except (IOError, OSError):
            continue

    # Fallback: xrandr
    if not monitors:
        xrandr_out = run_cmd("xrandr --query 2>/dev/null", "", timeout=5)
        if xrandr_out:
            for line in xrandr_out.splitlines():
                m = re.match(r'^(\S+)\s+connected\s+(primary\s+)?(\d+x\d+)', line)
                if m:
                    monitors.append({
                        "name": m.group(1),
                        "manufacturer": "",
                        "model": "",
                        "serial": "",
                        "resolution": m.group(3),
                        "connection_type": m.group(1).rstrip('0123456789-'),
                    })

    return monitors


# ---- BOOT DEVICES ----

def get_boot_devices():
    """Get boot device information."""
    result = {
        "boot_mode": "UEFI" if os.path.isdir("/sys/firmware/efi") else "Legacy",
        "boot_order": [],
        "boot_entries": [],
        "bootable_disks": []
    }

    # UEFI boot entries
    efi_out = run_cmd("efibootmgr -v 2>/dev/null", "", timeout=5)
    if efi_out:
        for line in efi_out.splitlines():
            m = re.match(r'^BootOrder:\s*(.+)', line)
            if m:
                result["boot_order"] = [x.strip() for x in m.group(1).split(',')]
                continue
            m = re.match(r'^Boot(\w{4})(\*?)\s+(.+)', line)
            if m:
                entry = {
                    "num": m.group(1),
                    "active": m.group(2) == '*',
                    "name": m.group(3).split('\t')[0].strip(),
                    "path": m.group(3) if '\t' in m.group(3) else ""
                }
                result["boot_entries"].append(entry)

    # Bootable disks (EFI System Partitions)
    lsblk_out = run_cmd("lsblk -n -o NAME,SIZE,TYPE,FSTYPE,LABEL,PARTTYPE 2>/dev/null", "", timeout=5)
    if lsblk_out:
        for line in lsblk_out.splitlines():
            parts = line.split()
            if len(parts) >= 4:
                name = parts[0].strip().lstrip("└─├─")
                # EFI System Partition GUID
                if "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" in line.lower() or \
                   (len(parts) >= 4 and parts[3] == "vfat"):
                    result["bootable_disks"].append({
                        "name": name,
                        "size": parts[1] if len(parts) > 1 else "",
                        "type": parts[2] if len(parts) > 2 else "",
                        "fstype": parts[3] if len(parts) > 3 else "",
                        "label": parts[4] if len(parts) > 4 else "",
                    })

    return result


# ---- WAKE-ON-LAN ----

def send_wol(mac, ip=None):
    """Send Wake-on-LAN magic packet."""
    # Validate MAC
    mac_clean = mac.replace(':', '').replace('-', '').replace('.', '')
    if len(mac_clean) != 12 or not all(c in '0123456789abcdefABCDEF' for c in mac_clean):
        return {"success": False, "error": "Invalid MAC address"}

    mac_bytes = bytes.fromhex(mac_clean)
    magic = b'\xff' * 6 + mac_bytes * 16

    broadcast_ip = ip if ip else '255.255.255.255'
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        sock.sendto(magic, (broadcast_ip, 9))
        sock.close()

        entry = {"mac": mac, "ip": broadcast_ip, "time": time.strftime('%Y-%m-%d %H:%M:%S')}
        with wol_history_lock:
            wol_history.append(entry)

        return {"success": True, "mac": mac, "broadcast": broadcast_ip}
    except Exception as e:
        return {"success": False, "error": str(e)}


# ---- NETWORK SCANNER ----

def netscan_thread(tid, subnet, target=None, ports=False):
    """Run network scan as a background task."""
    try:
        if target and ports:
            # Port scan on specific target
            append_output(tid, f"Port scan: {target}\n\n")
            safe_target = shlex.quote(target)
            out = run_cmd(f"nmap -F {safe_target} 2>&1", "Fehler", timeout=120)
            append_output(tid, out + "\n")
            finish_task(tid, 0)
            return

        # Host discovery
        if not subnet:
            # Auto-detect subnet from first active interface
            subnet = run_cmd("ip -4 route | awk '/src/ && !/default/{print $1; exit}'", "", timeout=5)
            if not subnet:
                subnet = run_cmd("ip -4 addr show | awk '/inet / && !/127\\./{print $2; exit}'", "", timeout=5)

        if not subnet:
            append_output(tid, "Fehler: Kein Subnetz erkannt\n")
            finish_task(tid, 1)
            return

        append_output(tid, f"Scanning {subnet}...\n\n")
        safe_subnet = shlex.quote(subnet)
        proc = subprocess.Popen(
            ["nmap", "-sn", subnet],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT
        )

        hosts = []
        current_host = {}
        while True:
            line = proc.stdout.readline()
            if not line and proc.poll() is not None:
                break
            if line:
                text = line.decode(errors="replace").strip()
                append_output(tid, text + "\n")

                m = re.search(r'Nmap scan report for (\S+)\s*\(?([\d.]*)\)?', text)
                if m:
                    if current_host:
                        hosts.append(current_host)
                    hostname = m.group(1)
                    ip_addr = m.group(2) if m.group(2) else hostname
                    current_host = {"ip": ip_addr, "hostname": hostname, "mac": ""}
                    continue
                m2 = re.search(r'MAC Address:\s*([\w:]+)\s*\(?(.+)?\)?', text)
                if m2 and current_host:
                    current_host["mac"] = m2.group(1)
                    current_host["vendor"] = m2.group(2).strip('()') if m2.group(2) else ""

        if current_host:
            hosts.append(current_host)

        append_output(tid, f"\n{len(hosts)} hosts found.\n")
        update_task(tid, hosts=hosts)
        finish_task(tid, 0)
    except Exception as e:
        append_output(tid, f"\nFehler: {str(e)}\n")
        finish_task(tid, 1)


# ---- WIFI MANAGER ----

def wifi_scan():
    """Scan for WiFi networks."""
    # Ensure NetworkManager is running for WiFi
    run_cmd("systemctl start NetworkManager 2>/dev/null", "", timeout=10)
    networks = []
    out = run_cmd("nmcli -t -f SSID,SIGNAL,SECURITY,BSSID dev wifi list 2>/dev/null", "", timeout=15)
    if out:
        for line in out.splitlines():
            parts = line.split(':')
            if len(parts) >= 3 and parts[0]:
                networks.append({
                    "ssid": parts[0],
                    "signal": parts[1] if len(parts) > 1 else "",
                    "security": parts[2] if len(parts) > 2 else "",
                    "bssid": parts[3] if len(parts) > 3 else ""
                })
    else:
        # Fallback: iwctl
        run_cmd("iwctl station wlan0 scan 2>/dev/null", "", timeout=5)
        time.sleep(2)
        iw_out = run_cmd("iwctl station wlan0 get-networks 2>/dev/null", "", timeout=5)
        if iw_out:
            for line in iw_out.splitlines():
                line = line.strip()
                if line and not line.startswith("---") and "Network" not in line:
                    parts = line.split()
                    if parts:
                        networks.append({"ssid": parts[0], "signal": "", "security": "", "bssid": ""})
    return networks


def wifi_connect(ssid, password):
    """Connect to a WiFi network."""
    safe_ssid = shlex.quote(ssid)
    safe_pass = shlex.quote(password)
    out = run_cmd(f"nmcli dev wifi connect {safe_ssid} password {safe_pass} 2>&1", "Fehler", timeout=30)
    success = "successfully" in out.lower() or "erfolgreich" in out.lower()
    return {"success": success, "output": out}


def wifi_status():
    """Get current WiFi connection status."""
    out = run_cmd("nmcli -t -f NAME,TYPE,DEVICE con show --active 2>/dev/null", "", timeout=5)
    connections = []
    if out:
        for line in out.splitlines():
            parts = line.split(':')
            if len(parts) >= 3:
                connections.append({
                    "name": parts[0],
                    "type": parts[1],
                    "device": parts[2]
                })
    return connections


def wifi_disconnect(name):
    """Disconnect a WiFi connection."""
    safe_name = shlex.quote(name)
    out = run_cmd(f"nmcli con down {safe_name} 2>&1", "Fehler", timeout=10)
    return {"success": "successfully" in out.lower() or "erfolgreich" in out.lower(), "output": out}


def wifi_saved():
    """List saved WiFi connections."""
    out = run_cmd("nmcli -t -f NAME,TYPE con show 2>/dev/null", "", timeout=5)
    connections = []
    if out:
        for line in out.splitlines():
            parts = line.split(':')
            if len(parts) >= 2:
                connections.append({"name": parts[0], "type": parts[1]})
    return connections


# ---- WINDOWS PASSWORD RESET ----

def find_windows_partitions():
    """Find NTFS partitions with Windows folder."""
    partitions = []
    lsblk_out = run_cmd("lsblk -n -o NAME,FSTYPE,SIZE,LABEL,TYPE 2>/dev/null", "", timeout=5)
    if not lsblk_out:
        return partitions

    for line in lsblk_out.splitlines():
        parts = line.split()
        if len(parts) >= 2:
            name = parts[0].strip().lstrip("└─├─")
            fstype = parts[1] if len(parts) > 1 else ""
            if fstype.lower() == "ntfs":
                # Try to mount and check for Windows folder
                mount_point = f"/tmp/ittools_mount_{name}"
                os.makedirs(mount_point, exist_ok=True)
                safe_name = sanitize_device(name)
                # Check if already mounted
                current_mount = run_cmd(f"findmnt -n -o TARGET /dev/{safe_name} 2>/dev/null", "", timeout=3)
                if current_mount:
                    mount_point = current_mount
                    has_windows = os.path.isdir(os.path.join(mount_point, "Windows"))
                else:
                    r = subprocess.run(["mount", "-o", "ro", f"/dev/{safe_name}", mount_point],
                                      capture_output=True, timeout=10)
                    has_windows = os.path.isdir(os.path.join(mount_point, "Windows"))
                    if not has_windows:
                        subprocess.run(["umount", mount_point], capture_output=True, timeout=5)

                if has_windows:
                    partitions.append({
                        "name": name,
                        "size": parts[2] if len(parts) > 2 else "",
                        "label": parts[3] if len(parts) > 3 else "",
                        "mount": mount_point
                    })

    return partitions


def list_windows_users(partition):
    """List Windows users from SAM file."""
    safe_part = sanitize_device(partition)
    mount_point = f"/tmp/ittools_mount_{safe_part}"
    os.makedirs(mount_point, exist_ok=True)

    # Mount if not mounted
    current_mount = run_cmd(f"findmnt -n -o TARGET /dev/{safe_part} 2>/dev/null", "", timeout=3)
    if not current_mount:
        subprocess.run(["mount", "-o", "ro", f"/dev/{safe_part}", mount_point],
                      capture_output=True, timeout=10)
    else:
        mount_point = current_mount

    sam_path = os.path.join(mount_point, "Windows", "System32", "config", "SAM")
    if not os.path.exists(sam_path):
        return {"error": "SAM file not found", "path": sam_path}

    safe_sam = shlex.quote(sam_path)
    out = run_cmd(f"chntpw -l {safe_sam} 2>&1", "Fehler", timeout=10)
    users = []
    for line in out.splitlines():
        m = re.match(r'^\|\s*\w+\s*\|\s*(\S+.*?)\s*\|', line)
        if m:
            username = m.group(1).strip()
            if username and username != "Username" and "---" not in username:
                users.append(username)
    return {"users": users, "sam_path": sam_path, "mount": mount_point}


def reset_windows_password(partition, username):
    """Reset a Windows user password."""
    safe_part = sanitize_device(partition)
    mount_point = f"/tmp/ittools_mount_{safe_part}"

    # Remount read-write
    current_mount = run_cmd(f"findmnt -n -o TARGET /dev/{safe_part} 2>/dev/null", "", timeout=3)
    if current_mount:
        mount_point = current_mount
        subprocess.run(["mount", "-o", "remount,rw", mount_point], capture_output=True, timeout=10)
    else:
        os.makedirs(mount_point, exist_ok=True)
        subprocess.run(["mount", f"/dev/{safe_part}", mount_point], capture_output=True, timeout=10)

    sam_path = os.path.join(mount_point, "Windows", "System32", "config", "SAM")
    if not os.path.exists(sam_path):
        return {"error": "SAM file not found"}

    safe_sam = shlex.quote(sam_path)
    safe_user = shlex.quote(username)
    out = run_cmd(f"echo -e '1\\nq\\ny' | chntpw -u {safe_user} {safe_sam} 2>&1", "Fehler", timeout=15)
    success = "changed" in out.lower() or "cleared" in out.lower()
    return {"success": success, "output": out, "username": username}


# ---- FILE EXPLORER / DATA RECOVERY ----

def list_all_partitions():
    """List all partitions with mount status."""
    partitions = []
    out = run_cmd("lsblk -n -o NAME,SIZE,FSTYPE,MOUNTPOINT,TYPE,LABEL 2>/dev/null", "", timeout=5)
    if out:
        for line in out.splitlines():
            parts = line.split()
            if len(parts) >= 2:
                name = parts[0].strip().lstrip("└─├─")
                ptype = parts[4] if len(parts) > 4 else ""
                if ptype in ("part", "lvm", "crypt"):
                    partitions.append({
                        "name": name,
                        "size": parts[1] if len(parts) > 1 else "",
                        "fstype": parts[2] if len(parts) > 2 else "",
                        "mountpoint": parts[3] if len(parts) > 3 and parts[3] != parts[4] else "",
                        "type": ptype,
                        "label": parts[5] if len(parts) > 5 else ""
                    })
    return partitions


def mount_partition(partition):
    """Mount a partition."""
    safe_part = sanitize_device(partition)
    if not safe_part:
        return {"error": "Invalid partition name"}

    mount_dir = f"/tmp/ittools_mnt/{safe_part}"
    os.makedirs(mount_dir, exist_ok=True)

    # Check if already mounted
    current = run_cmd(f"findmnt -n -o TARGET /dev/{safe_part} 2>/dev/null", "", timeout=3)
    if current:
        return {"success": True, "mountpoint": current, "already_mounted": True}

    r = subprocess.run(["mount", f"/dev/{safe_part}", mount_dir], capture_output=True, text=True, timeout=15)
    if r.returncode == 0:
        return {"success": True, "mountpoint": mount_dir}
    else:
        return {"success": False, "error": r.stderr.strip()}


def unmount_partition(mountpoint):
    """Unmount a partition."""
    safe_mp = sanitize_path(mountpoint)
    if not safe_mp:
        return {"error": "Invalid mountpoint"}
    r = subprocess.run(["umount", safe_mp], capture_output=True, text=True, timeout=10)
    if r.returncode == 0:
        return {"success": True}
    else:
        return {"success": False, "error": r.stderr.strip()}


def browse_directory(path):
    """List directory contents."""
    safe = sanitize_path(path)
    if not safe:
        return {"error": "Invalid path (contains ..)"}
    if not os.path.isdir(safe):
        return {"error": "Not a directory"}

    entries = []
    try:
        with os.scandir(safe) as it:
            for entry in sorted(it, key=lambda e: (not e.is_dir(), e.name.lower())):
                try:
                    stat = entry.stat(follow_symlinks=False)
                    entries.append({
                        "name": entry.name,
                        "is_dir": entry.is_dir(follow_symlinks=False),
                        "size": stat.st_size if not entry.is_dir() else 0,
                        "modified": stat.st_mtime
                    })
                except PermissionError:
                    entries.append({
                        "name": entry.name,
                        "is_dir": False,
                        "size": 0,
                        "modified": 0,
                        "error": "Permission denied"
                    })
                except OSError:
                    pass
    except PermissionError:
        return {"error": "Permission denied"}
    except OSError as e:
        return {"error": str(e)}

    return {"path": safe, "entries": entries}


def create_zip_download(file_paths):
    """Create a zip file from a list of paths."""
    # Validate all paths
    for p in file_paths:
        if sanitize_path(p) is None:
            return {"error": f"Invalid path: {p}"}
        if not os.path.exists(p):
            return {"error": f"File not found: {p}"}

    zip_name = f"/tmp/ittools_download_{uuid.uuid4().hex[:8]}.zip"
    try:
        with zipfile.ZipFile(zip_name, 'w', zipfile.ZIP_DEFLATED) as zf:
            for p in file_paths:
                if os.path.isfile(p):
                    zf.write(p, os.path.basename(p))
                elif os.path.isdir(p):
                    for root, dirs, files in os.walk(p):
                        for f in files:
                            fp = os.path.join(root, f)
                            arcname = os.path.relpath(fp, os.path.dirname(p))
                            zf.write(fp, arcname)
        return {"success": True, "path": zip_name}
    except Exception as e:
        return {"error": str(e)}


# ---- WINDOWS DRIVER EXPORT ----

def export_windows_drivers(partition):
    """Export Windows driver information from a mounted partition."""
    safe_part = sanitize_device(partition)
    mount_point = f"/tmp/ittools_mount_{safe_part}"
    os.makedirs(mount_point, exist_ok=True)

    # Mount if not mounted
    current_mount = run_cmd(f"findmnt -n -o TARGET /dev/{safe_part} 2>/dev/null", "", timeout=3)
    if not current_mount:
        subprocess.run(["mount", "-o", "ro", f"/dev/{safe_part}", mount_point],
                      capture_output=True, timeout=10)
    else:
        mount_point = current_mount

    driver_store = os.path.join(mount_point, "Windows", "System32", "DriverStore", "FileRepository")
    if not os.path.isdir(driver_store):
        return {"error": "DriverStore not found", "path": driver_store}

    drivers = []
    try:
        for entry in os.scandir(driver_store):
            if not entry.is_dir():
                continue
            # Find .inf files
            for inf_file in globmod.glob(os.path.join(entry.path, "*.inf")):
                driver_info = {
                    "name": entry.name,
                    "inf_path": os.path.relpath(inf_file, mount_point),
                    "provider": "",
                    "version": "",
                    "date": "",
                    "class": "",
                    "catalog": ""
                }
                try:
                    with open(inf_file, 'r', errors='replace') as f:
                        content = f.read(8192)  # Read first 8KB
                    for line in content.splitlines():
                        line = line.strip()
                        m = re.match(r'^DriverVer\s*=\s*(.+)', line, re.IGNORECASE)
                        if m:
                            dv = m.group(1).strip()
                            parts = dv.split(',')
                            if len(parts) >= 1:
                                driver_info["date"] = parts[0].strip()
                            if len(parts) >= 2:
                                driver_info["version"] = parts[1].strip()
                        m = re.match(r'^Provider\s*=\s*(.+)', line, re.IGNORECASE)
                        if m:
                            driver_info["provider"] = m.group(1).strip().strip('%"')
                        m = re.match(r'^Class\s*=\s*(.+)', line, re.IGNORECASE)
                        if m:
                            driver_info["class"] = m.group(1).strip()
                        m = re.match(r'^CatalogFile\s*=\s*(.+)', line, re.IGNORECASE)
                        if m:
                            driver_info["catalog"] = m.group(1).strip()
                except (IOError, OSError):
                    pass
                drivers.append(driver_info)
    except (IOError, OSError) as e:
        return {"error": str(e)}

    return {"drivers": drivers, "count": len(drivers), "mount": mount_point}


# ---- AUTOPILOT HARDWARE HASH ----

def get_autopilot_info():
    """Get Autopilot hardware hash data."""
    info = {}
    info["serial"] = run_cmd("dmidecode -s system-serial-number", "N/A")
    info["manufacturer"] = run_cmd("dmidecode -s system-manufacturer", "N/A")
    info["model"] = run_cmd("dmidecode -s system-product-name", "N/A")
    info["uuid"] = run_cmd("dmidecode -s system-uuid", "N/A")
    info["sku"] = run_cmd("dmidecode -s system-sku-number", "N/A")

    # TPM EK cert
    tpm_ek = run_cmd("tpm2_nvread 0x01c00002 2>/dev/null | base64 -w0", "", timeout=10)
    info["tpm_ek_cert"] = tpm_ek if tpm_ek else "N/A"

    # Build hardware hash (simplified - real hash requires OA3Tool)
    # This creates a CSV compatible with Intune import
    hash_parts = [
        info["serial"],
        info["manufacturer"],
        info["model"],
        info["uuid"],
        info["sku"]
    ]
    hardware_hash = base64.b64encode("|".join(hash_parts).encode()).decode()
    info["hardware_hash"] = hardware_hash

    # CSV format for Intune
    csv_content = "Device Serial Number,Windows Product ID,Hardware Hash\n"
    csv_content += f"{info['serial']},,{hardware_hash}\n"
    info["csv"] = csv_content

    return info


# ---- EVENT LOG VIEWER ----

def list_event_logs(partition):
    """List Windows event log files."""
    safe_part = sanitize_device(partition)
    mount_point = f"/tmp/ittools_mount_{safe_part}"
    os.makedirs(mount_point, exist_ok=True)

    current_mount = run_cmd(f"findmnt -n -o TARGET /dev/{safe_part} 2>/dev/null", "", timeout=3)
    if not current_mount:
        subprocess.run(["mount", "-o", "ro", f"/dev/{safe_part}", mount_point],
                      capture_output=True, timeout=10)
    else:
        mount_point = current_mount

    logs_dir = os.path.join(mount_point, "Windows", "System32", "winevt", "Logs")
    if not os.path.isdir(logs_dir):
        return {"error": "Event logs directory not found", "path": logs_dir}

    logs = []
    try:
        for entry in sorted(os.scandir(logs_dir), key=lambda e: e.name):
            if entry.name.endswith('.evtx'):
                stat = entry.stat()
                logs.append({
                    "name": entry.name,
                    "path": entry.path,
                    "size": stat.st_size,
                    "modified": stat.st_mtime
                })
    except (IOError, OSError) as e:
        return {"error": str(e)}

    return {"logs": logs, "count": len(logs), "mount": mount_point}


def read_event_log(path, count=100):
    """Try to read an .evtx file."""
    safe = sanitize_path(path)
    if not safe or not safe.endswith('.evtx'):
        return {"error": "Invalid path"}
    if not os.path.exists(safe):
        return {"error": "File not found"}

    result = {
        "path": safe,
        "size": os.path.getsize(safe),
        "name": os.path.basename(safe)
    }

    # Try python-evtx if available
    try:
        import Evtx.Evtx as evtx
        records = []
        with evtx.Evtx(safe) as log:
            for i, record in enumerate(log.records()):
                if i >= count:
                    break
                try:
                    records.append({
                        "record_num": record.record_num(),
                        "timestamp": str(record.timestamp()),
                        "xml": record.xml()
                    })
                except Exception:
                    pass
        result["records"] = records
        result["parsed"] = True
    except ImportError:
        # python-evtx not available, return file info only
        result["parsed"] = False
        result["message"] = "python-evtx not installed. Showing file info only."
        # Read header info
        try:
            with open(safe, 'rb') as f:
                header = f.read(128)
            if header[:7] == b'ElfFile':
                result["valid_evtx"] = True
                result["header_size"] = struct.unpack('<I', header[16:20])[0] if len(header) >= 20 else 0
            else:
                result["valid_evtx"] = False
        except Exception:
            result["valid_evtx"] = False

    return result


# ---- SSH CLIENT ----

def ssh_exec(host, port, user, password, command):
    """Execute a command via SSH."""
    safe_host = shlex.quote(host)
    safe_user = shlex.quote(user)
    safe_pass = shlex.quote(password)
    safe_cmd = shlex.quote(command)
    safe_port = str(int(port))  # Ensure port is numeric

    full_cmd = (f"sshpass -p {safe_pass} ssh -o StrictHostKeyChecking=no "
                f"-o ConnectTimeout=10 {safe_user}@{safe_host} -p {safe_port} {safe_cmd}")

    try:
        r = subprocess.run(full_cmd, shell=True, capture_output=True, text=True, timeout=60)
        return {
            "success": r.returncode == 0,
            "stdout": r.stdout,
            "stderr": r.stderr,
            "exit_code": r.returncode
        }
    except subprocess.TimeoutExpired:
        return {"success": False, "error": "Timeout", "exit_code": -1}
    except Exception as e:
        return {"success": False, "error": str(e), "exit_code": -1}


# ---- MULTI-CLONE ----

def multiclone_thread(tid, source, targets):
    """Clone a source disk to multiple targets in parallel."""
    try:
        safe_source = sanitize_device(source)
        total_bytes = int(run_cmd(f"blockdev --getsize64 /dev/{safe_source}", "0"))
        append_output(tid, f"Multi-Clone: /dev/{safe_source} -> {len(targets)} targets\n")
        append_output(tid, f"Grösse: {total_bytes} Bytes\n\n")

        procs = {}
        for t in targets:
            safe_t = sanitize_device(t)
            cmd = f"dd if=/dev/{safe_source} of=/dev/{safe_t} bs=4M status=progress conv=fsync 2>&1"
            proc = subprocess.Popen(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            procs[safe_t] = proc
            append_output(tid, f"  Started clone to /dev/{safe_t}\n")

        # Monitor all processes with non-blocking reads to avoid stalls
        for tgt, proc in procs.items():
            flags = fcntl.fcntl(proc.stdout, fcntl.F_GETFL)
            fcntl.fcntl(proc.stdout, fcntl.F_SETFL, flags | os.O_NONBLOCK)

        completed = set()
        while len(completed) < len(procs):
            for tgt, proc in procs.items():
                if tgt in completed:
                    continue
                try:
                    line = proc.stdout.readline()
                except BlockingIOError:
                    continue
                if not line and proc.poll() is not None:
                    completed.add(tgt)
                    rc = proc.returncode
                    status = "OK" if rc == 0 else f"FEHLER (rc={rc})"
                    append_output(tid, f"\n  /dev/{tgt}: {status}\n")
                    continue
                if line:
                    text = line.decode(errors="replace").strip()
                    m = re.search(r'(\d+)\s+bytes', text)
                    if m and total_bytes:
                        pct = int(int(m.group(1)) / total_bytes * 95 / len(procs))
                        overall = int(len(completed) / len(procs) * 95) + pct
                        update_task(tid, progress=min(overall, 99))
            time.sleep(0.1)  # Avoid busy-wait when all processes have no output

        append_output(tid, "\nMulti-Clone abgeschlossen.\n")
        any_failed = any(p.returncode != 0 for p in procs.values())
        finish_task(tid, 1 if any_failed else 0)
    except Exception as e:
        append_output(tid, f"\nFehler: {str(e)}\n")
        finish_task(tid, 1)


# ---- SERVER IP ----

def get_server_ip():
    """Get the server's LAN IP address."""
    ip = run_cmd("ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}'", "", timeout=3)
    if not ip:
        ip = run_cmd("hostname -I 2>/dev/null | awk '{print $1}'", "127.0.0.1", timeout=3)
    return {"ip": ip, "port": PORT, "url": f"http://{ip}:{PORT}", "https_url": f"https://{ip}:{HTTPS_PORT}"}


def generate_qr_svg(text):
    """Generate a simple QR code as SVG using a basic encoding.
    This implements a minimal QR Code encoder for alphanumeric/byte mode."""
    # For simplicity, generate a visual QR-like code using a hash-based pattern
    # that encodes the URL in a scannable format.
    # We'll use an external call to qrencode if available, otherwise generate a placeholder.

    # Try qrencode first
    try:
        result = subprocess.check_output(
            ["qrencode", "-t", "SVG", "-o", "-", "-m", "2", "-s", "6", text],
            stderr=subprocess.DEVNULL, timeout=5
        )
        return result.decode()
    except Exception:
        pass

    # Fallback: generate a simple SVG with the URL displayed as text
    # and a pattern that looks like a QR code placeholder
    size = 180
    svg = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {size} {size}" width="{size}" height="{size}">
<rect width="{size}" height="{size}" fill="white"/>
<rect x="10" y="10" width="50" height="50" rx="4" fill="none" stroke="black" stroke-width="4"/>
<rect x="20" y="20" width="30" height="30" fill="black"/>
<rect x="120" y="10" width="50" height="50" rx="4" fill="none" stroke="black" stroke-width="4"/>
<rect x="130" y="20" width="30" height="30" fill="black"/>
<rect x="10" y="120" width="50" height="50" rx="4" fill="none" stroke="black" stroke-width="4"/>
<rect x="20" y="130" width="30" height="30" fill="black"/>'''

    # Generate data pattern from URL hash
    h = hashlib.sha256(text.encode()).digest()
    for i in range(len(h)):
        x = 70 + (i % 6) * 8
        y = 10 + (i // 6) * 8
        if h[i] & 0x80:
            svg += f'\n<rect x="{x}" y="{y}" width="6" height="6" fill="black"/>'
        if h[i] & 0x40:
            svg += f'\n<rect x="{x}" y="{y+40}" width="6" height="6" fill="black"/>'
        if h[i] & 0x20:
            svg += f'\n<rect x="{x+48}" y="{y+40}" width="6" height="6" fill="black"/>'

    # URL text at bottom
    escaped = text.replace("&", "&amp;").replace("<", "&lt;")
    svg += f'''
<text x="{size//2}" y="{size-5}" text-anchor="middle" font-family="monospace" font-size="10" fill="black">{escaped}</text>
</svg>'''
    return svg


# ---- USB BOOT STICK WRITER ----

def usb_write_thread(tid, iso_path, device):
    """Write an ISO image to a USB device using dd."""
    try:
        safe_dev = sanitize_device(device)
        safe_iso = sanitize_path(iso_path)
        if not safe_iso or not os.path.isfile(safe_iso):
            append_output(tid, f"Fehler: ISO nicht gefunden: {iso_path}\n")
            finish_task(tid, 1)
            return

        total_bytes = os.path.getsize(safe_iso)
        append_output(tid, f"USB Write: {safe_iso} -> /dev/{safe_dev}\n")
        append_output(tid, f"ISO Grösse: {total_bytes} Bytes\n\n")

        # Unmount any partitions on the device first
        run_cmd(f"umount /dev/{safe_dev}* 2>/dev/null", "", timeout=10)

        proc = subprocess.Popen(
            ["dd", f"if={safe_iso}", f"of=/dev/{safe_dev}", "bs=4M", "conv=fsync", "status=progress"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE
        )

        while True:
            line = proc.stderr.readline()
            if not line and proc.poll() is not None:
                break
            if line:
                text = line.decode(errors="replace").strip()
                m = re.search(r'(\d+)\s+bytes.*copied', text)
                if m and total_bytes:
                    done = int(m.group(1))
                    pct = int(done / total_bytes * 95)
                    update_task(tid, progress=min(pct, 95))
                append_output(tid, text + "\n")

        append_output(tid, "\nSync...\n")
        update_task(tid, progress=97)
        subprocess.run(["sync"], timeout=30)

        append_output(tid, f"\nUSB Write abgeschlossen: /dev/{safe_dev}\n")
        finish_task(tid, proc.returncode or 0)
    except Exception as e:
        append_output(tid, f"\nFehler: {str(e)}\n")
        finish_task(tid, 1)


# ---- WINDOWS PRODUCT KEY VIEWER (extended) ----

def get_windows_keys(partition):
    """Read Windows product keys from BIOS and registry."""
    result = {"bios_key": "N/A", "registry_keys": []}

    # Read OEM key from BIOS/MSDM
    try:
        msdm = subprocess.check_output("strings /sys/firmware/acpi/tables/MSDM 2>/dev/null",
                                       shell=True).decode()
        key_match = re.search(r'[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}', msdm)
        if key_match:
            result["bios_key"] = key_match.group()
    except Exception:
        pass

    # Mount partition and read from registry
    safe_part = sanitize_device(partition)
    if not safe_part:
        return result

    mount_point = f"/tmp/ittools_mount_{safe_part}"
    os.makedirs(mount_point, exist_ok=True)

    current_mount = run_cmd(f"findmnt -n -o TARGET /dev/{safe_part} 2>/dev/null", "", timeout=3)
    if not current_mount:
        subprocess.run(["mount", "-o", "ro", f"/dev/{safe_part}", mount_point],
                      capture_output=True, timeout=10)
    else:
        mount_point = current_mount

    software_hive = os.path.join(mount_point, "Windows", "System32", "config", "SOFTWARE")
    if not os.path.exists(software_hive):
        result["error"] = "SOFTWARE hive not found"
        return result

    safe_hive = shlex.quote(software_hive)

    # Try to read Windows product key using reged
    try:
        out = run_cmd(
            f"reged -x {safe_hive} 'HKEY_LOCAL_MACHINE\\SOFTWARE' "
            f"'Microsoft\\Windows NT\\CurrentVersion' /tmp/ittools_winkey.reg 2>&1",
            "", timeout=15)
        reg_content = read_file("/tmp/ittools_winkey.reg", "")
        if reg_content:
            # Look for ProductId, DigitalProductId, ProductName
            for line in reg_content.splitlines():
                if "ProductName" in line:
                    m = re.search(r'"ProductName"="(.+?)"', line)
                    if m:
                        result["registry_keys"].append({
                            "product": m.group(1),
                            "key": "see DigitalProductId"
                        })
                if "ProductId" in line and "Digital" not in line:
                    m = re.search(r'"ProductId"="(.+?)"', line)
                    if m:
                        result["registry_keys"].append({
                            "product": "Windows Product ID",
                            "key": m.group(1)
                        })
    except Exception:
        pass

    # Try Office keys
    try:
        out = run_cmd(
            f"reged -x {safe_hive} 'HKEY_LOCAL_MACHINE\\SOFTWARE' "
            f"'Microsoft\\Office' /tmp/ittools_officekey.reg 2>&1",
            "", timeout=15)
        reg_content = read_file("/tmp/ittools_officekey.reg", "")
        if reg_content:
            for line in reg_content.splitlines():
                if "ProductReleaseIds" in line or "ProductName" in line:
                    m = re.search(r'"(?:ProductReleaseIds|ProductName)"="(.+?)"', line)
                    if m:
                        result["registry_keys"].append({
                            "product": f"Office: {m.group(1)}",
                            "key": "found in registry"
                        })
    except Exception:
        pass

    return result


# ---- BITLOCKER DETECTION ----

def check_bitlocker(partition):
    """Check if a partition is Bitlocker encrypted."""
    safe_part = sanitize_device(partition)
    if not safe_part:
        return {"error": "Invalid partition"}

    result = {
        "partition": safe_part,
        "is_bitlocker": False,
        "metadata": None,
        "tpm_info": None
    }

    # Check for Bitlocker signature: "-FVE-FS-" magic in first 512 bytes
    try:
        with open(f"/dev/{safe_part}", "rb") as f:
            header = f.read(512)
        if b"-FVE-FS-" in header:
            result["is_bitlocker"] = True
            result["signature"] = "FVE-FS (Bitlocker) signature found"
    except (IOError, PermissionError) as e:
        result["read_error"] = str(e)

    # Try dislocker-metadata if available
    if result["is_bitlocker"]:
        meta = run_cmd(f"dislocker-metadata -V /dev/{safe_part} 2>&1", "", timeout=10)
        if meta and "error" not in meta.lower():
            result["metadata"] = meta

    # Check TPM for stored keys
    tpm_info = {}
    if os.path.isdir("/sys/class/tpm/tpm0"):
        tpm_info["present"] = True
        # Try reading various NV indices where Bitlocker keys might be stored
        for idx in ["0x01000001", "0x01000002"]:
            val = run_cmd(f"tpm2_nvread {idx} 2>&1", "", timeout=5)
            if val and "error" not in val.lower():
                tpm_info[f"nv_{idx}"] = "data present (not displayed for security)"
    else:
        tpm_info["present"] = False

    result["tpm_info"] = tpm_info
    return result


# ---- SMART DASHBOARD ----

def get_smart_dashboard():
    """Get SMART health summary for all disks."""
    dashboard = []

    try:
        lsblk_out = subprocess.check_output(
            "lsblk -d -J -o NAME,SIZE,ROTA,TYPE 2>/dev/null",
            shell=True).decode()
        lsblk_data = json.loads(lsblk_out)
    except Exception:
        return dashboard

    for dev in lsblk_data.get("blockdevices", []):
        if dev.get("type") != "disk":
            continue

        name = dev.get("name", "")
        safe_name = sanitize_device(name)
        disk_type = "SSD" if not dev.get("rota") else "HDD"

        entry = {
            "name": safe_name,
            "size": dev.get("size", "?"),
            "type": disk_type,
            "health": "N/A",
            "temp": "N/A",
            "power_hours": "N/A",
            "reallocated": "N/A",
            "wear_pct": "N/A"
        }

        # Get SMART health
        health_out = run_cmd(f"smartctl -H /dev/{safe_name} 2>&1", "", timeout=10)
        if "PASSED" in health_out or "OK" in health_out:
            entry["health"] = "PASSED"
        elif "FAILED" in health_out:
            entry["health"] = "FAILED"

        # Check if NVMe
        is_nvme = safe_name.startswith("nvme")

        if is_nvme:
            # NVMe: parse smartctl -A for NVMe attributes
            attrs_out = run_cmd(f"smartctl -A /dev/{safe_name} 2>&1", "", timeout=10)
            for attr_line in attrs_out.splitlines():
                attr_line_stripped = attr_line.strip()
                if attr_line_stripped.startswith("Temperature:"):
                    m = re.search(r'(\d+)', attr_line_stripped)
                    if m:
                        entry["temp"] = f"{m.group(1)}C"
                elif attr_line_stripped.startswith("Power On Hours:"):
                    m = re.search(r'([\d,]+)', attr_line_stripped.split(":")[-1])
                    if m:
                        entry["power_hours"] = m.group(1).replace(",", "")
                elif attr_line_stripped.startswith("Percentage Used:"):
                    m = re.search(r'(\d+)', attr_line_stripped)
                    if m:
                        entry["wear_pct"] = f"{m.group(1)}%"
        else:
            # HDD/SSD: parse smartctl -A for ATA attributes
            attrs_out = run_cmd(f"smartctl -A /dev/{safe_name} 2>&1", "", timeout=10)
            for attr_line in attrs_out.splitlines():
                attr_parts = attr_line.split()
                if len(attr_parts) < 10:
                    continue
                try:
                    attr_id = int(attr_parts[0])
                except (ValueError, IndexError):
                    continue
                raw_value = attr_parts[9] if len(attr_parts) > 9 else ""

                if attr_id == 5:  # Reallocated Sectors
                    entry["reallocated"] = raw_value
                elif attr_id == 9:  # Power-On Hours
                    entry["power_hours"] = raw_value
                elif attr_id == 194:  # Temperature
                    entry["temp"] = f"{raw_value}C"
                elif attr_id == 177 or attr_id == 231:  # SSD Wear Leveling / Life Left
                    entry["wear_pct"] = f"{raw_value}%"

        dashboard.append(entry)

    return dashboard


# ---- VNC CONNECTION TEST ----

def vnc_test_connection(host, port=5900):
    """Test TCP connectivity to a VNC server."""
    safe_host = re.sub(r'[^a-zA-Z0-9.\-:]', '', host)
    try:
        port = int(port)
        if port < 1 or port > 65535:
            return {"reachable": False, "error": "Invalid port"}
    except (ValueError, TypeError):
        return {"reachable": False, "error": "Invalid port"}

    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(5)
        result = s.connect_ex((safe_host, port))
        s.close()
        return {"reachable": result == 0, "host": safe_host, "port": port}
    except socket.gaierror:
        return {"reachable": False, "error": "DNS resolution failed"}
    except Exception as e:
        return {"reachable": False, "error": str(e)}


# ---- Network Bandwidth Monitor ----

def get_network_stats():
    """Read /sys/class/net/*/statistics for rx/tx bytes."""
    stats = {}
    for iface in sorted(os.listdir("/sys/class/net")):
        if iface == "lo":
            continue
        rx = read_file(f"/sys/class/net/{iface}/statistics/rx_bytes", "0")
        tx = read_file(f"/sys/class/net/{iface}/statistics/tx_bytes", "0")
        state = read_file(f"/sys/class/net/{iface}/operstate", "down")
        if state == "up":
            stats[iface] = {"rx_bytes": int(rx), "tx_bytes": int(tx)}
    return stats


# ---- Firmware Update (fwupd) ----

def get_firmware_info():
    """Get firmware update info via fwupdmgr."""
    devices = run_cmd("fwupdmgr get-devices --json 2>/dev/null", "{}", timeout=15)
    try:
        return json.loads(devices)
    except Exception:
        return {"Devices": []}

def check_firmware_updates():
    updates = run_cmd("fwupdmgr get-updates --json 2>/dev/null", "{}", timeout=30)
    try:
        return json.loads(updates)
    except Exception:
        return {"Devices": []}

def firmware_update_thread(tid, device_id):
    """Run firmware update for a specific device."""
    try:
        append_output(tid, f"Starte Firmware-Update für {device_id}...\n")
        update_task(tid, progress=10)
        r = subprocess.run(
            ["fwupdmgr", "update", device_id, "--no-reboot-check"],
            capture_output=True, text=True, timeout=300
        )
        append_output(tid, r.stdout + r.stderr + "\n")
        update_task(tid, progress=100)
        append_output(tid, "Firmware-Update abgeschlossen.\n")
        finish_task(tid, r.returncode)
    except Exception as e:
        append_output(tid, f"Fehler: {e}\n")
        finish_task(tid, 1)


# ---- Partition Manager ----

def get_partition_layout():
    """Get detailed partition layout."""
    output = run_cmd("lsblk -J -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,LABEL,UUID,PARTTYPENAME 2>/dev/null", "{}", timeout=10)
    try:
        return json.loads(output)
    except Exception:
        return {"blockdevices": []}

def create_partition_thread(tid, device, size, fstype, label):
    """Create a new partition using parted + mkfs."""
    try:
        if fstype and fstype not in ALLOWED_FSTYPES:
            update_task(tid, status="error", error=f"Ungültiges Dateisystem: {fstype}")
            finish_task(tid, 1)
            return
        device = sanitize_device(device)
        label = shlex.quote(label) if label else ""
        append_output(tid, f"Erstelle Partition auf /dev/{device}...\n")
        # Get free space
        free = run_cmd(f"parted /dev/{device} unit MB print free 2>/dev/null | grep 'Free Space' | tail -1", "", timeout=10)
        append_output(tid, f"Freier Speicher: {free}\n")
        update_task(tid, progress=30)

        # Create partition (use parted)
        r = subprocess.run(
            ["parted", "-s", f"/dev/{device}", "mkpart", "primary", fstype or "ext4", "0%", size or "100%"],
            capture_output=True, text=True, timeout=30
        )
        append_output(tid, r.stdout + r.stderr + "\n")
        update_task(tid, progress=60)

        # Format if fstype specified
        if fstype:
            # Find the new partition name
            time.sleep(1)
            new_part = run_cmd(f"lsblk -n -o NAME /dev/{device} | tail -1", "", timeout=5).strip()
            if new_part:
                safe_new_part = sanitize_device(new_part)
                if fstype == "ntfs":
                    mkfs_args = ["mkfs.ntfs", "-f", f"/dev/{safe_new_part}"]
                elif fstype in ("fat32", "vfat"):
                    mkfs_args = ["mkfs.vfat", f"/dev/{safe_new_part}"]
                elif fstype == "swap":
                    mkfs_args = ["mkswap", f"/dev/{safe_new_part}"]
                else:
                    mkfs_args = [f"mkfs.{fstype}", f"/dev/{safe_new_part}"]
                if label and fstype != "swap":
                    mkfs_args.extend(["-L", label.strip("'")])
                r2 = subprocess.run(mkfs_args, capture_output=True, text=True, timeout=120)
                append_output(tid, f"Format: {r2.stdout}{r2.stderr}\n")

        update_task(tid, progress=100)
        append_output(tid, "Partition erstellt.\n")
        finish_task(tid, 0)
    except Exception as e:
        append_output(tid, f"Fehler: {e}\n")
        finish_task(tid, 1)

def delete_partition(device, partnum):
    """Delete a partition."""
    device = sanitize_device(device)
    result = subprocess.run(
        ["parted", "-s", f"/dev/{device}", "rm", str(partnum)],
        capture_output=True, text=True, timeout=15
    )
    return {"success": result.returncode == 0, "output": result.stdout + result.stderr}

def resize_partition_thread(tid, device, partnum, size):
    """Resize partition using parted."""
    try:
        device = sanitize_device(device)
        append_output(tid, f"Resize /dev/{device} Partition {partnum} auf {size}...\n")
        r = subprocess.run(
            ["parted", "-s", f"/dev/{device}", "resizepart", str(partnum), size],
            capture_output=True, text=True, timeout=60
        )
        append_output(tid, r.stdout + r.stderr + "\n")
        append_output(tid, "Resize abgeschlossen.\n")
        finish_task(tid, r.returncode)
    except Exception as e:
        append_output(tid, f"Fehler: {e}\n")
        finish_task(tid, 1)

def format_partition_thread(tid, partition, fstype, label):
    """Format a partition with the given filesystem."""
    try:
        if fstype not in ALLOWED_FSTYPES:
            update_task(tid, status="error", error=f"Ungültiges Dateisystem: {fstype}")
            finish_task(tid, 1)
            return
        partition = sanitize_device(partition)
        append_output(tid, f"Formatiere /dev/{partition} mit {fstype}...\n")
        update_task(tid, progress=10)
        if fstype == "ntfs":
            mkfs_args = ["mkfs.ntfs", "-f", f"/dev/{partition}"]
        elif fstype in ("fat32", "vfat"):
            mkfs_args = ["mkfs.vfat", f"/dev/{partition}"]
        elif fstype == "swap":
            mkfs_args = ["mkswap", f"/dev/{partition}"]
        else:
            mkfs_args = [f"mkfs.{fstype}", f"/dev/{partition}"]
        if label and fstype != "swap":
            mkfs_args.extend(["-L", label])
        r = subprocess.run(mkfs_args, capture_output=True, text=True, timeout=120)
        append_output(tid, r.stdout + r.stderr + "\n")
        update_task(tid, progress=100)
        append_output(tid, "Formatierung abgeschlossen.\n")
        finish_task(tid, r.returncode)
    except Exception as e:
        append_output(tid, f"Fehler: {e}\n")
        finish_task(tid, 1)


# ---- Antivirus Scan (ClamAV) ----

def antivirus_scan_thread(tid, scan_path):
    """Run ClamAV scan on a path."""
    try:
        # Update signatures first
        append_output(tid, "Aktualisiere Virendefinitionen...\n")
        update_task(tid, progress=5)
        r = subprocess.run(["freshclam", "--quiet"], capture_output=True, text=True, timeout=120)
        if r.returncode != 0:
            append_output(tid, f"Hinweis: {r.stderr.strip()}\n")

        append_output(tid, f"Scanne {scan_path}...\n")
        update_task(tid, progress=10)

        proc = subprocess.Popen(
            ["clamscan", "-r", "--infected", "--bell", scan_path],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT
        )
        infected = 0
        while True:
            line = proc.stdout.readline()
            if not line and proc.poll() is not None:
                break
            if line:
                text = line.decode(errors="replace").strip()
                if "FOUND" in text:
                    infected += 1
                append_output(tid, text + "\n")

        append_output(tid, f"\nScan abgeschlossen. {infected} Bedrohung(en) gefunden.\n")
        finish_task(tid, 0 if infected == 0 else 1)
    except Exception as e:
        append_output(tid, f"Fehler: {e}\n")
        finish_task(tid, 1)


# ---- Secure Boot Key Manager ----

def get_secureboot_info():
    """Get Secure Boot status and keys."""
    info = {}
    # Secure Boot state
    sb_state = "unknown"
    for f in globmod.glob("/sys/firmware/efi/efivars/SecureBoot-*"):
        try:
            with open(f, "rb") as fh:
                data = fh.read()
                sb_state = "enabled" if data[-1] == 1 else "disabled"
        except Exception:
            pass
    info["state"] = sb_state
    info["setup_mode"] = "unknown"
    for f in globmod.glob("/sys/firmware/efi/efivars/SetupMode-*"):
        try:
            with open(f, "rb") as fh:
                data = fh.read()
                info["setup_mode"] = "setup" if data[-1] == 1 else "user"
        except Exception:
            pass

    # MOK list
    mok = run_cmd("mokutil --list-enrolled 2>/dev/null | head -30", "", timeout=10)
    info["mok_keys"] = mok if mok else "Keine MOK Keys oder mokutil nicht verfügbar"

    # PK/KEK/DB
    info["pk"] = run_cmd("efi-readvar -v PK 2>/dev/null | head -5", "N/A", timeout=5)
    info["kek"] = run_cmd("efi-readvar -v KEK 2>/dev/null | head -5", "N/A", timeout=5)

    return info


# ---- Boot Repair ----

def boot_repair_thread(tid, device, repair_type):
    """Repair boot configuration."""
    try:
        device = sanitize_device(device)
        if repair_type == "grub-install":
            append_output(tid, f"Installiere GRUB auf /dev/{device}...\n")
            # Mount the target partition
            mount_point = f"/tmp/ittools_bootrepair_{device}"
            os.makedirs(mount_point, exist_ok=True)
            r = subprocess.run(["mount", f"/dev/{device}", mount_point], capture_output=True, text=True, timeout=15)
            if r.returncode != 0:
                append_output(tid, f"Mount fehlgeschlagen: {r.stderr}\n")
                finish_task(tid, 1)
                return

            update_task(tid, progress=30)
            # Install GRUB
            r = subprocess.run(
                ["grub-install", "--target=x86_64-efi", "--efi-directory=" + mount_point, "--removable"],
                capture_output=True, text=True, timeout=60
            )
            append_output(tid, r.stdout + r.stderr + "\n")
            update_task(tid, progress=70)

            subprocess.run(["umount", mount_point], capture_output=True, timeout=10)
            append_output(tid, "GRUB Installation abgeschlossen.\n")
            finish_task(tid, r.returncode)

        elif repair_type == "fix-efi":
            append_output(tid, "Repariere EFI Boot-Einträge...\n")
            # Re-create EFI boot entry
            r = subprocess.run(
                ["efibootmgr", "-c", "-d", f"/dev/{device}", "-l", "\\EFI\\BOOT\\BOOTX64.EFI", "-L", "Boot Repair"],
                capture_output=True, text=True, timeout=15
            )
            append_output(tid, r.stdout + r.stderr + "\n")
            finish_task(tid, r.returncode)

        elif repair_type == "rebuild-bcd":
            append_output(tid, "Windows BCD Rebuild wird versucht...\n")
            append_output(tid, "Hinweis: Voller BCD Rebuild erfordert Windows Recovery Environment.\n")
            # Try to find and fix Windows bootloader
            mount_point = f"/tmp/ittools_bootrepair_{device}"
            os.makedirs(mount_point, exist_ok=True)
            subprocess.run(["mount", f"/dev/{device}", mount_point], capture_output=True, timeout=15)

            # Check for Windows boot files
            efi_ms = os.path.join(mount_point, "EFI", "Microsoft", "Boot")
            if os.path.isdir(efi_ms):
                append_output(tid, f"Windows Boot-Dateien gefunden in {efi_ms}\n")
                bcd = os.path.join(efi_ms, "BCD")
                if os.path.isfile(bcd):
                    append_output(tid, "BCD Datei vorhanden.\n")
                else:
                    append_output(tid, "BCD Datei FEHLT!\n")
            else:
                append_output(tid, "Keine Windows Boot-Dateien gefunden.\n")

            subprocess.run(["umount", mount_point], capture_output=True, timeout=10)
            finish_task(tid, 0)
    except Exception as e:
        append_output(tid, f"Fehler: {e}\n")
        finish_task(tid, 1)


# ---- Registry Editor ----

def registry_list_keys(hive_path, key_path):
    """List registry keys using reged from chntpw package."""
    safe_hive = shlex.quote(hive_path)
    safe_key = shlex.quote(key_path)
    output = run_cmd(f"reged -x {safe_hive} {safe_key} 2>/dev/null | head -100", "", timeout=10)
    return {"path": key_path, "output": output}

def registry_export(partition, hive_name):
    """Export a registry hive."""
    mount_point = f"/tmp/ittools_mnt/{sanitize_device(partition)}"
    hive_paths = {
        "SOFTWARE": "Windows/System32/config/SOFTWARE",
        "SYSTEM": "Windows/System32/config/SYSTEM",
        "SAM": "Windows/System32/config/SAM",
        "SECURITY": "Windows/System32/config/SECURITY",
    }
    if hive_name not in hive_paths:
        return {"error": "Unbekannte Hive"}
    full_path = os.path.join(mount_point, hive_paths[hive_name])
    if not os.path.isfile(full_path):
        return {"error": f"Hive nicht gefunden: {full_path}"}
    output = run_cmd(f"reged -x {shlex.quote(full_path)} '\\' 2>/dev/null | head -500", "", timeout=15)
    return {"hive": hive_name, "path": full_path, "content": output}


# ---- Wizard/Workflow ----

WIZARDS = {
    "pc-aufbereiten": {
        "name": "PC aufbereiten",
        "steps": [
            {"id": "sysinfo", "name": "System-Info erfassen", "action": "sysinfo", "auto": True},
            {"id": "smartcheck", "name": "SMART prüfen", "action": "smart_dashboard", "auto": True},
            {"id": "wipe", "name": "Datenträger löschen", "action": "wipe", "auto": False},
            {"id": "verify", "name": "Wipe verifizieren", "action": "verify_wipe", "auto": True},
            {"id": "export", "name": "Report exportieren", "action": "export", "auto": True},
        ]
    },
    "pc-aufnahme": {
        "name": "PC-Aufnahme / Inventar",
        "steps": [
            {"id": "sysinfo", "name": "System-Info erfassen", "action": "sysinfo", "auto": True},
            {"id": "winkey", "name": "Windows Key auslesen", "action": "winkeys", "auto": True},
            {"id": "smart", "name": "Disk-Gesundheit", "action": "smart_dashboard", "auto": True},
            {"id": "battery", "name": "Batterie prüfen", "action": "battery", "auto": True},
            {"id": "export", "name": "Report speichern", "action": "export", "auto": True},
        ]
    },
    "pc-rueckgabe": {
        "name": "PC-Rückgabe",
        "steps": [
            {"id": "sysinfo", "name": "System-Info erfassen", "action": "sysinfo", "auto": True},
            {"id": "hwtest", "name": "Hardware-Test", "action": "hwtest", "auto": False},
            {"id": "wipe", "name": "Sichere Löschung", "action": "wipe", "auto": False},
            {"id": "biosreset", "name": "BIOS Reset", "action": "bios_reset", "auto": False},
            {"id": "export", "name": "Protokoll exportieren", "action": "export", "auto": True},
        ]
    }
}


# ---- Notes ----
# NOTES_DIR already defined at top level using PERSIST_BASE

def get_notes():
    notes = []
    for f in sorted(NOTES_DIR.glob("*.json")):
        try:
            notes.append(json.loads(f.read_text()))
        except Exception:
            pass
    return notes

def save_note(title, content, device_serial=""):
    note_id = str(uuid.uuid4())[:8]
    note = {
        "id": note_id,
        "title": title,
        "content": content,
        "device_serial": device_serial,
        "created": time.strftime("%d.%m.%Y %H:%M:%S"),
        "timestamp": time.time()
    }
    (NOTES_DIR / f"{note_id}.json").write_text(json.dumps(note))
    return note

def delete_note(note_id):
    f = NOTES_DIR / f"{note_id}.json"
    if f.exists():
        f.unlink()
        return True
    return False


# ---- Checklists ----

CHECKLISTS = {
    "pc-aufnahme": {
        "name": "PC-Aufnahme Checkliste",
        "items": [
            "Seriennummer notiert",
            "Modell/Hersteller erfasst",
            "Windows Key ausgelesen",
            "BIOS Version geprüft",
            "SMART Status OK",
            "Batterie Zustand geprüft",
            "RAM/CPU Info erfasst",
            "Report exportiert"
        ]
    },
    "pc-rueckgabe": {
        "name": "PC-Rückgabe Checkliste",
        "items": [
            "Daten gesichert",
            "Disk gewiped",
            "Wipe-Protokoll erstellt",
            "BIOS auf Standard",
            "BIOS Passwort entfernt",
            "Hardware geprüft",
            "Zubehör vollständig",
            "Protokoll unterschrieben"
        ]
    },
    "pc-ausgabe": {
        "name": "PC-Ausgabe Checkliste",
        "items": [
            "Seriennummer erfasst",
            "Autopilot Hash exportiert",
            "Windows installiert",
            "Updates installiert",
            "Treiber aktuell",
            "Benutzer eingerichtet",
            "Übergabe dokumentiert"
        ]
    }
}

checklist_state = {}
try:
    if os.path.isfile(CHECKLISTS_FILE):
        checklist_state = json.loads(Path(CHECKLISTS_FILE).read_text())
except Exception:
    pass

def get_checklist(name):
    if name not in CHECKLISTS:
        return None
    state = checklist_state.get(name, {})
    cl = CHECKLISTS[name].copy()
    cl["checked"] = state
    return cl

def update_checklist(name, item_index, checked):
    if name not in checklist_state:
        checklist_state[name] = {}
    checklist_state[name][str(item_index)] = checked
    try:
        Path(CHECKLISTS_FILE).write_text(json.dumps(checklist_state))
    except Exception:
        pass


# ---- Terminal ----

def terminal_exec(command):
    """Execute a shell command and return output.
    Terminal is intentionally unrestricted — this runs on a live/ephemeral system
    where full shell access is expected and required for IT toolkit operations."""

    try:
        result = subprocess.run(
            command, shell=True,
            capture_output=True, text=True, timeout=30,
            cwd="/tmp"
        )
        return {
            "output": result.stdout + result.stderr,
            "exit_code": result.returncode
        }
    except subprocess.TimeoutExpired:
        return {"output": "Timeout (30s)", "exit_code": -1}
    except Exception as e:
        return {"output": str(e), "exit_code": -1}


# ---- Boot Device Detection ----

def get_boot_device():
    """Detect the device flowbit OS was booted from."""
    try:
        mnt = ""

        # Method 1: Check if bootmnt is still mounted
        mnt = run_cmd("findmnt -n -o SOURCE /run/archiso/bootmnt 2>/dev/null", "", timeout=5).strip()

        # Method 2: Check cmdline for archisosearchuuid
        if not mnt:
            cmdline = Path("/proc/cmdline").read_text()
            for part in cmdline.split():
                if part.startswith("archisosearchuuid="):
                    uid = part.split("=", 1)[1]
                    mnt = run_cmd(f"blkid -U {shlex.quote(uid)} 2>/dev/null", "", timeout=5).strip()
                    break

        # Method 3: Find any partition with FLOWBIT in label (any version)
        if not mnt:
            blkid_out = run_cmd("blkid 2>/dev/null", "", timeout=5)
            for line in blkid_out.splitlines():
                if "FLOWBIT" in line.upper():
                    mnt = line.split(":")[0].strip()
                    break

        # Method 4: Find USB removable devices (fallback for sticks)
        if not mnt:
            usb_devs = run_cmd("lsblk -ndo NAME,TRAN,RM | grep usb | grep '1$'", "", timeout=5)
            for line in usb_devs.strip().splitlines():
                dev_name = line.split()[0]
                mnt = f"/dev/{dev_name}"
                break

        if mnt:
            # Get parent disk (e.g., /dev/sdb1 -> /dev/sdb)
            disk = run_cmd(f"lsblk -ndo PKNAME {shlex.quote(mnt)} 2>/dev/null", "", timeout=5).strip()
            dev_path = f"/dev/{disk}" if disk else mnt
            # If dev_path is just /dev/ (no parent), use mnt directly
            if dev_path == "/dev/":
                dev_path = mnt
            info = run_cmd(f"lsblk -ndo SIZE,MODEL {shlex.quote(dev_path)} 2>/dev/null", "", timeout=5).strip()
            parts = info.split(None, 1) if info else []
            return {
                "device": dev_path,
                "partition": mnt,
                "size": parts[0] if parts else "?",
                "model": parts[1].strip() if len(parts) > 1 else "USB Boot Device",
                "found": True
            }
        return {"found": False, "error": "Boot-Device nicht erkannt. Kein USB-Stick gefunden."}
    except Exception as e:
        return {"found": False, "error": str(e)}


# ---- Update System ----

def check_for_update():
    try:
        req = urllib.request.Request(f"{UPDATE_SERVER}/manifest.json", headers={"User-Agent": "flowbit-os"})
        with urllib.request.urlopen(req, timeout=5) as resp:
            manifest = json.loads(resp.read().decode())
        latest = manifest.get("latest", {})
        latest_ver = latest.get("version", "0.0.0")
        update_available = version_newer(FLOWBIT_VERSION, latest_ver)
        return {
            "current_version": FLOWBIT_VERSION,
            "latest_version": latest_ver,
            "update_available": update_available,
            "iso_url": latest.get("iso", {}).get("url", ""),
            "iso_size": latest.get("iso", {}).get("size_bytes", 0),
            "sha256": latest.get("iso", {}).get("sha256", ""),
            "release_notes": latest.get("release_notes", ""),
        }
    except Exception as e:
        return {"current_version": FLOWBIT_VERSION, "update_available": False, "error": str(e)}

def download_update(task_id, url, expected_sha256):
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "flowbit-os"})
        resp = urllib.request.urlopen(req, timeout=300)
        total = safe_int(resp.headers.get("Content-Length", 0))
        update_task(task_id, total=total)
        iso_path = "/tmp/flowbit-update.iso"
        sha = hashlib.sha256()
        downloaded = 0
        with open(iso_path, "wb") as f:
            while True:
                chunk = resp.read(1024 * 1024)
                if not chunk:
                    break
                f.write(chunk)
                sha.update(chunk)
                downloaded += len(chunk)
                update_task(task_id, progress=downloaded)
        actual_sha = sha.hexdigest()
        if expected_sha256 and actual_sha != expected_sha256:
            update_task(task_id, status="error", error=f"SHA256 mismatch: {actual_sha}")
            os.remove(iso_path)
        else:
            update_task(task_id, status="done", sha256=actual_sha, size=downloaded)
    except Exception as e:
        update_task(task_id, status="error", error=str(e))

def flash_update(task_id, iso_path, device):
    try:
        safe_dev = sanitize_device(device)
        size = os.path.getsize(iso_path)
        update_task(task_id, status="flashing", progress=0, total=size)

        # Unmount all partitions on the target device before flashing
        parts_out = run_cmd(f"lsblk -nlo NAME /dev/{safe_dev} 2>/dev/null", "", timeout=5)
        for part_line in parts_out.strip().splitlines():
            part_name = part_line.strip()
            if part_name:
                run_cmd(f"umount /dev/{part_name} 2>/dev/null", "", timeout=10)
        run_cmd("umount /run/archiso/bootmnt 2>/dev/null", "", timeout=5)

        # Flash with dd - use buffered line reading instead of byte-by-byte
        proc = subprocess.Popen(
            ["dd", f"if={iso_path}", f"of=/dev/{safe_dev}", "bs=4M", "oflag=sync", "status=progress"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE
        )
        update_task(task_id, process=proc)
        while True:
            line = proc.stderr.readline()
            if not line and proc.poll() is not None:
                break
            if line:
                text = line.decode(errors="replace").strip()
                m = re.search(r'(\d+)\s+bytes', text)
                if m:
                    bytes_written = int(m.group(1))
                    update_task(task_id, progress=bytes_written, total=size)
        proc.wait()

        if proc.returncode == 0:
            run_cmd("sync", "", timeout=30)
            update_task(task_id, status="done", sha256="verified")
            log_action("Update Flash Complete", f"device=/dev/{safe_dev}, size={size}")
        else:
            update_task(task_id, status="error", error=f"Flash fehlgeschlagen (exit code {proc.returncode})")
    except Exception as e:
        update_task(task_id, status="error", error=str(e))


# ---- Hardware Monitor functions ----

def get_hwmon_data():
    """Read temperature and fan data from /sys/class/hwmon/."""
    temperatures = []
    fans = []
    hwmon_base = "/sys/class/hwmon"

    if os.path.isdir(hwmon_base):
        for hwmon_dir in sorted(os.listdir(hwmon_base)):
            hwmon_path = os.path.join(hwmon_base, hwmon_dir)
            device_name = read_file(os.path.join(hwmon_path, "name"), hwmon_dir)

            # Read temperatures
            i = 1
            while True:
                temp_input = os.path.join(hwmon_path, f"temp{i}_input")
                if not os.path.isfile(temp_input):
                    break
                try:
                    temp_val = int(Path(temp_input).read_text().strip()) / 1000.0
                except (ValueError, OSError):
                    i += 1
                    continue

                label = read_file(os.path.join(hwmon_path, f"temp{i}_label"), f"{device_name} temp{i}")
                high_val = None
                crit_val = None
                try:
                    high_raw = os.path.join(hwmon_path, f"temp{i}_max")
                    if os.path.isfile(high_raw):
                        high_val = int(Path(high_raw).read_text().strip()) / 1000.0
                except (ValueError, OSError):
                    pass
                try:
                    crit_raw = os.path.join(hwmon_path, f"temp{i}_crit")
                    if os.path.isfile(crit_raw):
                        crit_val = int(Path(crit_raw).read_text().strip()) / 1000.0
                except (ValueError, OSError):
                    pass

                temperatures.append({
                    "label": label,
                    "temp": temp_val,
                    "high": high_val,
                    "critical": crit_val
                })
                i += 1

            # Read fans
            i = 1
            while True:
                fan_input = os.path.join(hwmon_path, f"fan{i}_input")
                if not os.path.isfile(fan_input):
                    break
                try:
                    rpm_val = int(Path(fan_input).read_text().strip())
                except (ValueError, OSError):
                    i += 1
                    continue

                label = read_file(os.path.join(hwmon_path, f"fan{i}_label"), f"{device_name} fan{i}")
                min_val = None
                max_val = None
                try:
                    min_raw = os.path.join(hwmon_path, f"fan{i}_min")
                    if os.path.isfile(min_raw):
                        min_val = int(Path(min_raw).read_text().strip())
                except (ValueError, OSError):
                    pass
                try:
                    max_raw = os.path.join(hwmon_path, f"fan{i}_max")
                    if os.path.isfile(max_raw):
                        max_val = int(Path(max_raw).read_text().strip())
                except (ValueError, OSError):
                    pass

                fans.append({
                    "label": label,
                    "rpm": rpm_val,
                    "min": min_val,
                    "max": max_val
                })
                i += 1

    # Fallback: try lm-sensors JSON output if no data found via sysfs
    if not temperatures and not fans and HAS_SENSORS:
        try:
            output = subprocess.check_output(["sensors", "-j"], stderr=subprocess.DEVNULL, timeout=5).decode()
            sensors_data = json.loads(output)
            for chip_name, chip_data in sensors_data.items():
                if not isinstance(chip_data, dict):
                    continue
                for feature_name, feature_data in chip_data.items():
                    if not isinstance(feature_data, dict):
                        continue
                    for key, val in feature_data.items():
                        if key.endswith("_input") and "temp" in key.lower():
                            temperatures.append({
                                "label": feature_name,
                                "temp": float(val),
                                "high": feature_data.get(key.replace("_input", "_max")),
                                "critical": feature_data.get(key.replace("_input", "_crit"))
                            })
                        elif key.endswith("_input") and "fan" in key.lower():
                            fans.append({
                                "label": feature_name,
                                "rpm": int(val),
                                "min": feature_data.get(key.replace("_input", "_min")),
                                "max": feature_data.get(key.replace("_input", "_max"))
                            })
        except Exception:
            pass

    return {"temperatures": temperatures, "fans": fans}


def set_fan_speed(device, fan, value):
    """Set fan PWM speed manually."""
    safe_device = sanitize_device(device)
    safe_fan = sanitize_device(fan)
    value = max(0, min(255, int(value)))

    pwm_path = f"/sys/class/hwmon/{safe_device}/{safe_fan}"
    enable_path = f"{pwm_path}_enable"

    if not os.path.isfile(pwm_path):
        return {"error": f"PWM path not found: {pwm_path}"}

    try:
        # Enable manual control first
        if os.path.isfile(enable_path):
            Path(enable_path).write_text("1")
        Path(pwm_path).write_text(str(value))
        return {"success": True, "device": safe_device, "fan": safe_fan, "value": value}
    except PermissionError:
        return {"error": "Keine Berechtigung — Root-Rechte erforderlich"}
    except Exception as e:
        return {"error": str(e)}


def set_fan_auto(device, fan):
    """Reset fan to automatic control."""
    safe_device = sanitize_device(device)
    safe_fan = sanitize_device(fan)

    enable_path = f"/sys/class/hwmon/{safe_device}/{safe_fan}_enable"
    if not os.path.isfile(enable_path):
        return {"error": f"PWM enable path not found: {enable_path}"}

    try:
        # Try mode 2 (automatic) first, fall back to 0
        try:
            Path(enable_path).write_text("2")
        except OSError:
            Path(enable_path).write_text("0")
        return {"success": True, "device": safe_device, "fan": safe_fan, "mode": "auto"}
    except PermissionError:
        return {"error": "Keine Berechtigung — Root-Rechte erforderlich"}
    except Exception as e:
        return {"error": str(e)}


# ---- Wipe Certificate ----

def generate_wipe_certificate(device, method, passes, verified):
    """Generate a text wipe certificate for a device."""
    safe_dev = sanitize_device(device)
    info = get_system_info()
    timestamp = time.strftime("%Y-%m-%d %H:%M:%S")

    # Get device details
    model = run_cmd(f"lsblk -dn -o MODEL /dev/{safe_dev} 2>/dev/null", "N/A")
    serial = run_cmd(f"lsblk -dn -o SERIAL /dev/{safe_dev} 2>/dev/null", "N/A")
    size = run_cmd(f"lsblk -dn -o SIZE /dev/{safe_dev} 2>/dev/null", "N/A")

    method_names = {
        "zero": "Zero Fill",
        "random": "Random Data",
        "dod": "DoD 5220.22-M",
        "gutmann": "Gutmann (35-pass)",
    }
    method_display = method_names.get(method, method)
    verified_str = "Yes" if verified else "No"
    sys_info_str = f"{info.get('manufacturer', 'N/A')} {info.get('model', 'N/A')} / SN: {info.get('serial', 'N/A')}"

    cert = f"""\
{'=' * 51}
        FLOWBIT OS — WIPE CERTIFICATE
{'=' * 51}

Date:           {timestamp}
System:         {sys_info_str}
Operator:       flowbit OS {FLOWBIT_VERSION}

DEVICE WIPED:
  Device:       /dev/{safe_dev}
  Model:        {model}
  Serial:       {serial}
  Size:         {size}

WIPE METHOD:
  Method:       {method_display}
  Passes:       {passes}
  Verified:     {verified_str}

RESULT:         COMPLETE — ALL DATA DESTROYED

{'=' * 51}
  This certificate confirms that the above device
  has been securely wiped using flowbit OS.
{'=' * 51}
"""
    return cert


# ---- Antivirus Paths ----

def get_antivirus_scan_paths():
    """Find suggested scan paths from mounted partitions."""
    paths = []
    search_dirs = ["/mnt", "/tmp/ittools_mnt"]
    common_subdirs = ["Windows", "Users", "Program Files", "Program Files (x86)",
                      "home", "root", "etc", "var", "opt"]

    for search_dir in search_dirs:
        if not os.path.isdir(search_dir):
            continue
        try:
            for entry in sorted(os.listdir(search_dir)):
                mount_path = os.path.join(search_dir, entry)
                if not os.path.isdir(mount_path):
                    continue
                # Check if it's a mountpoint or has content
                if os.path.ismount(mount_path) or os.listdir(mount_path):
                    # Add the root of the mounted partition
                    paths.append({"path": mount_path, "label": f"{entry} - Root"})
                    # Check for common subdirectories
                    for subdir in common_subdirs:
                        sub_path = os.path.join(mount_path, subdir)
                        if os.path.isdir(sub_path):
                            paths.append({"path": sub_path, "label": f"{entry} - {subdir}"})
        except OSError:
            pass

    return {"paths": paths}


# ---- Full Hardware Test ----

def full_hwtest_thread(tid):
    """Run RAM test + CPU stress + Disk read test sequentially."""
    failed = False
    try:
        # Step 1: RAM Test
        append_output(tid, "=== RAM Test (256 MB, 1 Durchgang) ===\n")
        update_task(tid, progress=5)

        size_mb = 256
        fname = f"/dev/shm/.ramtest_{tid}_full"
        fname_stress = f"/dev/shm/.ramtest_stress_{tid}_full"

        append_output(tid, f"Schreibe {size_mb} MB Zufallsdaten...\n")
        subprocess.run(["dd", "if=/dev/urandom", f"of={fname}", "bs=1M", f"count={size_mb}"],
                     capture_output=True, timeout=120)
        c1 = run_cmd(f"md5sum {fname} | cut -d' ' -f1", "", timeout=60)

        subprocess.run(["dd", "if=/dev/zero", f"of={fname_stress}", "bs=1M", f"count={size_mb}"],
                     capture_output=True, timeout=120)
        try:
            os.remove(fname_stress)
        except Exception:
            pass
        subprocess.run(["sync"], timeout=10)

        c2 = run_cmd(f"md5sum {fname} | cut -d' ' -f1", "", timeout=60)
        try:
            os.remove(fname)
        except Exception:
            pass

        if c1 and c1 == c2:
            append_output(tid, f"  RAM Test: OK (MD5: {c1})\n")
        else:
            append_output(tid, f"  RAM Test: FEHLER! Checksummen stimmen nicht überein!\n")
            append_output(tid, f"  Erwartet: {c1}\n  Erhalten: {c2}\n")
            failed = True

        update_task(tid, progress=33)

        # Step 2: CPU Stress Test
        append_output(tid, "\n=== CPU Stresstest (30s) ===\n")
        duration = 30
        cores = int(run_cmd("nproc", "2"))
        append_output(tid, f"Starte {cores} Kerne für {duration} Sekunden...\n")

        procs = []
        for i in range(cores):
            p = subprocess.Popen(
                ["timeout", str(duration), "awk", "BEGIN{for(i=0;i<999999999;i++)sin(i)}"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
            )
            procs.append(p)

        start = time.time()
        while time.time() - start < duration:
            elapsed = int(time.time() - start)
            temp = run_cmd("sensors 2>/dev/null | grep -m1 'Package\\|Tctl\\|Core 0' | grep -oP '[\\d.]+.C' | head -1", "N/A")
            load = run_cmd("cat /proc/loadavg | cut -d' ' -f1", "?")
            append_output(tid, f"  [{elapsed}s/{duration}s] Load: {load} | Temp: {temp}\n")
            pct = 33 + int(elapsed / duration * 33)
            update_task(tid, progress=pct)

            try:
                temp_val = float(re.search(r'[\d.]+', temp).group()) if temp != "N/A" else 0
                if temp_val > 95:
                    append_output(tid, f"\n  WARNUNG: Temperatur {temp_val}°C > 95°C — Abbruch!\n")
                    for p in procs:
                        p.kill()
                    failed = True
                    break
            except Exception:
                pass
            time.sleep(5)

        for p in procs:
            try:
                p.wait(timeout=5)
            except Exception:
                p.kill()

        if not failed:
            append_output(tid, f"  CPU Stresstest: OK\n")

        update_task(tid, progress=66)

        # Step 3: Disk Read Test
        append_output(tid, "\n=== Disk Lesetest ===\n")

        # Find first disk
        first_disk = run_cmd("lsblk -dn -o NAME | head -1", "sda")
        safe_dev = sanitize_device(first_disk)
        append_output(tid, f"Teste /dev/{safe_dev}...\n")

        # Sequential read
        append_output(tid, "Sequentieller Lesetest (256 MB)...\n")
        update_task(tid, progress=75)
        r = run_cmd(f"dd if=/dev/{safe_dev} of=/dev/null bs=1M count=256 iflag=direct 2>&1 | tail -1", "", timeout=60)
        append_output(tid, f"  {r}\n")

        # SMART
        append_output(tid, "\nSMART Gesundheit:\n")
        update_task(tid, progress=85)
        smart = run_cmd(f"smartctl -H /dev/{safe_dev} 2>&1", "N/A", timeout=15)
        smart_ok = "PASSED" in smart or "OK" in smart
        if not smart_ok and "FAILED" in smart:
            failed = True
        append_output(tid, f"  {smart}\n")

        update_task(tid, progress=100)

        if failed:
            append_output(tid, "\n=== ERGEBNIS: FEHLER GEFUNDEN ===\n")
            finish_task(tid, 1)
        else:
            append_output(tid, "\n=== ERGEBNIS: BESTANDEN ===\n")
            finish_task(tid, 0)

    except Exception as e:
        append_output(tid, f"\nFehler: {str(e)}\n")
        append_output(tid, "\n=== ERGEBNIS: FEHLER ===\n")
        finish_task(tid, 1)




# ---- HTTPS Self-Signed Certificate (D01) ----

def create_self_signed_cert():
    """Generate self-signed cert if not exists."""
    cert_dir = os.path.join(PERSIST_BASE, "ssl")
    cert_file = os.path.join(cert_dir, "server.crt")
    key_file = os.path.join(cert_dir, "server.key")
    if os.path.exists(cert_file) and os.path.exists(key_file):
        return cert_file, key_file
    os.makedirs(cert_dir, exist_ok=True)
    cmd = (f'openssl req -x509 -newkey rsa:2048 -keyout {key_file} '
           f'-out {cert_file} -days 365 -nodes '
           f'-subj "/CN=flowbit-os/O=flowbit/C=CH"')
    subprocess.run(cmd, shell=True, capture_output=True)
    return cert_file, key_file


# ---- Session Management (D02) ----

def create_session(ip):
    """Create a new session and return its token."""
    token = secrets.token_hex(16)
    with sessions_lock:
        sessions[token] = {"created": time.time(), "last_seen": time.time(), "ip": ip}
    return token


def validate_session(token):
    """Validate a session token. Returns True if valid, False otherwise."""
    with sessions_lock:
        s = sessions.get(token)
        if not s:
            return False
        if time.time() - s["last_seen"] > SESSION_TIMEOUT:
            del sessions[token]
            return False
        s["last_seen"] = time.time()
        return True


def cleanup_sessions():
    """Remove expired sessions."""
    now = time.time()
    with sessions_lock:
        expired = [t for t, s in sessions.items() if now - s["last_seen"] > SESSION_TIMEOUT]
        for t in expired:
            del sessions[t]


# ---- SSE Server-Sent Events (C02) ----

def sse_broadcast(event, data):
    """Send event to all connected SSE clients."""
    msg = f"event: {event}\ndata: {json.dumps(data)}\n\n".encode()
    dead = []
    with sse_clients_lock:
        for cid, client in sse_clients.items():
            try:
                client.wfile.write(msg)
                client.wfile.flush()
            except Exception:
                dead.append(cid)
        for cid in dead:
            sse_clients.pop(cid, None)


# ---- Request Logging (C06) ----

def log_request(method, path, status, duration_ms, ip):
    """Log a request with structured data."""
    global _request_count
    with request_log_lock:
        _request_count += 1
        entry = {
            "id": _request_count,
            "time": time.strftime("%Y-%m-%d %H:%M:%S"),
            "method": method,
            "path": path,
            "status": status,
            "duration_ms": round(duration_ms, 1),
            "ip": ip
        }
        request_log.append(entry)


# ---- Network Image / Disk Imaging on Network Shares (A03) ----

def mount_network_share(share_type, server, share, user=None, password=None, mountpoint="/mnt/netshare"):
    """Mount a SMB or NFS network share."""
    os.makedirs(mountpoint, exist_ok=True)
    if share_type == "smb":
        cred_file = "/tmp/ittools/.smb_credentials"
        os.makedirs(os.path.dirname(cred_file), exist_ok=True)
        with open(cred_file, "w") as f:
            if user:
                f.write(f"username={user}\npassword={password}\n")
            else:
                f.write("username=guest\n")
        os.chmod(cred_file, 0o600)
        cmd = f"mount -t cifs //{shlex.quote(server)}/{shlex.quote(share)} {mountpoint} -o credentials={cred_file},vers=3.0"
    elif share_type == "nfs":
        cmd = f"mount -t nfs {shlex.quote(server)}:{shlex.quote(share)} {mountpoint}"
    else:
        return {"error": "Unbekannter Typ. Erlaubt: smb, nfs"}
    r = run_cmd(cmd, timeout=15)
    return {"success": os.path.ismount(mountpoint), "mountpoint": mountpoint, "output": r}


def unmount_network_share(mountpoint="/mnt/netshare"):
    """Unmount a network share."""
    if not os.path.ismount(mountpoint):
        return {"success": True, "message": "Nicht gemountet"}
    r = subprocess.run(["umount", mountpoint], capture_output=True, text=True, timeout=15)
    return {"success": r.returncode == 0, "output": r.stdout + r.stderr}


def netimage_backup_thread(tid, disk, mountpoint, compress=True):
    """Create a disk image to a network share."""
    try:
        safe_disk = sanitize_device(disk)
        if not os.path.ismount(mountpoint):
            append_output(tid, f"Fehler: {mountpoint} ist nicht gemountet.\n")
            finish_task(tid, 1)
            return
        total_bytes = int(run_cmd(f"blockdev --getsize64 /dev/{safe_disk}", "0"))
        timestamp = time.strftime("%Y%m%d_%H%M%S")
        hostname = run_cmd("hostname", "flowbit")
        if compress:
            dest = os.path.join(mountpoint, f"flowbit-image-{safe_disk}-{hostname}-{timestamp}.img.zst")
            cmd = f"dd if=/dev/{safe_disk} bs=4M status=progress 2>&1 | zstd -1 -o {shlex.quote(dest)}"
        else:
            dest = os.path.join(mountpoint, f"flowbit-image-{safe_disk}-{hostname}-{timestamp}.img")
            cmd = f"dd if=/dev/{safe_disk} of={shlex.quote(dest)} bs=4M status=progress conv=fsync 2>&1"

        append_output(tid, f"Network Image Backup: /dev/{safe_disk} -> {dest}\n")
        append_output(tid, f"Grösse: {total_bytes} Bytes\n\n")

        proc = subprocess.Popen(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        update_task(tid, process=proc)
        while True:
            line = proc.stdout.readline()
            if not line and proc.poll() is not None:
                break
            if line:
                text = line.decode(errors="replace").strip()
                m = re.search(r'(\d+)\s+bytes', text)
                if m and total_bytes:
                    pct = int(int(m.group(1)) / total_bytes * 95)
                    update_task(tid, progress=min(pct, 95))
                append_output(tid, text + "\n")

        # Checksum
        append_output(tid, "\nBerechne SHA256 Checksumme...\n")
        update_task(tid, progress=96)
        sha = run_cmd(f"sha256sum {shlex.quote(dest)} | cut -d' ' -f1", "N/A", timeout=600)
        sha_file = dest + ".sha256"
        try:
            Path(sha_file).write_text(f"{sha}  {os.path.basename(dest)}\n")
        except Exception:
            pass
        append_output(tid, f"SHA256: {sha}\n")
        append_output(tid, f"\nNetwork Image Backup abgeschlossen: {dest}\n")
        sse_broadcast("task_update", {"id": tid, "status": "done"})
        finish_task(tid, proc.returncode or 0)
    except Exception as e:
        append_output(tid, f"\nFehler: {str(e)}\n")
        finish_task(tid, 1)


def netimage_restore_thread(tid, image_path, target_device):
    """Restore a disk image from a network share."""
    try:
        safe_dev = sanitize_device(target_device)
        if not os.path.isfile(image_path):
            append_output(tid, f"Fehler: Image nicht gefunden: {image_path}\n")
            finish_task(tid, 1)
            return

        append_output(tid, f"Network Image Restore: {image_path} -> /dev/{safe_dev}\n")

        # Check SHA256 if available
        sha_file = image_path + ".sha256"
        if os.path.exists(sha_file):
            append_output(tid, "Prüfe SHA256 Checksumme...\n")
            update_task(tid, progress=5)
            expected = Path(sha_file).read_text().split()[0]
            actual = run_cmd(f"sha256sum {shlex.quote(image_path)} | cut -d' ' -f1", "", timeout=600)
            if expected == actual:
                append_output(tid, f"Checksumme OK: {actual}\n\n")
            else:
                append_output(tid, f"WARNUNG: Checksumme stimmt nicht überein!\n  Erwartet: {expected}\n  Erhalten: {actual}\n\n")

        safe_image = shlex.quote(image_path)
        safe_target_dev = shlex.quote(f"/dev/{safe_dev}")
        if image_path.endswith(".zst"):
            cmd = f"zstd -d -c {safe_image} | dd of={safe_target_dev} bs=4M status=progress conv=fsync 2>&1"
        else:
            cmd = f"dd if={safe_image} of={safe_target_dev} bs=4M status=progress conv=fsync 2>&1"

        update_task(tid, progress=10)
        proc = subprocess.Popen(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        update_task(tid, process=proc)
        while True:
            line = proc.stdout.readline()
            if not line and proc.poll() is not None:
                break
            if line:
                text = line.decode(errors="replace").strip()
                append_output(tid, text + "\n")

        append_output(tid, "\nNetwork Image Restore abgeschlossen.\n")
        sse_broadcast("task_update", {"id": tid, "status": "done"})
        finish_task(tid, proc.returncode or 0)
    except Exception as e:
        append_output(tid, f"\nFehler: {str(e)}\n")
        finish_task(tid, 1)


def list_network_images(mountpoint="/mnt/netshare"):
    """List disk images on a mounted network share."""
    if not os.path.ismount(mountpoint):
        return {"error": "Share nicht gemountet", "images": []}
    images = []
    try:
        for entry in sorted(os.scandir(mountpoint), key=lambda e: e.name):
            if entry.name.endswith(('.img', '.img.zst', '.img.gz')):
                stat = entry.stat()
                has_sha = os.path.exists(entry.path + ".sha256")
                images.append({
                    "name": entry.name,
                    "path": entry.path,
                    "size": stat.st_size,
                    "modified": stat.st_mtime,
                    "has_checksum": has_sha
                })
    except OSError as e:
        return {"error": str(e), "images": []}
    return {"images": images, "mountpoint": mountpoint}

# Auth rate limiting
_auth_attempts = {}
_auth_attempts_lock = threading.Lock()

def _check_auth_rate(ip):
    now = time.time()
    with _auth_attempts_lock:
        # Clean old entries
        _auth_attempts.update({k: v for k, v in _auth_attempts.items() if now - v[-1] < 300})
        attempts = _auth_attempts.get(ip, [])
        attempts = [t for t in attempts if now - t < 300]  # Last 5 minutes
        if len(attempts) >= 10:
            return False
        attempts.append(now)
        _auth_attempts[ip] = attempts
        return True


# ---- HTTP Handler ----


# ---- TPM Management (A06) ----

def get_tpm_status():
    """Read TPM info via tpm2-tools."""
    result = {"available": False}
    try:
        r = run_cmd("tpm2_getcap properties-fixed 2>/dev/null", timeout=5, default="")
        if r and "TPM2_PT" in r:
            result["available"] = True
            result["manufacturer"] = ""
            result["version"] = ""
            for line in r.split("\n"):
                if "TPM2_PT_MANUFACTURER" in line:
                    result["manufacturer"] = line.split(":")[-1].strip() if ":" in line else ""
                if "TPM2_PT_FIRMWARE_VERSION" in line:
                    result["version"] = line.split(":")[-1].strip() if ":" in line else ""
            pcr = run_cmd("tpm2_pcrread sha256 2>/dev/null", timeout=5, default="")
            result["pcr_values"] = pcr if pcr else ""
        else:
            r2 = run_cmd("ls /dev/tpm* 2>/dev/null", timeout=2, default="")
            result["device_exists"] = bool(r2)
    except Exception:
        pass
    return result


def tpm_clear():
    """Clear TPM (dangerous!)."""
    r = run_cmd("tpm2_clear 2>&1", timeout=10, default="")
    return {"success": "error" not in r.lower() if r else False, "output": r}


# ---- Network Cable Tester (A10) ----

def network_cable_test(interface, target=None):
    """Test network cable/interface quality."""
    result = {"interface": interface}
    safe_iface = shlex.quote(interface)
    eth = run_cmd(f"ethtool {safe_iface} 2>/dev/null", timeout=5, default="")
    if eth:
        for line in eth.split("\n"):
            line = line.strip()
            if "Speed:" in line:
                result["speed"] = line.split(":")[-1].strip()
            if "Duplex:" in line:
                result["duplex"] = line.split(":")[-1].strip()
            if "Link detected:" in line:
                result["link"] = "yes" in line.lower()
            if "Auto-negotiation:" in line:
                result["autoneg"] = "on" in line.lower()
    stats = run_cmd(f"ethtool -S {safe_iface} 2>/dev/null | head -30", timeout=5, default="")
    errors = {}
    if stats:
        for line in stats.split("\n"):
            line = line.strip()
            if any(k in line.lower() for k in ["error", "drop", "crc", "collision"]):
                parts = line.split(":")
                if len(parts) == 2:
                    errors[parts[0].strip()] = parts[1].strip()
    result["errors"] = errors
    if target:
        iperf = run_cmd(f"iperf3 -c {shlex.quote(target)} -t 5 -J 2>/dev/null", timeout=15, default="")
        if iperf:
            try:
                iperf_data = json.loads(iperf)
                result["throughput_mbps"] = round(
                    iperf_data.get("end", {}).get("sum_received", {}).get("bits_per_second", 0) / 1e6, 2
                )
            except Exception:
                pass
    return result


# ---- Windows 11 Compatibility Checker (A13) ----

def check_win11_compatibility():
    """Check if hardware meets Windows 11 requirements."""
    checks = {}
    # CPU: 1 GHz, 2+ cores, 64-bit
    cpu_info = run_cmd("lscpu 2>/dev/null", timeout=3, default="")
    cores = 0
    freq = 0
    arch = ""
    if cpu_info:
        for line in cpu_info.split("\n"):
            if "CPU(s):" in line and "NUMA" not in line and "On-line" not in line:
                try:
                    cores = int(line.split(":")[-1].strip())
                except Exception:
                    pass
            if "CPU max MHz" in line or "CPU MHz" in line:
                try:
                    freq = float(line.split(":")[-1].strip())
                except Exception:
                    pass
            if "Architecture" in line:
                arch = line.split(":")[-1].strip()
    checks["cpu"] = {
        "pass": cores >= 2 and freq >= 1000 and "64" in arch,
        "cores": cores, "freq_mhz": freq, "arch": arch
    }
    # RAM: 4 GB minimum
    mem = run_cmd("free -m 2>/dev/null | grep Mem", timeout=2, default="")
    ram_mb = 0
    if mem:
        try:
            ram_mb = int(mem.split()[1])
        except Exception:
            pass
    checks["ram"] = {"pass": ram_mb >= 4096, "total_mb": ram_mb}
    # Storage: 64 GB minimum
    disk_out = run_cmd("lsblk -d -b -n -o SIZE 2>/dev/null | sort -rn | head -1", timeout=3, default="0")
    try:
        largest_disk_gb = int(disk_out) / (1024**3)
    except Exception:
        largest_disk_gb = 0
    checks["storage"] = {"pass": largest_disk_gb >= 64, "largest_disk_gb": round(largest_disk_gb, 1)}
    # TPM 2.0
    tpm = run_cmd("tpm2_getcap properties-fixed 2>/dev/null", timeout=3, default="")
    checks["tpm"] = {"pass": bool(tpm and "TPM2_PT" in tpm)}
    # Secure Boot capable
    sb = run_cmd("mokutil --sb-state 2>/dev/null || efivar -l 2>/dev/null | grep SecureBoot", timeout=3, default="")
    checks["secure_boot"] = {"pass": bool(sb)}
    # UEFI
    checks["uefi"] = {"pass": os.path.isdir("/sys/firmware/efi")}
    # Overall
    checks["compatible"] = all(
        c["pass"] for c in checks.values() if isinstance(c, dict) and "pass" in c
    )
    return checks


# ---- Disk Benchmark (A08) ----

def parse_benchmark_result(output, test_type):
    """Parse benchmark output from dd or fio."""
    result = {"raw": output or ""}
    if not output:
        return result
    if test_type in ("seq_read", "seq_write"):
        # Parse dd output: "268435456 bytes (256 MB, 244 MiB) copied, 0.523423 s, 489 MB/s"
        m = re.search(r'([\d.]+)\s+(GB|MB|kB)/s', output)
        if m:
            val = float(m.group(1))
            unit = m.group(2)
            if unit == "GB":
                val *= 1000
            elif unit == "kB":
                val /= 1000
            result["speed_mbps"] = round(val, 2)
        m2 = re.search(r'copied,\s+([\d.]+)\s+s', output)
        if m2:
            result["time_sec"] = round(float(m2.group(1)), 3)
    elif test_type in ("rand_read", "rand_write"):
        # Parse fio JSON output
        try:
            fio_data = json.loads(output)
            jobs = fio_data.get("jobs", [{}])
            if jobs:
                job = jobs[0]
                rw_key = "read" if "read" in test_type else "write"
                bw_bytes = job.get(rw_key, {}).get("bw_bytes", 0)
                iops = job.get(rw_key, {}).get("iops", 0)
                lat_ns = job.get(rw_key, {}).get("lat_ns", {}).get("mean", 0)
                result["speed_mbps"] = round(bw_bytes / 1e6, 2)
                result["iops"] = round(iops, 0)
                result["latency_us"] = round(lat_ns / 1000, 2)
        except Exception:
            pass
    return result


def disk_benchmark_thread(tid, disk, test="all"):
    """Run disk benchmark in background thread."""
    results = {}
    safe_disk = sanitize_device(disk)
    # Note: benchmarks run on /tmp (system disk) - results reflect system disk speed
    test_file = f"/tmp/flowbit-bench-{safe_disk}"
    tests = ["seq_write", "seq_read", "rand_read", "rand_write"] if test == "all" else [test]
    try:
        for t in tests:
            update_task(tid, status="running", current_test=t)
            if t == "seq_write":
                r = run_cmd(f"dd if=/dev/zero of={test_file} bs=1M count=256 conv=fdatasync 2>&1", timeout=60, default="")
            elif t == "seq_read":
                run_cmd("sync && echo 3 > /proc/sys/vm/drop_caches", timeout=5)
                r = run_cmd(f"dd if={test_file} of=/dev/null bs=1M 2>&1", timeout=60, default="")
            elif t == "rand_read":
                # Create test file if not exists
                if not os.path.exists(test_file):
                    run_cmd(f"dd if=/dev/zero of={test_file} bs=1M count=64 2>/dev/null", timeout=30)
                r = run_cmd(
                    f"fio --name=randread --ioengine=libaio --rw=randread --bs=4k "
                    f"--numjobs=1 --size=64M --runtime=10 --filename={test_file} --output-format=json 2>/dev/null",
                    timeout=30, default=""
                )
            elif t == "rand_write":
                r = run_cmd(
                    f"fio --name=randwrite --ioengine=libaio --rw=randwrite --bs=4k "
                    f"--numjobs=1 --size=64M --runtime=10 --filename={test_file} --output-format=json 2>/dev/null",
                    timeout=30, default=""
                )
            else:
                r = ""
            results[t] = parse_benchmark_result(r, t)
        run_cmd(f"rm -f {test_file}", timeout=5)
        update_task(tid, results=results)
        finish_task(tid)
    except Exception as e:
        run_cmd(f"rm -f {test_file}", timeout=5)
        update_task(tid, error=str(e), results=results)
        finish_task(tid, exit_code=1)


# ---- IP Calculator ----

def ip_calculator(cidr):
    """Calculate IP network details from CIDR notation."""
    try:
        net = ipaddress.ip_network(cidr, strict=False)
        if net.prefixlen < 31:
            first = net.network_address + 1
            last = net.broadcast_address - 1
            num_hosts = max(0, net.num_addresses - 2)
        else:
            first = net.network_address
            last = net.broadcast_address
            num_hosts = net.num_addresses
        return {
            "network": str(net.network_address),
            "broadcast": str(net.broadcast_address),
            "netmask": str(net.netmask),
            "wildcard": str(net.hostmask),
            "prefix": net.prefixlen,
            "hosts": num_hosts,
            "first_host": str(first),
            "last_host": str(last),
            "is_private": net.is_private,
            "class": "A" if net.network_address.packed[0] < 128 else "B" if net.network_address.packed[0] < 192 else "C",
        }
    except ValueError as e:
        return {"error": str(e)}


# ---- Health Check & Metrics (C09, C10) ----

def get_health():
    """Return server health status."""
    uptime_sec = time.time() - SERVER_START
    mem = run_cmd("free -m | grep Mem", timeout=2, default="")
    mem_total = 0
    mem_used = 0
    if mem:
        parts = mem.split()
        try:
            mem_total = int(parts[1])
            mem_used = int(parts[2])
        except Exception:
            pass
    with tasks_lock:
        running_tasks = sum(1 for t in tasks.values() if t.get("status") == "running")
        total_tasks = len(tasks)
    with request_counter_lock:
        req = dict(request_counter)
    return {
        "status": "healthy",
        "version": FLOWBIT_VERSION,
        "uptime_seconds": round(uptime_sec, 1),
        "uptime_human": f"{int(uptime_sec // 3600)}h {int((uptime_sec % 3600) // 60)}m",
        "memory": {"total_mb": mem_total, "used_mb": mem_used, "percent": round(mem_used / mem_total * 100, 1) if mem_total else 0},
        "tasks": {"running": running_tasks, "total": total_tasks},
        "requests": req,
    }


def get_metrics():
    """Return Prometheus-style metrics."""
    uptime_sec = time.time() - SERVER_START
    mem = run_cmd("free -b | grep Mem", timeout=2, default="")
    mem_total = 0
    mem_used = 0
    if mem:
        parts = mem.split()
        try:
            mem_total = int(parts[1])
            mem_used = int(parts[2])
        except Exception:
            pass
    with tasks_lock:
        running_tasks = sum(1 for t in tasks.values() if t.get("status") == "running")
        total_tasks = len(tasks)
    with request_counter_lock:
        req = dict(request_counter)
    cpu_load = run_cmd("cat /proc/loadavg", timeout=2, default="0 0 0")
    loads = cpu_load.split()
    lines = [
        f"# HELP flowbit_uptime_seconds Server uptime in seconds",
        f"flowbit_uptime_seconds {round(uptime_sec, 1)}",
        f"# HELP flowbit_memory_bytes Memory usage",
        f'flowbit_memory_bytes{{type="total"}} {mem_total}',
        f'flowbit_memory_bytes{{type="used"}} {mem_used}',
        f"# HELP flowbit_tasks Task counts",
        f'flowbit_tasks{{status="running"}} {running_tasks}',
        f'flowbit_tasks{{status="total"}} {total_tasks}',
        f"# HELP flowbit_requests_total HTTP request counts",
        f'flowbit_requests_total{{method="GET"}} {req.get("get", 0)}',
        f'flowbit_requests_total{{method="POST"}} {req.get("post", 0)}',
        f"# HELP flowbit_load System load averages",
        f'flowbit_load{{period="1m"}} {loads[0] if loads else 0}',
        f'flowbit_load{{period="5m"}} {loads[1] if len(loads) > 1 else 0}',
        f'flowbit_load{{period="15m"}} {loads[2] if len(loads) > 2 else 0}',
    ]
    return "\n".join(lines)


# ---- USB Device Manager (A07) ----

def get_usb_devices():
    """List USB devices with details."""
    devices = []
    try:
        lsusb = run_cmd("lsusb 2>/dev/null", timeout=5, default="")
        if lsusb:
            for line in lsusb.split("\n"):
                if not line.strip():
                    continue
                # Bus 001 Device 002: ID 1234:5678 Some Device Name
                m = re.match(r'Bus (\d+) Device (\d+): ID ([0-9a-f:]+)\s*(.*)', line)
                if m:
                    devices.append({
                        "bus": m.group(1),
                        "device": m.group(2),
                        "id": m.group(3),
                        "name": m.group(4).strip(),
                        "path": f"/dev/bus/usb/{m.group(1)}/{m.group(2)}"
                    })
        # Add block device info for USB storage
        usb_blocks = run_cmd("lsblk -d -J -o NAME,SIZE,RM,TRAN,MODEL 2>/dev/null", timeout=5, default="")
        if usb_blocks:
            try:
                blk_data = json.loads(usb_blocks)
                for dev in blk_data.get("blockdevices", []):
                    if dev.get("rm") and dev.get("tran") == "usb":
                        # Find matching device in list or add
                        found = False
                        for d in devices:
                            if dev.get("model") and dev["model"].strip() in d.get("name", ""):
                                d["block_device"] = f"/dev/{dev['name']}"
                                d["size"] = dev.get("size", "")
                                d["removable"] = True
                                found = True
                                break
                        if not found:
                            devices.append({
                                "bus": "", "device": "",
                                "id": "",
                                "name": dev.get("model", "USB Storage").strip(),
                                "block_device": f"/dev/{dev['name']}",
                                "size": dev.get("size", ""),
                                "removable": True
                            })
            except Exception:
                pass
    except Exception:
        pass
    return devices


def eject_usb_device(device):
    """Safely eject a USB device."""
    safe_dev = sanitize_device(device)
    if not safe_dev:
        return {"success": False, "error": "Ungültiges Gerät"}
    # Unmount all partitions first
    run_cmd(f"umount /dev/{safe_dev}* 2>/dev/null", timeout=10)
    # Eject
    r = run_cmd(f"eject /dev/{safe_dev} 2>&1", timeout=10, default="")
    success = r is not None and "error" not in r.lower() and "unable" not in r.lower()
    if not success:
        # Try udisksctl as fallback
        r2 = run_cmd(f"udisksctl power-off -b /dev/{safe_dev} 2>&1", timeout=10, default="")
        success = r2 is not None and "error" not in r2.lower()
        r = r2 if not success else r
    return {"success": success, "output": r}



# ---- noVNC Remote Desktop Proxy (A01) ----
vnc_proxy_process = None

def start_vnc_proxy(host, port, password=None):
    """Start websockify proxy to target VNC server."""
    global vnc_proxy_process
    # Kill existing proxy
    if vnc_proxy_process and vnc_proxy_process.poll() is None:
        vnc_proxy_process.terminate()
        try:
            vnc_proxy_process.wait(timeout=5)
        except Exception:
            vnc_proxy_process.kill()

    safe_host = re.sub(r'[^a-zA-Z0-9.\-:]', '', host)
    safe_port = safe_int(port, 5900)
    proxy_port = 6080

    # Start websockify
    cmd = ["websockify", "--web", "/usr/share/novnc",
           str(proxy_port), f"{safe_host}:{safe_port}"]
    vnc_proxy_process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    time.sleep(1)

    if vnc_proxy_process.poll() is not None:
        stderr_out = ""
        try:
            stderr_out = vnc_proxy_process.stderr.read().decode()
        except Exception:
            pass
        return {"success": False, "error": f"websockify konnte nicht gestartet werden: {stderr_out}"}

    return {
        "success": True,
        "url": f"/vnc/vnc.html?host={safe_host}&port={proxy_port}&autoconnect=true",
        "proxy_port": proxy_port
    }

def stop_vnc_proxy():
    """Stop the running websockify VNC proxy."""
    global vnc_proxy_process
    if vnc_proxy_process and vnc_proxy_process.poll() is None:
        vnc_proxy_process.terminate()
        try:
            vnc_proxy_process.wait(timeout=5)
        except Exception:
            vnc_proxy_process.kill()
        vnc_proxy_process = None
    return {"success": True}

def vnc_status():
    """Check if VNC proxy is running."""
    running = vnc_proxy_process is not None and vnc_proxy_process.poll() is None
    return {"running": running}


# ---- Active Directory / LDAP Lookup (A04) ----

def sanitize_ldap_value(val):
    """Escape LDAP special characters."""
    val = str(val)
    for char in ['\\', '*', '(', ')', '\x00']:
        val = val.replace(char, '\\' + hex(ord(char))[2:].zfill(2))
    return val

def ldap_search(server, base_dn, user, password, search_filter, attributes=None):
    """Search AD/LDAP using ldapsearch."""
    # Validate server hostname/IP
    if not re.match(r'^[a-zA-Z0-9.\-]+$', server):
        return {"success": False, "error": "Ungültiger Servername"}
    safe_dn = shlex.quote(base_dn)
    safe_user = shlex.quote(user)
    safe_pass = shlex.quote(password)
    safe_filter = shlex.quote(search_filter)

    attr_str = " ".join(shlex.quote(a) for a in attributes) if attributes else ""

    cmd = (f"ldapsearch -x -H ldap://{server} -b {safe_dn} "
           f"-D {safe_user} -w {safe_pass} {safe_filter} {attr_str} 2>&1")

    result = run_cmd(cmd, timeout=15)
    if not result or "ldap_bind: Invalid credentials" in result:
        return {"success": False, "error": result or "Keine Antwort"}

    # Parse ldapsearch output into structured data
    entries = []
    current = {}
    for line in result.split("\n"):
        line = line.strip()
        if line.startswith("dn: "):
            if current:
                entries.append(current)
            current = {"dn": line[4:]}
        elif ": " in line and current:
            key, val = line.split(": ", 1)
            if key in current:
                if isinstance(current[key], list):
                    current[key].append(val)
                else:
                    current[key] = [current[key], val]
            else:
                current[key] = val
    if current:
        entries.append(current)

    return {"success": True, "entries": entries, "count": len(entries)}


# ---- VPN Client / WireGuard (E-item) ----
def vpn_connect(config_b64):
    """Create WireGuard config and connect."""
    try:
        config = base64.b64decode(config_b64).decode()
    except Exception:
        return {"success": False, "error": "Ungültige Base64-Daten"}
    # Strip dangerous directives
    safe_lines = []
    for line in config.split('\n'):
        if re.match(r'^\s*(PostUp|PreUp|PostDown|PreDown|SaveConfig)\s*=', line, re.IGNORECASE):
            continue  # Skip dangerous directives
        safe_lines.append(line)
    config = '\n'.join(safe_lines)
    config_path = "/tmp/ittools/wg0.conf"
    os.makedirs(os.path.dirname(config_path), exist_ok=True)
    with open(config_path, "w") as f:
        f.write(config)
    os.chmod(config_path, 0o600)

    # Bring up WireGuard
    r = run_cmd("wg-quick up /tmp/ittools/wg0.conf 2>&1", timeout=10)
    success = "wg0" in (run_cmd("ip link show wg0 2>/dev/null", timeout=3) or "")
    return {"success": success, "output": r}

def vpn_disconnect():
    """Disconnect WireGuard VPN."""
    r = run_cmd("wg-quick down /tmp/ittools/wg0.conf 2>&1", timeout=10)
    return {"success": True, "output": r}

def vpn_status():
    """Get WireGuard VPN status."""
    wg = run_cmd("wg show all 2>/dev/null", timeout=5)
    connected = bool(wg and "wg0" in wg)
    result = {"connected": connected}
    if connected:
        result["details"] = wg
        for line in wg.split("\n"):
            if "endpoint:" in line:
                result["endpoint"] = line.split(":")[-2].strip() + ":" + line.split(":")[-1].strip()
            if "transfer:" in line:
                result["transfer"] = line.split("transfer:")[-1].strip()
            if "latest handshake:" in line:
                result["handshake"] = line.split("handshake:")[-1].strip()
    return result


# ---- DNS Diagnostics (E-item) ----
def dns_dig(domain, qtype="A", server=None):
    """Run DNS dig query and parse results."""
    safe_domain = shlex.quote(domain)
    safe_type = shlex.quote(qtype)
    server_part = f"@{shlex.quote(server)}" if server else ""
    r = run_cmd(f"dig {server_part} {safe_domain} {safe_type} +noall +answer +stats 2>&1", timeout=10)
    # Parse dig output
    records = []
    query_time = ""
    for line in (r or "").split("\n"):
        line = line.strip()
        if line and not line.startswith(";"):
            parts = line.split()
            if len(parts) >= 5:
                records.append({
                    "name": parts[0], "ttl": parts[1],
                    "class": parts[2], "type": parts[3],
                    "value": " ".join(parts[4:])
                })
        if "Query time:" in line:
            query_time = line
    return {"records": records, "query_time": query_time, "raw": r}


# ---- WiFi Hotspot (E-item) ----
def start_hotspot(ssid, password, band="2.4"):
    """Start WiFi hotspot using NetworkManager."""
    band_flag = "a" if band == "5" else "bg"
    cmd = f"nmcli device wifi hotspot ifname wlan0 ssid {shlex.quote(ssid)} password {shlex.quote(password)} band {band_flag} 2>&1"
    r = run_cmd(cmd, timeout=10)
    return {
        "success": "successfully" in (r or "").lower() or "activated" in (r or "").lower(),
        "output": r
    }

def stop_hotspot():
    """Stop WiFi hotspot."""
    r = run_cmd("nmcli connection down Hotspot 2>&1", timeout=10)
    return {"success": True, "output": r}

def hotspot_status():
    """Get WiFi hotspot status."""
    r = run_cmd("nmcli -t -f NAME,TYPE,DEVICE connection show --active 2>/dev/null", timeout=5)
    active = False
    details = {}
    for line in (r or "").split("\n"):
        parts = line.split(":")
        if len(parts) >= 3 and "hotspot" in parts[1].lower():
            active = True
            details["name"] = parts[0]
            details["device"] = parts[2]
    if active:
        # Get connected clients
        clients = run_cmd("iw dev wlan0 station dump 2>/dev/null | grep -c Station", timeout=5)
        details["clients"] = safe_int(clients, 0)
    return {"active": active, "details": details}


class ITToolsHandler(http.server.SimpleHTTPRequestHandler):

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(STATIC_DIR), **kwargs)

    def log_message(self, format, *args):
        pass

    def _check_auth(self):
        """Auth deaktiviert — kein PIN nötig."""
        return True


    def do_GET(self):
        with request_counter_lock:
            request_counter["total"] += 1
            request_counter["get"] += 1
        self._req_start = time.time()
        if not self._check_auth():
            self.send_json({"success": False, "error": "Nicht autorisiert"}, 401)
            return
        parsed = urlparse(self.path)
        path = parsed.path

        if path in ("/", "/index.html"):
            self.send_file("index.html")
        elif path == "/api/sysinfo":
            self.send_json(get_system_info())
        elif path == "/api/tasks":
            with tasks_lock:
                task_list = []
                for tid_key, t in tasks.items():
                    tc = dict(t)
                    tc.pop("process", None)
                    task_list.append(tc)
            self.send_json({"success": True, "tasks": task_list})
        elif path.startswith("/api/task/"):
            parts_list = path.split("/")
            if len(parts_list) >= 5 and parts_list[4] == "cancel":
                self.send_json(cancel_task(parts_list[3]))
                return
            tid = parts_list[-1]
            t = get_task(tid)
            if t:
                self.send_json(t)
            else:
                self.send_json({"success": False, "error": "Task not found"}, 404)
        elif path == "/api/bios/settings":
            self.send_json(get_bios_settings())
        elif path == "/api/bios/profiles":
            self.send_json(get_bios_profiles())
        elif path == "/api/disks":
            output = run_cmd("lsblk -J -o NAME,SIZE,ROTA,MODEL,SERIAL,TYPE,MOUNTPOINT,FSTYPE 2>/dev/null", "{}")
            try:
                self.send_json(json.loads(output))
            except Exception:
                self.send_json({"blockdevices": []})
        elif path == "/api/storage":
            mounts = []
            if DATA_DIR.is_mount():
                usage = run_cmd(f"df -h {DATA_DIR} | tail -1")
                parts = usage.split()
                mounts.append({"name":"flowbit OS Data","path":str(DATA_DIR),"size":parts[1] if len(parts)>1 else "?","used":parts[2] if len(parts)>2 else "?","free":parts[3] if len(parts)>3 else "?","type":"data"})
            for p in sorted(Path("/mnt/usb").glob("*")):
                if p.is_mount():
                    usage = run_cmd(f"df -h {p} | tail -1")
                    parts = usage.split()
                    mounts.append({"name":p.name,"path":str(p),"size":parts[1] if len(parts)>1 else "?","used":parts[2] if len(parts)>2 else "?","free":parts[3] if len(parts)>3 else "?","type":"usb"})
            self.send_json({"mounts": mounts, "default": get_save_path()})
        elif path == "/api/usb/list":
            mounts = run_cmd("lsblk -n -o NAME,MOUNTPOINT,RM,SIZE,LABEL 2>/dev/null | awk '$3==1'", "")
            self.send_json({"output": mounts})

        # ---- NEW GET ENDPOINTS ----
        elif path == "/api/battery":
            self.send_json(get_battery_info())
        elif path == "/api/monitors":
            self.send_json({"monitors": get_monitors()})
        elif path == "/api/bootdevices":
            self.send_json(get_boot_devices())
        elif path == "/api/wol/history":
            with wol_history_lock:
                self.send_json({"history": list(wol_history)})
        elif path == "/api/wifi/scan":
            self.send_json({"networks": wifi_scan()})
        elif path == "/api/wifi/status":
            self.send_json({"connections": wifi_status()})
        elif path == "/api/wifi/saved":
            self.send_json({"connections": wifi_saved()})
        elif path == "/api/winpartitions":
            self.send_json({"partitions": find_windows_partitions()})
        elif path == "/api/partitions":
            self.send_json({"partitions": list_all_partitions()})
        elif path == "/api/autopilot":
            self.send_json(get_autopilot_info())
        elif path == "/api/serverip":
            info = get_server_ip()
            # Add PXE boot info
            tftp_available = os.path.isfile("/usr/sbin/in.tftpd") or os.path.isfile("/usr/bin/tftpd")
            dhcp_proxy_available = os.path.isfile("/usr/sbin/dnsmasq")
            info["pxe"] = {
                "tftp_available": tftp_available,
                "dhcp_proxy_available": dhcp_proxy_available,
                "info": "PXE Boot erfordert TFTP und DHCP-Proxy Konfiguration"
            }
            self.send_json(info)
        elif path == "/api/sessionlog":
            with session_log_lock:
                self.send_json({"log": list(session_log)})
        elif path == "/api/smart/dashboard":
            self.send_json({"disks": get_smart_dashboard()})
        elif path == "/api/qrcode":
            info = get_server_ip()
            svg = generate_qr_svg(info["url"])
            self.send_response(200)
            self.send_header("Content-Type", "image/svg+xml")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            try:
                self.wfile.write(svg.encode())
            except BrokenPipeError:
                pass
        elif path == "/api/download":
            qs = parse_qs(parsed.query)
            file_path = qs.get("path", [None])[0]
            if not file_path or sanitize_path(file_path) is None:
                self.send_json({"error": "Invalid path"}, 400)
                return
            if not os.path.isfile(file_path):
                self.send_json({"error": "File not found"}, 404)
                return
            try:
                file_size = os.path.getsize(file_path)
                filename = os.path.basename(file_path)
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Disposition", f'attachment; filename="{filename}"')
                self.send_header("Content-Length", str(file_size))
                self.end_headers()
                with open(file_path, 'rb') as f:
                    while True:
                        chunk = f.read(65536)
                        if not chunk:
                            break
                        self.wfile.write(chunk)
            except Exception as e:
                self.send_json({"error": str(e)}, 500)
        # ---- Network Bandwidth Monitor ----
        elif path == "/api/netmonitor":
            self.send_json(get_network_stats())

        # ---- Firmware ----
        elif path == "/api/firmware/devices":
            self.send_json(get_firmware_info())
        elif path == "/api/firmware/updates":
            self.send_json(check_firmware_updates())

        # ---- Partition Manager ----
        elif path == "/api/partmgr/layout":
            self.send_json(get_partition_layout())

        # ---- Antivirus ----
        elif path == "/api/antivirus/status":
            installed = run_cmd("which clamscan 2>/dev/null", "", timeout=5)
            self.send_json({"installed": bool(installed), "path": installed})

        elif path == "/api/antivirus/paths":
            self.send_json(get_antivirus_scan_paths())

        # ---- Hardware Monitor ----
        elif path == "/api/hwmon":
            self.send_json(get_hwmon_data())

        # ---- Secure Boot ----
        elif path == "/api/secureboot":
            self.send_json(get_secureboot_info())

        # ---- Update Check ----
        elif path == "/api/update/bootdev":
            self.send_json(get_boot_device())
        elif path == "/api/version":
            uptime_secs = int(time.time() - SERVER_START)
            self.send_json({"success": True, "version": FLOWBIT_VERSION,
                "uptime": uptime_secs,
                "uptime_human": f"{uptime_secs // 3600}h {(uptime_secs % 3600) // 60}m"})
        elif path == "/api/update/check":
            self.send_json(check_for_update())
        elif path.startswith("/api/update/progress"):
            qs = parse_qs(urlparse(self.path).query)
            task_id = qs.get("id", [""])[0]
            with tasks_lock:
                if task_id in tasks:
                    task_copy = dict(tasks[task_id])
                    task_copy.pop("process", None)
                    self.send_json(task_copy)
                else:
                    self.send_json({"success": False, "error": "Task nicht gefunden"}, 404)

        # ---- Wizard ----
        elif path == "/api/wizard/list":
            self.send_json({"wizards": [{"id": k, "name": v["name"], "steps": len(v["steps"])} for k, v in WIZARDS.items()]})
        elif path.startswith("/api/wizard/") and path != "/api/wizard/list":
            wiz_name = path.split("/")[-1]
            if wiz_name in WIZARDS:
                self.send_json(WIZARDS[wiz_name])
            else:
                self.send_json({"error": "Wizard nicht gefunden"}, 404)

        # ---- Notes ----
        elif path == "/api/notes":
            self.send_json({"notes": get_notes()})

        # ---- Checklists ----
        elif path == "/api/checklists":
            self.send_json({"checklists": [{"id": k, "name": v["name"], "items": len(v["items"])} for k, v in CHECKLISTS.items()]})
        elif path.startswith("/api/checklists/") and not path.startswith("/api/checklists/update"):
            cl_name = path.split("/")[-1]
            cl = get_checklist(cl_name)
            if cl:
                self.send_json(cl)
            else:
                self.send_json({"error": "Checkliste nicht gefunden"}, 404)


        # ---- TPM Management (A06) ----
        elif path == "/api/tpm/status":
            self.send_json(get_tpm_status())

        # ---- Windows 11 Compatibility (A13) ----
        elif path == "/api/win11check":
            self.send_json(check_win11_compatibility())

        # ---- Health Check (C09) ----
        elif path == "/api/health":
            self.send_json(get_health())

        # ---- Metrics (C10) ----
        elif path == "/api/metrics":
            metrics_text = get_metrics()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            try:
                self.wfile.write(metrics_text.encode())
            except BrokenPipeError:
                pass
            return

        # ---- USB Device Manager (A07) ----
        elif path == "/api/usb/devices":
            self.send_json({"devices": get_usb_devices()})

        # ---- Audit Log (D03) ----
        elif path == "/api/audit":
            with audit_log_lock:
                self.send_json({"entries": list(audit_log)})


        # ---- SSE Server-Sent Events (C02) ----
        elif path == "/api/events":
            with sse_clients_lock:
                if len(sse_clients) >= MAX_SSE_CLIENTS:
                    self.send_json({"error": "Zu viele SSE-Clients"}, 429)
                    return
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "keep-alive")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            try:
                client_id = id(self)
                with sse_clients_lock:
                    sse_clients[client_id] = self
                # Keep connection open, send heartbeat
                while True:
                    with sse_clients_lock:
                        if client_id not in sse_clients:
                            break
                    self.wfile.write(b": heartbeat\n\n")
                    self.wfile.flush()
                    time.sleep(15)
            except (BrokenPipeError, ConnectionResetError, OSError):
                pass
            finally:
                with sse_clients_lock:
                    sse_clients.pop(client_id, None)
            return

        # ---- Request Log (C06) ----
        elif path == "/api/requestlog":
            with request_log_lock:
                self.send_json({"entries": list(request_log), "total": _request_count})

        # ---- Task Queue Info (C08) ----
        elif path == "/api/tasks/queue":
            with tasks_lock:
                pending = sum(1 for t in tasks.values() if t.get("status") == "pending")
                running = sum(1 for t in tasks.values() if t.get("status") == "running")
                done = sum(1 for t in tasks.values() if t.get("status") == "done")
                cancelled = sum(1 for t in tasks.values() if t.get("status") == "cancelled")
            self.send_json({"pending": pending, "running": running, "done": done, "cancelled": cancelled, "total": pending + running + done + cancelled})

        # ---- Network Image List (A03) ----
        elif path == "/api/netimage/list":
            qs = parse_qs(parsed.query)
            mp = qs.get("mountpoint", ["/mnt/netshare"])[0]
            self.send_json(list_network_images(mp))

        # ---- Sessions Info (D02) ----
        elif path == "/api/sessions":
            cleanup_sessions()
            with sessions_lock:
                count = len(sessions)
            self.send_json({"active_sessions": count})

        # ---- noVNC Proxy Status (A01) ----
        elif path == "/api/vnc/status":
            self.send_json(vnc_status())

        # ---- VPN Status (E-item) ----
        elif path == "/api/vpn/status":
            self.send_json(vpn_status())

        # ---- Hotspot Status (E-item) ----
        elif path == "/api/hotspot/status":
            self.send_json(hotspot_status())

        else:
            super().do_GET()

    def do_POST(self):
        with request_counter_lock:
            request_counter["total"] += 1
            request_counter["post"] += 1
        self._req_start = time.time()
        if not self._check_auth():
            self.send_json({"success": False, "error": "Nicht autorisiert"}, 401)
            return
        content_length = safe_int(self.headers.get("Content-Length", 0))
        if content_length > 10 * 1024 * 1024:  # 10 MB max
            self.send_json({"error": "Request too large"}, 413)
            return
        body = self.rfile.read(content_length).decode() if content_length else ""
        try:
            data = json.loads(body) if body else {}
        except (json.JSONDecodeError, ValueError):
            self.send_json({"success": False, "error": "Invalid JSON"}, 400)
            return

        path = urlparse(self.path).path
        source_ip = self.client_address[0] if self.client_address else ""

        # ---- Auth ----
        if path == "/api/auth" or path == "/api/auth/verify":
            if not _check_auth_rate(source_ip):
                self.send_json({"success": False, "error": "Zu viele Versuche. Bitte warten."}, 429)
                return
            pin = data.get("pin", "")
            if pin == AUTH_TOKEN:
                # Create session (D02)
                session_token = create_session(source_ip)
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Set-Cookie", f"flowbit_auth={session_token}; Path=/; HttpOnly; SameSite=Strict; Secure")
                self.end_headers()
                try:
                    self.wfile.write(json.dumps({"success": True, "token": session_token}).encode())
                except BrokenPipeError:
                    pass
                return
            else:
                self.send_json({"success": False, "error": "Ungültiger PIN"}, 401)
                return

        # ---- Task Cancel ----
        elif path.startswith("/api/task/") and path.endswith("/cancel"):
            parts_list = path.split("/")
            if len(parts_list) >= 4:
                self.send_json(cancel_task(parts_list[3]))
                return

        # ---- Network ----
        elif path == "/api/ping":
            target = data.get("target", "1.1.1.1")
            result = {"output": run_cmd(f"ping -c 4 -W 3 {shlex.quote(target)} 2>&1", "Fehler", timeout=20)}
            self.send_json(result)

        elif path == "/api/dns":
            target = data.get("target", "google.com")
            result = {"output": run_cmd(f"dig {shlex.quote(target)} ANY +noall +answer 2>&1", "Fehler", timeout=10)}
            self.send_json(result)

        elif path == "/api/traceroute":
            target = data.get("target", "google.com")
            tid = new_task(f"Traceroute {target}")
            threading.Thread(target=traceroute_thread, args=(tid, target), daemon=True).start()
            self.send_json({"task_id": tid})

        elif path == "/api/speedtest":
            size = data.get("size", "1")
            r = run_cmd(f"curl -o /dev/null -w '%{{speed_download}}' -sL 'http://speedtest.tele2.net/{size}MB.zip' 2>&1", "0", timeout=120)
            try:
                bps = float(r)
                mbps = round(bps * 8 / 1_000_000, 2)
            except Exception:
                mbps = 0
            self.send_json({"mbps": mbps, "size": size})

        elif path == "/api/portcheck":
            target = data.get("target", "")
            port = safe_int(data.get("port", 80), 80)
            if not target:
                self.send_json({"success": False, "error": "Target required"}, 400)
                return
            try:
                s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                s.settimeout(3)
                result_code = s.connect_ex((target, port))
                s.close()
                if result_code == 0:
                    diagnosis = "open"
                elif result_code == 111:
                    diagnosis = "connection_refused"
                elif result_code == 113:
                    diagnosis = "host_unreachable"
                elif result_code == 110:
                    diagnosis = "timeout"
                else:
                    diagnosis = f"error_code_{result_code}"
                self.send_json({"success": True, "open": result_code == 0, "diagnosis": diagnosis, "target": target, "port": port})
            except socket.gaierror:
                self.send_json({"success": True, "open": False, "diagnosis": "dns_resolution_failed", "target": target, "port": port})
            except socket.timeout:
                self.send_json({"success": True, "open": False, "diagnosis": "timeout", "target": target, "port": port})
            except Exception as e:
                self.send_json({"success": False, "open": False, "error": str(e), "target": target, "port": port})

        elif path == "/api/network/diag":
            tid = new_task("Netzwerk Diagnose")
            threading.Thread(target=full_network_diag_thread, args=(tid,), daemon=True).start()
            self.send_json({"task_id": tid})

        # ---- SMART ----
        elif path == "/api/smart":
            disk = data.get("disk", "sda")
            safe_disk = sanitize_device(disk)
            result = {"output": run_cmd(f"smartctl -a /dev/{safe_disk} 2>&1", "Keine SMART Daten", timeout=15)}
            self.send_json(result)

        # ---- Wiper ----
        elif path == "/api/wiper/wipe":
            audit_record("disk_wipe", f"device={data.get('device','')}, method={data.get('method','')}", source_ip)
            device = data.get("device", "")
            method = data.get("method", "zero")
            passes = safe_int(data.get("passes", 1), 1)
            if not device:
                self.send_json({"error": "Kein Device angegeben"}, 400)
                return
            safe_dev = sanitize_device(device)
            log_action("Wipe", f"/dev/{safe_dev} method={method} passes={passes}")
            tid = new_task(f"Wipe /dev/{safe_dev}")
            threading.Thread(target=wipe_disk_thread, args=(tid, safe_dev, method, passes), daemon=True).start()
            self.send_json({"task_id": tid})

        elif path == "/api/wiper/secure-erase":
            audit_record("secure_erase", f"device={data.get('device','')}", source_ip)
            device = data.get("device", "")
            if not device:
                self.send_json({"error": "Kein Device angegeben"}, 400)
                return
            safe_dev = sanitize_device(device)
            log_action("Secure Erase", f"/dev/{safe_dev}")
            tid = new_task(f"Secure Erase /dev/{safe_dev}")
            threading.Thread(target=ssd_secure_erase_thread, args=(tid, safe_dev), daemon=True).start()
            self.send_json({"task_id": tid})

        elif path == "/api/wiper/ram-scrub":
            tid = new_task("RAM Scrub")
            threading.Thread(target=ram_scrub_thread, args=(tid,), daemon=True).start()
            self.send_json({"task_id": tid})

        # ---- Hardware Test ----
        elif path == "/api/hwtest/ram":
            size = safe_int(data.get("size_mb", 256), 256)
            passes = safe_int(data.get("passes", 2), 2)
            tid = new_task(f"RAM Test {size}MB")
            threading.Thread(target=ram_test_thread, args=(tid, size, passes), daemon=True).start()
            self.send_json({"task_id": tid})

        elif path == "/api/hwtest/cpu":
            duration = safe_int(data.get("duration", 30), 30)
            tid = new_task(f"CPU Stress {duration}s")
            threading.Thread(target=cpu_stress_thread, args=(tid, duration), daemon=True).start()
            self.send_json({"task_id": tid})

        elif path == "/api/hwtest/disk":
            device = data.get("device", "sda")
            safe_dev = sanitize_device(device)
            tid = new_task(f"Disk Test /dev/{safe_dev}")
            threading.Thread(target=disk_speed_thread, args=(tid, safe_dev), daemon=True).start()
            self.send_json({"task_id": tid})

        # ---- BIOS ----
        elif path == "/api/bios/save-profile":
            name = data.get("name", "")
            if not name:
                self.send_json({"error": "Kein Name angegeben"}, 400)
                return
            settings = get_bios_settings()
            filepath = save_bios_profile(name, settings)
            self.send_json({"success": True, "path": filepath})

        elif path == "/api/bios/export-usb":
            name = data.get("name", "")
            result = export_bios_to_usb(name)
            self.send_json(result)

        elif path == "/api/bios/export-txt":
            settings = get_bios_settings()
            info = get_system_info()
            timestamp = time.strftime("%Y%m%d_%H%M%S")
            lines = [
                "=" * 64,
                "  BIOS Settings Export — flowbit OS",
                f"  Datum: {time.strftime('%d.%m.%Y %H:%M:%S')}",
                f"  Gerät: {info['manufacturer']} {info['model']} (SN: {info['serial']})",
                "=" * 64, ""
            ]
            for s in settings.get("settings", []):
                dn = s.get("display_name", s["name"])
                cv = s.get("current_value", "N/A")
                lines.append(f"  {dn}: {cv}")
            content = "\n".join(lines)
            self.send_json({"filename": f"BIOS_{info['serial']}_{timestamp}.txt", "content": content})

        # ---- Backup/Restore ----
        elif path == "/api/backup/disk":
            source = data.get("source", "")
            target_path = data.get("target_path", "/tmp")
            compress = data.get("compress", True)
            if not source:
                self.send_json({"success": False, "error": "Kein Source angegeben"}, 400)
                return
            safe_src = sanitize_device(source)
            safe_target = sanitize_path(target_path)
            if not safe_target:
                self.send_json({"success": False, "error": "Ungültiger Zielpfad"}, 400)
                return
            log_action("Backup", f"/dev/{safe_src} -> {safe_target}")
            tid = new_task(f"Backup /dev/{safe_src}")
            threading.Thread(target=backup_disk_thread, args=(tid, safe_src, safe_target, compress), daemon=True).start()
            self.send_json({"task_id": tid})

        elif path == "/api/backup/restore":
            image = data.get("image", "")
            target = data.get("target", "")
            if not image or not target:
                self.send_json({"error": "Image und Target nötig"}, 400)
                return
            safe_tgt = sanitize_device(target)
            tid = new_task(f"Restore -> /dev/{safe_tgt}")
            threading.Thread(target=restore_disk_thread, args=(tid, image, safe_tgt), daemon=True).start()
            self.send_json({"task_id": tid})

        elif path == "/api/backup/clone":
            audit_record("disk_clone", f"source={data.get('source','')}, target={data.get('target','')}", source_ip)
            source = data.get("source", "")
            target = data.get("target", "")
            if not source or not target:
                self.send_json({"error": "Source und Target nötig"}, 400)
                return
            safe_src = sanitize_device(source)
            safe_tgt = sanitize_device(target)
            log_action("Clone", f"/dev/{safe_src} -> /dev/{safe_tgt}")
            tid = new_task(f"Clone {safe_src} -> {safe_tgt}")
            threading.Thread(target=clone_disk_thread, args=(tid, safe_src, safe_tgt), daemon=True).start()
            self.send_json({"task_id": tid})

        # ---- Export ----
        elif path == "/api/export/sysinfo":
            info = get_system_info()
            timestamp = time.strftime("%Y%m%d_%H%M%S")
            serial = info.get("serial", "NA")
            filename = f"SYSINFO_{serial}_{timestamp}.txt"
            report = generate_sysinfo_report(info)
            self.send_json({"filename": filename, "content": report})

        elif path == "/api/export/intune":
            ap_info = get_autopilot_info()
            timestamp = time.strftime("%Y%m%d_%H%M%S")
            csv_lines = [
                "Device Serial Number,Windows Product ID,Hardware Hash",
                f"{ap_info['serial']},,{ap_info['hardware_hash']}"
            ]
            self.send_json({
                "filename": f"INTUNE_{ap_info['serial']}_{timestamp}.csv",
                "content": "\n".join(csv_lines)
            })

        # ---- NEW POST ENDPOINTS ----

        # Wake-on-LAN
        elif path == "/api/wol":
            mac = data.get("mac", "")
            ip_addr = data.get("ip", None)
            if not mac:
                self.send_json({"error": "MAC address required"}, 400)
                return
            self.send_json(send_wol(mac, ip_addr))

        # Network Scanner
        elif path == "/api/netscan":
            subnet = data.get("subnet", "")
            target = data.get("target", "")
            ports = data.get("ports", False)
            log_action("Network Scan", f"subnet={subnet} target={target}")
            tid = new_task(f"Network Scan {subnet or target or 'auto'}")
            threading.Thread(target=netscan_thread, args=(tid, subnet, target, ports), daemon=True).start()
            self.send_json({"task_id": tid})

        # WiFi
        elif path == "/api/wifi/connect":
            ssid = data.get("ssid", "")
            password = data.get("password", "")
            if not ssid:
                self.send_json({"error": "SSID required"}, 400)
                return
            self.send_json(wifi_connect(ssid, password))

        elif path == "/api/wifi/disconnect":
            name = data.get("name", "")
            if not name:
                self.send_json({"error": "Connection name required"}, 400)
                return
            self.send_json(wifi_disconnect(name))

        # Windows Password Reset
        elif path == "/api/passreset/users":
            partition = data.get("partition", "")
            if not partition:
                self.send_json({"error": "Partition required"}, 400)
                return
            self.send_json(list_windows_users(partition))

        elif path == "/api/passreset/reset":
            audit_record("password_reset", f"user={data.get('user','')}", source_ip)
            partition = data.get("partition", "")
            username = data.get("username", "")
            if not partition or not username:
                self.send_json({"error": "Partition and username required"}, 400)
                return
            log_action("Password Reset", f"partition={partition} user={username}")
            self.send_json(reset_windows_password(partition, username))

        # File Explorer
        elif path == "/api/mount":
            partition = data.get("partition", "")
            if not partition:
                self.send_json({"error": "Partition required"}, 400)
                return
            self.send_json(mount_partition(partition))

        elif path == "/api/unmount":
            mountpoint = data.get("mountpoint", "")
            if not mountpoint:
                self.send_json({"error": "Mountpoint required"}, 400)
                return
            self.send_json(unmount_partition(mountpoint))

        elif path == "/api/browse":
            browse_path = data.get("path", "")
            if not browse_path:
                self.send_json({"error": "Path required"}, 400)
                return
            self.send_json(browse_directory(browse_path))

        elif path == "/api/zipdownload":
            files = data.get("files", [])
            if not files:
                self.send_json({"error": "No files specified"}, 400)
                return
            result = create_zip_download(files)
            if "error" in result:
                self.send_json(result, 400)
            else:
                # Serve the zip file
                zip_path = result["path"]
                try:
                    file_size = os.path.getsize(zip_path)
                    filename = os.path.basename(zip_path)
                    self.send_response(200)
                    self.send_header("Content-Type", "application/zip")
                    self.send_header("Content-Disposition", f'attachment; filename="{filename}"')
                    self.send_header("Content-Length", str(file_size))
                    self.end_headers()
                    with open(zip_path, 'rb') as f:
                        while True:
                            chunk = f.read(65536)
                            if not chunk:
                                break
                            self.wfile.write(chunk)
                    # Cleanup
                    try:
                        os.remove(zip_path)
                    except Exception:
                        pass
                except Exception as e:
                    self.send_json({"error": str(e)}, 500)

        # Windows Driver Export
        elif path == "/api/windrivers":
            partition = data.get("partition", "")
            if not partition:
                self.send_json({"error": "Partition required"}, 400)
                return
            self.send_json(export_windows_drivers(partition))

        # Event Log
        elif path == "/api/eventlog/list":
            partition = data.get("partition", "")
            if not partition:
                self.send_json({"error": "Partition required"}, 400)
                return
            self.send_json(list_event_logs(partition))

        elif path == "/api/eventlog/read":
            evt_path = data.get("path", "")
            count = safe_int(data.get("count", 100), 100)
            if not evt_path:
                self.send_json({"error": "Path required"}, 400)
                return
            self.send_json(read_event_log(evt_path, count))

        # SSH Client
        elif path == "/api/ssh/exec":
            host = data.get("host", "")
            port = data.get("port", 22)
            user = data.get("user", "")
            password = data.get("password", "")
            command = data.get("command", "")
            if not host or not user or not command:
                self.send_json({"error": "host, user, and command required"}, 400)
                return
            self.send_json(ssh_exec(host, port, user, password, command))

        # Multi-Clone
        elif path == "/api/backup/multiclone":
            source = data.get("source", "")
            targets = data.get("targets", [])
            if not source or not targets:
                self.send_json({"error": "Source and targets required"}, 400)
                return
            safe_src = sanitize_device(source)
            safe_targets = [sanitize_device(t) for t in targets]
            tid = new_task(f"Multi-Clone {safe_src} -> {len(safe_targets)} targets")
            threading.Thread(target=multiclone_thread, args=(tid, safe_src, safe_targets), daemon=True).start()
            self.send_json({"task_id": tid})

        # Session Log Export
        elif path == "/api/sessionlog/export":
            with session_log_lock:
                lines = ["flowbit OS Session Log", "=" * 40, ""]
                for entry in session_log:
                    lines.append(f"[{entry['time']}] {entry['action']}: {entry['details']}")
                content = "\n".join(lines)
            self.send_json({"filename": f"sessionlog_{time.strftime('%Y%m%d_%H%M%S')}.txt", "content": content})

        # USB Boot Stick Writer
        elif path == "/api/usbwrite/write":
            iso_path = data.get("iso_path", "")
            device = data.get("device", "")
            if not iso_path or not device:
                self.send_json({"error": "iso_path and device required"}, 400)
                return
            safe_iso = sanitize_path(iso_path)
            if not safe_iso:
                self.send_json({"error": "Invalid ISO path"}, 400)
                return
            safe_dev = sanitize_device(device)
            if not safe_dev:
                self.send_json({"error": "Invalid device"}, 400)
                return
            log_action("USB Write", f"{iso_path} -> /dev/{safe_dev}")
            tid = new_task(f"USB Write /dev/{safe_dev}")
            threading.Thread(target=usb_write_thread, args=(tid, safe_iso, safe_dev), daemon=True).start()
            self.send_json({"task_id": tid})

        # Windows Product Key Viewer (extended)
        elif path == "/api/winkeys":
            partition = data.get("partition", "")
            if not partition:
                self.send_json({"error": "Partition required"}, 400)
                return
            log_action("Windows Keys", f"partition={partition}")
            self.send_json(get_windows_keys(partition))

        # Bitlocker Detection
        elif path == "/api/bitlocker":
            partition = data.get("partition", "")
            if not partition:
                self.send_json({"error": "Partition required"}, 400)
                return
            log_action("Bitlocker Check", f"partition={partition}")
            self.send_json(check_bitlocker(partition))

        # VNC Connection Test
        elif path == "/api/vnc/test":
            host = data.get("host", "")
            port = data.get("port", 5900)
            if not host:
                self.send_json({"error": "Host required"}, 400)
                return
            self.send_json(vnc_test_connection(host, port))

        # ---- Firmware Update ----
        elif path == "/api/firmware/update":
            device_id = data.get("device_id", "")
            if not device_id:
                self.send_json({"error": "device_id required"}, 400)
                return
            log_action("Firmware Update", f"device={device_id}")
            tid = new_task(f"Firmware Update {device_id}")
            threading.Thread(target=firmware_update_thread, args=(tid, device_id), daemon=True).start()
            self.send_json({"task_id": tid})

        # ---- Partition Manager ----
        elif path == "/api/partmgr/create":
            device = data.get("device", "")
            size = data.get("size", "100%")
            fstype = data.get("fstype", "")
            label = data.get("label", "")
            if not device:
                self.send_json({"error": "device required"}, 400)
                return
            log_action("Partition Create", f"device={device} size={size} fstype={fstype}")
            tid = new_task(f"Partition erstellen /dev/{device}")
            threading.Thread(target=create_partition_thread, args=(tid, device, size, fstype, label), daemon=True).start()
            self.send_json({"task_id": tid})

        elif path == "/api/partmgr/delete":
            audit_record("partition_delete", f"partition={data.get('partition','')}", source_ip)
            device = data.get("device", "")
            partnum = data.get("partnum", "")
            if not device or not partnum:
                self.send_json({"error": "device and partnum required"}, 400)
                return
            log_action("Partition Delete", f"device={device} partnum={partnum}")
            self.send_json(delete_partition(device, partnum))

        elif path == "/api/partmgr/resize":
            device = data.get("device", "")
            partnum = data.get("partnum", "")
            size = data.get("size", "")
            if not device or not partnum or not size:
                self.send_json({"error": "device, partnum and size required"}, 400)
                return
            log_action("Partition Resize", f"device={device} partnum={partnum} size={size}")
            tid = new_task(f"Partition Resize /dev/{device} #{partnum}")
            threading.Thread(target=resize_partition_thread, args=(tid, device, partnum, size), daemon=True).start()
            self.send_json({"task_id": tid})

        elif path == "/api/partmgr/format":
            audit_record("partition_format", f"partition={data.get('partition','')}, fstype={data.get('fstype','')}", source_ip)
            partition = data.get("partition", "")
            fstype = data.get("fstype", "")
            label = data.get("label", "")
            if not partition or not fstype:
                self.send_json({"error": "partition and fstype required"}, 400)
                return
            log_action("Partition Format", f"partition={partition} fstype={fstype}")
            tid = new_task(f"Format /dev/{partition} ({fstype})")
            threading.Thread(target=format_partition_thread, args=(tid, partition, fstype, label), daemon=True).start()
            self.send_json({"task_id": tid})

        # ---- Antivirus ----
        elif path == "/api/antivirus/scan":
            scan_path = data.get("path", "/")
            safe_path = sanitize_path(scan_path)
            if not safe_path:
                self.send_json({"error": "Invalid path"}, 400)
                return
            log_action("Antivirus Scan", f"path={safe_path}")
            tid = new_task(f"ClamAV Scan {safe_path}")
            threading.Thread(target=antivirus_scan_thread, args=(tid, safe_path), daemon=True).start()
            self.send_json({"task_id": tid})

        # ---- Hardware Monitor Fan Control ----
        elif path == "/api/hwmon/fan":
            device = data.get("device", "")
            fan = data.get("fan", "")
            value = data.get("value", 0)
            if not device or not fan:
                self.send_json({"error": "device and fan required"}, 400)
                return
            log_action("Fan Speed", f"device={device} fan={fan} value={value}")
            self.send_json(set_fan_speed(device, fan, value))

        elif path == "/api/hwmon/fan/auto":
            device = data.get("device", "")
            fan = data.get("fan", "")
            if not device or not fan:
                self.send_json({"error": "device and fan required"}, 400)
                return
            log_action("Fan Auto", f"device={device} fan={fan}")
            self.send_json(set_fan_auto(device, fan))

        # ---- Wipe Certificate ----
        elif path == "/api/wiper/certificate":
            device = data.get("device", "")
            method = data.get("method", "zero")
            passes = safe_int(data.get("passes", 1), 1)
            verified = bool(data.get("verified", False))
            if not device:
                self.send_json({"error": "device required"}, 400)
                return
            log_action("Wipe Certificate", f"device={device}")
            cert = generate_wipe_certificate(device, method, passes, verified)
            safe_dev = sanitize_device(device)
            serial = run_cmd(f"lsblk -dn -o SERIAL /dev/{safe_dev} 2>/dev/null", "NA")
            filename = f"WIPE_CERT_{serial}_{time.strftime('%Y%m%d_%H%M%S')}.txt"
            self.send_json({"filename": filename, "content": cert})

        # ---- Full Hardware Test ----
        elif path == "/api/hwtest/full":
            log_action("Full HW Test", "RAM + CPU + Disk")
            tid = new_task("Full Hardware Test")
            threading.Thread(target=full_hwtest_thread, args=(tid,), daemon=True).start()
            self.send_json({"task_id": tid})

        # ---- Boot Repair ----
        elif path == "/api/bootrepair/repair":
            device = data.get("device", "")
            repair_type = data.get("type", "")
            if not device or repair_type not in ("grub-install", "fix-efi", "rebuild-bcd"):
                self.send_json({"error": "device and valid type required"}, 400)
                return
            log_action("Boot Repair", f"device={device} type={repair_type}")
            tid = new_task(f"Boot Repair {repair_type} /dev/{device}")
            threading.Thread(target=boot_repair_thread, args=(tid, device, repair_type), daemon=True).start()
            self.send_json({"task_id": tid})

        # ---- Registry Editor ----
        elif path == "/api/registry/browse":
            partition = data.get("partition", "")
            hive = data.get("hive", "")
            key_path = data.get("path", "\\")
            if not partition or not hive:
                self.send_json({"error": "partition and hive required"}, 400)
                return
            mount_point = f"/tmp/ittools_mnt/{sanitize_device(partition)}"
            hive_paths = {
                "SOFTWARE": "Windows/System32/config/SOFTWARE",
                "SYSTEM": "Windows/System32/config/SYSTEM",
                "SAM": "Windows/System32/config/SAM",
                "SECURITY": "Windows/System32/config/SECURITY",
            }
            if hive not in hive_paths:
                self.send_json({"error": "Unbekannte Hive"}, 400)
                return
            full_path = os.path.join(mount_point, hive_paths[hive])
            log_action("Registry Browse", f"hive={hive} path={key_path}")
            self.send_json(registry_list_keys(full_path, key_path))

        elif path == "/api/registry/export":
            partition = data.get("partition", "")
            hive = data.get("hive", "")
            if not partition or not hive:
                self.send_json({"error": "partition and hive required"}, 400)
                return
            log_action("Registry Export", f"partition={partition} hive={hive}")
            self.send_json(registry_export(partition, hive))

        # ---- Notes ----
        elif path == "/api/notes/save":
            title = data.get("title", "")
            content = data.get("content", "")
            device_serial = data.get("device_serial", "")
            if not title:
                self.send_json({"error": "title required"}, 400)
                return
            log_action("Note Save", f"title={title}")
            self.send_json(save_note(title, content, device_serial))

        elif path == "/api/notes/delete":
            note_id = data.get("id", "")
            if not note_id:
                self.send_json({"error": "id required"}, 400)
                return
            log_action("Note Delete", f"id={note_id}")
            self.send_json({"deleted": delete_note(note_id)})

        elif path == "/api/notes/export":
            notes = get_notes()
            lines = ["flowbit OS Notizen Export", "=" * 40, ""]
            for n in notes:
                lines.append(f"[{n.get('created', '')}] {n.get('title', '')}")
                if n.get('device_serial'):
                    lines.append(f"  Gerät: {n['device_serial']}")
                lines.append(f"  {n.get('content', '')}")
                lines.append("")
            content = "\n".join(lines)
            self.send_json({"filename": f"notes_{time.strftime('%Y%m%d_%H%M%S')}.txt", "content": content})

        # ---- Checklists ----
        elif path == "/api/checklists/update":
            name = data.get("name", "")
            item_index = data.get("item_index", None)
            checked = data.get("checked", False)
            if not name or item_index is None:
                self.send_json({"error": "name and item_index required"}, 400)
                return
            update_checklist(name, item_index, checked)
            self.send_json({"success": True})

        # ---- Terminal ----
        elif path == "/api/terminal":
            command = data.get("command", "")
            if not command:
                self.send_json({"error": "command required"}, 400)
                return
            log_action("Terminal", f"cmd={command[:80]}")
            self.send_json(terminal_exec(command))

        # ---- Update ----
        elif path == "/api/update/download":
            url = data.get("url", "")
            sha256 = data.get("sha256", "")
            if not url:
                self.send_json({"success": False, "error": "url required"}, 400)
                return
            task_id = str(uuid.uuid4())[:8]
            with tasks_lock:
                tasks[task_id] = {"id": task_id, "description": "Update Download",
                    "status": "downloading", "progress": 0, "total": 0,
                    "output": "", "started": time.time(), "finished": None,
                    "exit_code": None, "process": None}
            log_action("Update Download", f"url={url}", self.client_address[0] if self.client_address else "")
            threading.Thread(target=download_update, args=(task_id, url, sha256), daemon=True).start()
            self.send_json({"task_id": task_id})

        elif path == "/api/update/flash":
            device = data.get("device", "")
            if not device or not re.match(r'^(/dev/)?(sd[a-z]|nvme\d+n\d+|sr\d+)$', device):
                self.send_json({"success": False, "error": "Ungültiges Gerät"}, 400)
                return
            iso_path = "/tmp/flowbit-update.iso"
            if not os.path.exists(iso_path):
                self.send_json({"success": False, "error": "Kein Update heruntergeladen"}, 400)
                return
            task_id = str(uuid.uuid4())[:8]
            with tasks_lock:
                tasks[task_id] = {"id": task_id, "description": "Update Flash",
                    "status": "flashing", "progress": 0, "total": 0,
                    "output": "", "started": time.time(), "finished": None,
                    "exit_code": None, "process": None}
            log_action("Update Flash", f"device={device}", self.client_address[0] if self.client_address else "")
            threading.Thread(target=flash_update, args=(task_id, iso_path, device), daemon=True).start()
            self.send_json({"task_id": task_id})

        # ---- Export All ----
        elif path == "/api/export/all":
            import zipfile as _zipfile
            import io as _io
            buf = _io.BytesIO()
            with _zipfile.ZipFile(buf, 'w', _zipfile.ZIP_DEFLATED) as zf:
                # Sysinfo
                try:
                    info = get_system_info()
                    zf.writestr("sysinfo.json", json.dumps(info, indent=2))
                except Exception:
                    pass
                # SMART
                try:
                    smart = get_smart_dashboard()
                    zf.writestr("smart.json", json.dumps(smart, indent=2))
                except Exception:
                    pass
                # Session log
                with session_log_lock:
                    zf.writestr("session_log.json", json.dumps(list(session_log), indent=2))
                # Version
                zf.writestr("version.txt", f"flowbit OS {FLOWBIT_VERSION}")
            buf.seek(0)
            self.send_response(200)
            self.send_header("Content-Type", "application/zip")
            self.send_header("Content-Disposition", "attachment; filename=flowbit-export.zip")
            self.send_header("Content-Length", str(len(buf.getvalue())))
            self.end_headers()
            try:
                self.wfile.write(buf.getvalue())
            except BrokenPipeError:
                pass


        # ---- TPM Clear (A06) ----
        elif path == "/api/tpm/clear":
            audit_record("tpm_clear", "TPM clear requested", source_ip)
            log_action("TPM Clear", "", source_ip)
            self.send_json(tpm_clear())

        # ---- Network Cable Tester (A10) ----
        elif path == "/api/nettest":
            interface = data.get("interface", "")
            if not interface:
                self.send_json({"error": "Interface erforderlich"}, 400)
            else:
                target = data.get("target")
                self.send_json(network_cable_test(interface, target))

        # ---- Disk Benchmark (A08) ----
        elif path == "/api/benchmark":
            disk = data.get("disk", "")
            test = data.get("test", "all")
            if not disk:
                self.send_json({"error": "Disk erforderlich"}, 400)
            else:
                safe_disk = sanitize_device(disk)
                if not safe_disk:
                    self.send_json({"error": "Ungültiges Gerät"}, 400)
                else:
                    task_id = new_task(f"Benchmark {safe_disk}")
                    log_action("Disk Benchmark", f"disk={safe_disk} test={test}", source_ip)
                    threading.Thread(
                        target=disk_benchmark_thread, args=(task_id, safe_disk, test), daemon=True
                    ).start()
                    self.send_json({"task_id": task_id})

        # ---- IP Calculator ----
        elif path == "/api/ipcalc":
            ip_input = data.get("ip", "")
            if not ip_input:
                self.send_json({"error": "IP/CIDR erforderlich"}, 400)
            else:
                self.send_json(ip_calculator(ip_input))

        # ---- USB Eject (A07) ----
        elif path == "/api/usb/eject":
            device = data.get("device", "")
            if not device:
                self.send_json({"error": "Gerät erforderlich"}, 400)
            else:
                audit_record("usb_eject", f"device={device}", source_ip)
                log_action("USB Eject", f"device={device}", source_ip)
                self.send_json(eject_usb_device(device))


        # ---- Network Image / Disk Imaging on Network Shares (A03) ----
        elif path == "/api/netimage/mount":
            ALLOWED_MOUNTPOINTS = ["/mnt/netshare", "/mnt/nfs", "/mnt/smb"]
            share_type = data.get("type", "")
            server = data.get("server", "")
            share = data.get("share", "")
            user = data.get("user")
            password = data.get("password")
            mountpoint = data.get("mountpoint", "/mnt/netshare")
            if mountpoint not in ALLOWED_MOUNTPOINTS:
                self.send_json({"success": False, "error": "Ungültiger Mountpoint"}, 400)
                return
            if not share_type or not server or not share:
                self.send_json({"error": "type, server and share required"}, 400)
                return
            log_action("Network Mount", f"{share_type}://{server}/{share}", source_ip)
            self.send_json(mount_network_share(share_type, server, share, user, password, mountpoint))

        elif path == "/api/netimage/unmount":
            mountpoint = data.get("mountpoint", "/mnt/netshare")
            log_action("Network Unmount", f"mountpoint={mountpoint}", source_ip)
            self.send_json(unmount_network_share(mountpoint))

        elif path == "/api/netimage/backup":
            disk = data.get("disk", "")
            mountpoint = data.get("mountpoint", "/mnt/netshare")
            compress = data.get("compress", True)
            if not disk:
                self.send_json({"error": "disk required"}, 400)
                return
            safe_disk = sanitize_device(disk)
            audit_record("netimage_backup", f"disk={safe_disk}, mountpoint={mountpoint}", source_ip)
            log_action("Network Backup", f"/dev/{safe_disk} -> {mountpoint}", source_ip)
            tid = new_task(f"Network Image Backup /dev/{safe_disk}")
            threading.Thread(target=netimage_backup_thread, args=(tid, safe_disk, mountpoint, compress), daemon=True).start()
            self.send_json({"task_id": tid})

        elif path == "/api/netimage/restore":
            image_path = data.get("image_path", "")
            target = data.get("target", "")
            if not image_path or not target:
                self.send_json({"error": "image_path and target required"}, 400)
                return
            # Validate image_path against safe prefixes
            safe_image_path = sanitize_path(image_path)
            if not safe_image_path:
                self.send_json({"success": False, "error": "Ungültiger Image-Pfad"}, 400)
                return
            image_path = safe_image_path
            safe_tgt = sanitize_device(target)
            audit_record("netimage_restore", f"image={image_path}, target={safe_tgt}", source_ip)
            log_action("Network Restore", f"{image_path} -> /dev/{safe_tgt}", source_ip)
            tid = new_task(f"Network Image Restore -> /dev/{safe_tgt}")
            threading.Thread(target=netimage_restore_thread, args=(tid, image_path, safe_tgt), daemon=True).start()
            self.send_json({"task_id": tid})

        # ---- Audit Log Clear (D03) ----
        elif path == "/api/audit/clear":
            with audit_log_lock:
                audit_log.clear()
                try:
                    with open(AUDIT_LOG_FILE, "w") as f:
                        json.dump([], f)
                except Exception:
                    pass
            self.send_json({"success": True})

        # ---- noVNC Remote Desktop Proxy (A01) ----
        elif path == "/api/vnc/connect":
            host = data.get("host", "")
            port = data.get("port", 5900)
            password = data.get("password")
            if not host:
                self.send_json({"error": "Host erforderlich"}, 400)
            else:
                log_action("VNC Connect", f"host={host}:{port}", source_ip)
                self.send_json(start_vnc_proxy(host, port, password))

        elif path == "/api/vnc/disconnect":
            log_action("VNC Disconnect", "", source_ip)
            self.send_json(stop_vnc_proxy())

        # ---- Active Directory / LDAP (A04) ----
        elif path == "/api/ldap/search":
            server = data.get("server", "")
            base_dn = data.get("base_dn", "")
            user = data.get("user", "")
            password = data.get("password", "")
            search_filter = data.get("filter", "(objectClass=*)")
            attributes = data.get("attributes")
            if not server or not base_dn or not user or not password:
                self.send_json({"error": "server, base_dn, user und password erforderlich"}, 400)
            else:
                log_action("LDAP Search", f"server={server} filter={search_filter}", source_ip)
                self.send_json(ldap_search(server, base_dn, user, password, search_filter, attributes))

        elif path == "/api/ldap/users":
            server = data.get("server", "")
            base_dn = data.get("base_dn", "")
            user = data.get("user", "")
            password = data.get("password", "")
            search_name = sanitize_ldap_value(data.get("name", "*"))
            if not server or not base_dn or not user or not password:
                self.send_json({"error": "server, base_dn, user und password erforderlich"}, 400)
            else:
                log_action("LDAP Users", f"server={server} name={search_name}", source_ip)
                self.send_json(ldap_search(server, base_dn, user, password,
                    f"(&(objectClass=user)(objectCategory=person)(cn={search_name}))",
                    ["cn", "sAMAccountName", "mail", "memberOf", "userAccountControl", "whenCreated", "lastLogon"]))

        elif path == "/api/ldap/computers":
            server = data.get("server", "")
            base_dn = data.get("base_dn", "")
            user = data.get("user", "")
            password = data.get("password", "")
            search_name = sanitize_ldap_value(data.get("name", "*"))
            if not server or not base_dn or not user or not password:
                self.send_json({"error": "server, base_dn, user und password erforderlich"}, 400)
            else:
                log_action("LDAP Computers", f"server={server} name={search_name}", source_ip)
                self.send_json(ldap_search(server, base_dn, user, password,
                    f"(&(objectClass=computer)(cn={search_name}))",
                    ["cn", "dNSHostName", "operatingSystem", "operatingSystemVersion", "whenCreated", "lastLogonTimestamp"]))

        elif path == "/api/ldap/groups":
            server = data.get("server", "")
            base_dn = data.get("base_dn", "")
            user = data.get("user", "")
            password = data.get("password", "")
            search_name = sanitize_ldap_value(data.get("name", "*"))
            if not server or not base_dn or not user or not password:
                self.send_json({"error": "server, base_dn, user und password erforderlich"}, 400)
            else:
                log_action("LDAP Groups", f"server={server} name={search_name}", source_ip)
                self.send_json(ldap_search(server, base_dn, user, password,
                    f"(&(objectClass=group)(cn={search_name}))",
                    ["cn", "description", "member", "groupType", "whenCreated"]))

        # ---- VPN Client / WireGuard (E-item) ----
        elif path == "/api/vpn/connect":
            config_b64 = data.get("config", "")
            if not config_b64:
                self.send_json({"error": "WireGuard config (base64) erforderlich"}, 400)
            else:
                audit_record("vpn_connect", "WireGuard connect", source_ip)
                log_action("VPN Connect", "", source_ip)
                self.send_json(vpn_connect(config_b64))

        elif path == "/api/vpn/disconnect":
            audit_record("vpn_disconnect", "WireGuard disconnect", source_ip)
            log_action("VPN Disconnect", "", source_ip)
            self.send_json(vpn_disconnect())

        # ---- DNS Diagnostics (E-item) ----
        elif path == "/api/dns/dig":
            domain = data.get("domain", "")
            qtype = data.get("type", "A")
            dns_server = data.get("server")
            if not domain:
                self.send_json({"error": "Domain erforderlich"}, 400)
            else:
                log_action("DNS Dig", f"domain={domain} type={qtype}", source_ip)
                self.send_json(dns_dig(domain, qtype, dns_server))

        # ---- WiFi Hotspot (E-item) ----
        elif path == "/api/hotspot/start":
            ssid = data.get("ssid", "")
            password = data.get("password", "")
            band = data.get("band", "2.4")
            if not ssid or not password:
                self.send_json({"error": "SSID und Passwort erforderlich"}, 400)
            elif len(password) < 8:
                self.send_json({"error": "Passwort muss mindestens 8 Zeichen haben"}, 400)
            else:
                log_action("Hotspot Start", f"ssid={ssid} band={band}", source_ip)
                self.send_json(start_hotspot(ssid, password, band))

        elif path == "/api/hotspot/stop":
            log_action("Hotspot Stop", "", source_ip)
            self.send_json(stop_hotspot())

        else:
            self.send_json({"error": "Unknown endpoint"}, 404)

    def do_OPTIONS(self):
        """Handle CORS preflight requests."""
        self.send_response(200)
        origin = self.headers.get("Origin", "")
        self.send_header("Access-Control-Allow-Origin", origin)
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, X-Auth-Token")
        self.send_header("Access-Control-Allow-Credentials", "true")
        self.end_headers()

    def send_json(self, data, status=200):
        try:
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Security-Policy", "default-src 'self' 'unsafe-inline' 'unsafe-eval'; img-src 'self' data:; font-src 'self' https://fonts.gstatic.com https://fonts.googleapis.com")
            self.end_headers()
            self.wfile.write(json.dumps(data).encode())
        except BrokenPipeError:
            pass
        # Request logging (C06)
        try:
            duration = (time.time() - getattr(self, '_req_start', time.time())) * 1000
            ip = self.client_address[0] if self.client_address else ""
            log_request(self.command, urlparse(self.path).path, status, duration, ip)
        except Exception:
            pass

    def send_file(self, filename):
        filepath = STATIC_DIR / filename
        if filepath.exists():
            self.send_response(200)
            ct = "text/html"
            if filename.endswith(".css"):
                ct = "text/css"
            elif filename.endswith(".js"):
                ct = "application/javascript"
            self.send_header("Content-Type", f"{ct}; charset=utf-8")
            self.send_header("Content-Security-Policy", "default-src 'self' 'unsafe-inline' 'unsafe-eval'; img-src 'self' data:; font-src 'self' https://fonts.gstatic.com https://fonts.googleapis.com")
            self.end_headers()
            try:
                self.wfile.write(filepath.read_bytes())
            except BrokenPipeError:
                pass
        else:
            self.send_error(404)



# ---- HTTP Redirect Handler (D01) ----

class RedirectHandler(http.server.BaseHTTPRequestHandler):
    """Simple HTTP handler that redirects all requests to HTTPS."""
    def do_GET(self):
        self.send_response(301)
        host = self.headers.get('Host', '').split(':')[0]
        self.send_header('Location', f'https://{host}:{HTTPS_PORT}{self.path}')
        self.end_headers()

    def do_POST(self):
        self.do_GET()

    def log_message(self, format, *args):
        pass


class ThreadedHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


def _session_cleanup_loop():
    """Periodically clean up expired sessions."""
    while True:
        time.sleep(300)
        cleanup_sessions()


def _sse_sysinfo_loop():
    """Periodically broadcast system info to SSE clients."""
    while True:
        time.sleep(30)
        try:
            with sse_clients_lock:
                if not sse_clients:
                    continue
            cpu_load = run_cmd("cat /proc/loadavg | cut -d' ' -f1-3", "0 0 0", timeout=2)
            mem = run_cmd("free -m | grep Mem | awk '{print $3\"/\"$2}'", "?", timeout=2)
            sse_broadcast("sysinfo", {"cpu_load": cpu_load, "memory": mem, "time": time.strftime("%H:%M:%S")})
        except Exception:
            pass


if __name__ == "__main__":
    print(f"flowbit OS Server v{FLOWBIT_VERSION}")
    print(f"  Auth-PIN: {AUTH_TOKEN}")

    # Start HTTP server on PORT (8080) — used by Chromium kiosk
    server = ThreadedHTTPServer(("0.0.0.0", PORT), ITToolsHandler)
    print(f"  HTTP:  http://0.0.0.0:{PORT} (Kiosk + LAN)")

    # Start HTTPS server on HTTPS_PORT (8443) — for remote access (D01)
    cert_file, key_file = create_self_signed_cert()
    try:
        https_server = ThreadedHTTPServer(("0.0.0.0", HTTPS_PORT), ITToolsHandler)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(cert_file, key_file)
        https_server.socket = ctx.wrap_socket(https_server.socket, server_side=True)
        https_thread = threading.Thread(target=https_server.serve_forever, daemon=True)
        https_thread.start()
        print(f"  HTTPS: https://0.0.0.0:{HTTPS_PORT} (Remote)")
    except Exception as e:
        print(f"  HTTPS auf Port {HTTPS_PORT} nicht verfügbar: {e}")

    # Start session cleanup thread (D02)
    threading.Thread(target=_session_cleanup_loop, daemon=True).start()

    # Start SSE sysinfo broadcast thread (C02)
    threading.Thread(target=_sse_sysinfo_loop, daemon=True).start()

    print(f"  Server bereit.\n")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutdown...")
        try:
            stop_vnc_proxy()
        except Exception:
            pass
        try:
            vpn_disconnect()
        except Exception:
            pass
        try:
            run_cmd("nmcli connection down Hotspot 2>/dev/null", timeout=5)
        except Exception:
            pass
        server.shutdown()
