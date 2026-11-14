# shellcheck shell=sh
# The agents' browser on Linux (#5209, #5228): Google Chrome stable, headed under Xvfb,
# which Google sign-in and Cloudflare let in where they refuse Chrome for Testing
# headless. It is installed only with root, or sudo that asks no password, on Debian or
# Ubuntu x86_64 (Google ships no Chrome for Linux arm64). Otherwise nothing is installed,
# the browser stays Chrome for Testing headless, and one line says why. Chrome then
# updates from Google's apt repository, as on any desktop. This step never stops the
# install. install.sh holds the same text (a test keeps them equal).
install_browser() {
    if command -v google-chrome-stable >/dev/null 2>&1 && command -v Xvfb >/dev/null 2>&1; then
        return 0
    fi
    headless="The agents' browser here stays Chrome for Testing headless:"
    case "$(uname -m)" in
        x86_64|amd64) ;;
        *) echo "$headless Google ships no Chrome for Linux $(uname -m)."; return 0 ;;
    esac
    if [ ! -f /etc/debian_version ] || ! command -v apt-get >/dev/null 2>&1; then
        echo "$headless Agents installs Google Chrome and Xvfb only on Debian or Ubuntu."
        return 0
    fi
    if [ "$(id -u)" = 0 ]; then
        as=
    elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        as="sudo -n"
    else
        echo "$headless installing Google Chrome and Xvfb needs root, or sudo with no password."
        return 0
    fi
    echo "Installing Google Chrome and Xvfb for the agents' browser…"
    # Enough for the first install. Chrome's package then writes its own source,
    # google-chrome.sources, signed by its own keyring, and removes this .list.
    key=$(mktemp) || return 0
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$key" https://dl.google.com/linux/linux_signing_key.pub
    else
        wget -q -O "$key" https://dl.google.com/linux/linux_signing_key.pub
    fi || { rm -f "$key"; echo "$headless Google's signing key could not be fetched."; return 0; }
    if ! grep -q "BEGIN PGP PUBLIC KEY BLOCK" "$key"; then
        rm -f "$key"; echo "$headless Google's signing key was not a key."; return 0
    fi
    $as install -D -m 644 "$key" /etc/apt/trusted.gpg.d/google-chrome.asc || { rm -f "$key"; return 0; }
    rm -f "$key"
    echo "deb [arch=amd64] https://dl.google.com/linux/chrome/deb/ stable main" |
        $as tee /etc/apt/sources.list.d/google-chrome.list >/dev/null || return 0
    if $as env DEBIAN_FRONTEND=noninteractive apt-get -qq update >/dev/null &&
        $as env DEBIAN_FRONTEND=noninteractive apt-get -qq install -y google-chrome-stable xvfb >/dev/null; then
        # Its source names its own keyring, so the key above need not be trusted for
        # every repository.
        if [ -f /etc/apt/sources.list.d/google-chrome.sources ]; then
            $as rm -f /etc/apt/trusted.gpg.d/google-chrome.asc
        fi
        echo "Installed $(google-chrome-stable --version 2>/dev/null | sed 's/ *$//') and Xvfb."
    else
        echo "$headless apt-get could not install Google Chrome and Xvfb."
    fi
    return 0
}
