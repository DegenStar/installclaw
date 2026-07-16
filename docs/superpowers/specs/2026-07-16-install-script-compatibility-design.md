# Install-script compatibility design

## Scope

Apply only the approved compatibility and static-quality changes to `setup.sh`:

- support the package managers already detected by the script: apt/apt-get, dnf, yum, pacman, zypper, and apk;
- make a newly installed Homebrew available during the same macOS run;
- avoid a standalone pacman database refresh;
- remove the current ShellCheck warnings without changing the broader installer policy.

`setup.ps1`, remote-script execution, privilege handling, logging, and exit-status policy are deliberately out of scope.

## Design

`resolve_pkg_name` will map generic dependency names to their package-manager names. `python3-pip` maps to `python-pip` on pacman and `py3-pip` on apk; all other current managers retain `python3-pip`. Clipboard dependencies keep the existing `xclip` / pure-Wayland `wl-clipboard` selection.

After Homebrew installation, the script will attempt Homebrew's official `shellenv` command. It will discover the binary in the existing PATH, `/opt/homebrew/bin/brew`, or `/usr/local/bin/brew`, then evaluate its shell environment before issuing `brew install python`.

Pacman installation will use `pacman -S --needed --noconfirm` rather than `pacman -Sy`, preventing an isolated database refresh and avoiding reinstalls for satisfied packages.

The pip command array will be initialized with a quoted array element, and unused package-version output variables will be removed while retaining their exit-code-based checks.

## Verification

A shell test will assert the intended package mappings, Homebrew initialization, pacman flags, and absence of the prior unused assignments. It will first fail against the current script, then pass after implementation. Final checks: `bash -n setup.sh` and `shellcheck -S warning setup.sh`.
