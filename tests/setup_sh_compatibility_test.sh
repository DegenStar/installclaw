#!/usr/bin/env bash
set -euo pipefail

setup_path="$(cd "$(dirname "$0")/.." && pwd)/setup.sh"
script=$(<"$setup_path")

extract_function() {
    sed -n "/^$1()/,/^}/p" "$setup_path"
}

# Source only the functions under test, never setup.sh's top-level installer.
source <(extract_function pkg_install)
source <(extract_function resolve_pkg_name)
source <(extract_function install_dependencies)

test "$(resolve_pkg_name python3-pip pacman)" = "python-pip"
test "$(resolve_pkg_name python3-pip apk)" = "py3-pip"
for pkg_manager in apt apt-get dnf yum zypper; do
    test "$(resolve_pkg_name python3-pip "$pkg_manager")" = "python3-pip"
done

pacman_invocation=""
_sudo() {
    "$@"
}
pacman() {
    pacman_invocation="$*"
}
pkg_install pacman python-pip xclip
test "$pacman_invocation" = "-S --needed --noconfirm python-pip xclip"
case "$pacman_invocation" in
    *-Sy*) exit 1 ;;
esac

run_step() {
    shift
    "$@"
}
find_python3() {
    printf '%s\n' python3
}

test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
BREW_LOG="$test_root/brew.log"
export BREW_LOG

test_homebrew_fallback() {
    local fallback_opt="$test_root/opt/homebrew/bin/brew"
    local fallback_usr="$test_root/usr/local/bin/brew"
    local candidate="$1"
    local install_dependencies_source=""
    local command_brew_checks=0

    rm -f "$fallback_opt" "$fallback_usr"
    mkdir -p "$(dirname "$candidate")"
    printf '%s\n' '#!/bin/bash' \
        'printf "%s\\n" "$1" >> "$BREW_LOG"' \
        'case "$1" in' \
        '  shellenv) printf "%s\\n" "export HOMEBREW_TEST_SHELLENV=loaded" ;;' \
        '  install) test "${HOMEBREW_TEST_SHELLENV:-}" = "loaded" ;;' \
        'esac' > "$candidate"
    chmod +x "$candidate"

    install_dependencies_source="$(extract_function install_dependencies | sed "s|/opt/homebrew/bin/brew|$fallback_opt|; s|/usr/local/bin/brew|$fallback_usr|")"
    source <(printf '%s\n' "$install_dependencies_source")
    command() {
        if [ "$1" = "-v" ] && [ "$2" = "brew" ]; then
            command_brew_checks=$((command_brew_checks + 1))
            [ "$command_brew_checks" -eq 1 ] && return 0
            return 1
        fi
        builtin command "$@"
    }

    OS_TYPE="Darwin"
    PYTHON_CMD=""
    unset HOMEBREW_TEST_SHELLENV
    : > "$BREW_LOG"
    install_dependencies
    unset -f command

    test "${HOMEBREW_TEST_SHELLENV:-}" = "loaded"
    test "$(sed -n '1p' "$BREW_LOG")" = "shellenv"
    test "$(sed -n '2p' "$BREW_LOG")" = "install"
}

test_homebrew_fallback "$test_root/opt/homebrew/bin/brew"
test_homebrew_fallback "$test_root/usr/local/bin/brew"

# Restore the unmodified implementation for the command -v brew case.
source <(extract_function install_dependencies)
brew_calls=()
brew() {
    case "$1" in
        shellenv)
            printf '%s\n' 'export HOMEBREW_TEST_SHELLENV=loaded'
            ;;
        install)
            test "${HOMEBREW_TEST_SHELLENV:-}" = "loaded"
            brew_calls+=("$*")
            ;;
        *)
            return 1
            ;;
    esac
}
OS_TYPE="Darwin"
PYTHON_CMD=""
unset HOMEBREW_TEST_SHELLENV
install_dependencies
test "${HOMEBREW_TEST_SHELLENV:-}" = "loaded"
test "${brew_calls[*]}" = "install python"

# ShellCheck-related contracts remain stable text contracts.
grep -Fq 'PIP_INSTALL_CMD=("$PYTHON_CMD" -m pip install --upgrade)' <<<"$script"
grep -Fq 'run_step "pip 安装 uv" "$PYTHON_CMD" -m pip install uv' "$setup_path"
! grep -Fq 'state_output=' <<<"$script"
! grep -Fq 'verify_output=' <<<"$script"

# sudo must be requested only when _sudo executes a privileged command.
for forbidden_sudo_setup in 'sudo -v' 'SUDO_KEEPALIVE_PID=' 'cleanup_sudo_keepalive'; do
    if grep -Fq "$forbidden_sudo_setup" "$setup_path"; then
        printf 'unexpected eager sudo setup: %s\n' "$forbidden_sudo_setup" >&2
        exit 1
    fi
done
bash -n "$setup_path"
