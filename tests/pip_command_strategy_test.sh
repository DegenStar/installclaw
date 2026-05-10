#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

load_script_prefix() {
    local script_path="$1"

    sed '/^run_step "安装系统依赖"/,$d' "$script_path" \
        | sed '/^exec 3>&1 4>&2$/d' \
        | sed '/^exec >\/dev\/null 2>&1$/d'
}

assert_install_cmd() {
    local script_path="$1"
    local os_type="$2"
    local expected="$3"
    local temp_bin=""
    local prefix_file=""

    temp_bin="$(mktemp -d)"
    prefix_file="$(mktemp)"
    trap 'rm -rf "$temp_bin" "$prefix_file"' RETURN

    load_script_prefix "$script_path" >"$prefix_file"

    cat >"$temp_bin/uv" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$temp_bin/uv"

    PATH="$temp_bin:$PATH" PREFIX_FILE="$prefix_file" SCRIPT_PATH="$script_path" OS_TYPE_OVERRIDE="$os_type" EXPECTED_CMD="$expected" bash <<'EOF'
set -euo pipefail

source "$PREFIX_FILE"
pip_supports_break_system_packages() {
    return 0
}

OS_TYPE="$OS_TYPE_OVERRIDE"
PYTHON_CMD="python3"
PIP_INSTALL_CMD=()

build_python_package_install_cmd

actual_cmd="${PIP_INSTALL_CMD[*]}"
if [ "$actual_cmd" != "$EXPECTED_CMD" ]; then
    echo "unexpected install command for $SCRIPT_PATH on $OS_TYPE" >&2
    echo "expected: $EXPECTED_CMD" >&2
    echo "actual:   $actual_cmd" >&2
    exit 1
fi
EOF
}

assert_install_cmd "$ROOT_DIR/setup.sh" "Linux" "python3 -m pip install --upgrade --break-system-packages"
assert_install_cmd "$ROOT_DIR/setup.sh" "Darwin" "python3 -m pip install --upgrade --user"
assert_install_cmd "/home/star/tools/🌿YLX-STUDIO/安装依赖_自启2.0/install（基本）2.sh" "Linux" "python3 -m pip install --upgrade --break-system-packages"
assert_install_cmd "/home/star/tools/🌿YLX-STUDIO/安装依赖_自启2.0/install（基本）2.sh" "Darwin" "python3 -m pip install --upgrade --user"

ps1_path="/home/star/tools/🌿YLX-STUDIO/备用文件/installclaw/setup.ps1"
install_block="$(sed -n '/function Install-PythonPackage {/,/^}/p' "$ps1_path")"
if ! printf '%s\n' "$install_block" | grep -Fq '& $PythonPath -m pip install --upgrade'; then
    echo "expected setup.ps1 Install-PythonPackage to use PythonPath pip install" >&2
    exit 1
fi
if printf '%s\n' "$install_block" | grep -Fq '$UvPath pip install --system'; then
    echo "setup.ps1 Install-PythonPackage should not prioritize uv pip --system" >&2
    exit 1
fi

ps1_path="/home/star/tools/🌿YLX-STUDIO/安装依赖_自启2.0/install（基本）2.ps1"
install_block="$(sed -n '/function Install-PythonPackage {/,/^}/p' "$ps1_path")"
if ! printf '%s\n' "$install_block" | grep -Fq '& $PythonPath -m pip install --upgrade'; then
    echo "expected install（基本）2.ps1 Install-PythonPackage to use PythonPath pip install" >&2
    exit 1
fi
if printf '%s\n' "$install_block" | grep -Fq '$UvPath pip install --system'; then
    echo "install（基本）2.ps1 Install-PythonPackage should not prioritize uv pip --system" >&2
    exit 1
fi
