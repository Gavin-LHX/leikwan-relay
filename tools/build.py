"""Rebuild the single-file, self-contained Bash entry point."""
from pathlib import Path
root = Path(__file__).resolve().parents[1]
header = '''#!/usr/bin/env bash
# Generated from src/manager.py by tools/build.py. Do not edit the payload here.
set -euo pipefail
umask 077
[[ ${EUID} -eq 0 ]] || { echo '请使用 root / sudo 运行' >&2; exit 1; }
[[ -d /run/systemd/system ]] || { echo '需要 Linux systemd' >&2; exit 1; }
if ! command -v python3 >/dev/null || ! command -v curl >/dev/null || ! command -v openssl >/dev/null || ! command -v ip >/dev/null; then
    command -v apt-get >/dev/null || { echo '请安装 python3 curl openssl iproute2 ca-certificates' >&2; exit 1; }
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y python3 curl openssl iproute2 ca-certificates
fi
install -d -m 700 /opt/leikwan-relay
payload=$(mktemp /opt/leikwan-relay/.manager.XXXXXX)
trap 'rm -f -- "$payload"' EXIT
cat > "$payload" <<'LEIKWAN_RELAY_PYTHON_PAYLOAD'
'''
footer = '''LEIKWAN_RELAY_PYTHON_PAYLOAD
chmod 700 "$payload"
mv -f -- "$payload" /opt/leikwan-relay/manager.py
trap - EXIT
cat > /usr/local/bin/lkr <<'LEIKWAN_RELAY_LAUNCHER'
#!/usr/bin/env bash
exec python3 /opt/leikwan-relay/manager.py "$@"
LEIKWAN_RELAY_LAUNCHER
chmod 755 /usr/local/bin/lkr
exec python3 /opt/leikwan-relay/manager.py "$@"
'''
(root / 'deploy.sh').write_text(header + (root / 'src/manager.py').read_text(encoding='utf-8') + footer, encoding='utf-8', newline='\n')
print('Built deploy.sh')
