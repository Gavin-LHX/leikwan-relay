#!/usr/bin/env bash
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
#!/usr/bin/env python3
"""Isolated Linux relay/exit manager. Python standard library only."""
import argparse
import base64
import contextlib
import copy
import fcntl
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import platform
import re
import secrets
import shutil
import socket
import statistics
import struct
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.parse
import uuid
import zipfile

VERSION = '1.0.0'
ROOT = Path('/etc/leikwan-relay')
BASE = Path('/opt/leikwan-relay')
BIN = BASE / 'bin'
SELF = BASE / 'manager.py'
SB_VERSION = '1.14.4'
XR_VERSION = '26.11.9'
HASHES = {
    'sing-box-amd64': '699a1b510aa4396b2176d32d1181920399ebf1e267835da6f3b598d0f7c24968',
    'sing-box-arm64': '436441f76ee2f7fe21b5b2d426d3cb261a480455a704865789ad533e4273ec26',
    'xray-amd64': 'b651f7e1d9966ee2c1b1ee1bf8b52c72771824d3065dce96bbc8bcc19ed95f82',
    'xray-arm64': '64ed6858982a7f5eb85d88b811089063bd4f17561f4c8f44e0f1dc8e6f6430be',
}

def run(args, check=True, timeout=90, input=None):
    p = subprocess.run([str(a) for a in args], input=input, text=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    if check and p.returncode:
        # Never echo argv: it can contain credentials.
        raise RuntimeError(f'{args[0]} failed ({p.returncode}): {p.stderr.strip() or p.stdout.strip()}')
    return p.stdout.strip()

def atomic(path, data, mode=0o600):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, tmp = tempfile.mkstemp(prefix='.tmp-', dir=path.parent)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, 'w') as f:
            f.write(data)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)

def save(path, obj):
    atomic(path, json.dumps(obj, indent=2, ensure_ascii=False) + '\n')

def read(path, default=None):
    return json.loads(Path(path).read_text()) if Path(path).exists() else copy.deepcopy(default)

def valid_name(value):
    if not re.fullmatch(r'[a-z][a-z0-9-]{0,31}', value):
        raise ValueError('名称需为 1–32 位小写字母、数字、短横线，以字母开头')
    return value

def port(value):
    value = int(value)
    if not 1 <= value <= 65535:
        raise ValueError('端口必须在 1–65535')
    return value

def host(value):
    value = value.strip().strip('[]')
    try:
        return str(ipaddress.ip_address(value))
    except ValueError:
        if not re.fullmatch(r'(?=.{1,253}$)[a-zA-Z0-9](?:[a-zA-Z0-9.-]*[a-zA-Z0-9])?', value):
            raise ValueError('无效的主机名/IP')
        return value

def authority(h):
    return f'[{h}]' if ':' in h else h

def b64(data):
    if isinstance(data, str):
        data = data.encode()
    return base64.urlsafe_b64encode(data).decode().rstrip('=')

def unb64(data):
    return base64.urlsafe_b64decode(data + '=' * (-len(data) % 4))

def node_path(name):
    return ROOT / 'nodes' / valid_name(name)

def nodes():
    return [read(p) for p in sorted((ROOT / 'nodes').glob('*/node.json'))]

def routes():
    return read(ROOT / 'routes.json', {})

def unit(name, core):
    return f'lkr-{valid_name(name)}-{core}.service'

def service_file(name, core):
    return Path('/etc/systemd/system') / unit(name, core)

def install():
    machine = platform.machine()
    arch = {'x86_64': 'amd64', 'aarch64': 'arm64'}.get(machine)
    if not arch:
        raise ValueError('仅支持 Linux amd64 / arm64')
    BIN.mkdir(parents=True, exist_ok=True, mode=0o700)
    for core, version in [('sing-box', SB_VERSION), ('xray', XR_VERSION)]:
        dest = BIN / core
        try:
            if dest.exists() and version in run([dest, 'version'], check=False):
                continue
        except OSError:
            pass  # A partial first download is replaced only after verification.
        if core == 'sing-box':
            asset = f'sing-box-{version}-linux-{arch}.tar.gz'
            url = f'https://github.com/SagerNet/sing-box/releases/download/v{version}/{asset}'
        else:
            asset = 'Xray-linux-' + ('64' if arch == 'amd64' else 'arm64-v8a') + '.zip'
            url = f'https://github.com/XTLS/Xray-core/releases/download/v{version}/{asset}'
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / asset
            run(['curl', '-fL', '--retry', '3', '--connect-timeout', '15', '--max-time', '300',
                 '--proto', '=https', '--tlsv1.2', '-o', archive, url], timeout=330)
            if hashlib.sha256(archive.read_bytes()).hexdigest() != HASHES[f'{core}-{arch}']:
                raise ValueError('下载校验失败: ' + asset)
            if core == 'sing-box':
                with tarfile.open(archive) as t:
                    members = [m for m in t.getmembers() if m.isfile() and m.name.endswith('/sing-box')]
                    if len(members) != 1:
                        raise ValueError('压缩包内核不唯一')
                    data = t.extractfile(members[0]).read()
            else:
                with zipfile.ZipFile(archive) as z:
                    data = z.read('xray')
            staged = BIN / ('.' + core + '.new')
            staged.write_bytes(data)
            staged.chmod(0o755)
            if version not in run([staged, 'version']):
                raise ValueError('内核版本校验失败')
            os.replace(staged, dest)
    print(f'内核就绪: sing-box {SB_VERSION}, Xray {XR_VERSION}')

def local_sources():
    result = []
    for iface in json.loads(run(['ip', '-j', 'address', 'show'])):
        if iface['ifname'] == 'lo':
            continue
        for a in iface.get('addr_info', []):
            if a.get('scope') == 'global':
                result.append({'interface': iface['ifname'], 'source': a['local'],
                               'prefixlen': a['prefixlen']})
    return result

def validate_route(r):
    addr = ipaddress.ip_address(r['source'])
    gw = ipaddress.ip_address(r['gateway'])
    if addr.version != gw.version:
        raise ValueError('网关与源地址的 IP 版本不同')
    if not re.fullmatch(r'[a-zA-Z0-9_.:-]{1,15}', r['interface']):
        raise ValueError('无效网卡名')
    if not any(x['interface'] == r['interface'] and x['source'] == r['source'] for x in local_sources()):
        raise ValueError('源 IP 必须配置在所选本机网卡上')
    if not 24000 <= r['table'] < 25000:
        raise ValueError('本工具保留路由表/优先级范围 24000–24999')
    return addr.version

def route_commands(r, delete=False):
    family = '-4' if ipaddress.ip_address(r['source']).version == 4 else '-6'
    network = str(ipaddress.ip_network(f"{r['source']}/{r['prefixlen']}", strict=False))
    mask = '32' if family == '-4' else '128'
    rule = ['ip', family, 'rule']
    if delete:
        return [rule + ['del', 'pref', r['table'], 'from', r['source'] + '/' + mask,
                        'table', r['table']],
                ['ip', family, 'route', 'flush', 'table', r['table']]]
    return [
        ['ip', family, 'route', 'replace', 'table', r['table'], network, 'dev', r['interface'], 'src', r['source']],
        ['ip', family, 'route', 'replace', 'table', r['table'], 'default', 'via', r['gateway'],
         'dev', r['interface'], 'onlink', 'src', r['source']],
        rule + ['add', 'pref', r['table'], 'from', r['source'] + '/' + mask, 'table', r['table']],
    ]

def rule_matches(rule, r):
    mask = 32 if ipaddress.ip_address(r['source']).version == 4 else 128
    return (rule.get('src') in (r['source'], f"{r['source']}/{mask}")
            and str(rule.get('table')) == str(r['table']))

def route_apply_one(r):
    family = '-4' if validate_route(r) == 4 else '-6'
    rules = json.loads(run(['ip', family, '-j', 'rule', 'show']))
    at_pref = [x for x in rules if x.get('priority') == r['table']]
    if any(not rule_matches(x, r) for x in at_pref):
        raise ValueError(f"路由优先级冲突 {r['table']}")
    commands = route_commands(r)
    for cmd in commands[:-1]:
        run(cmd)
    if not at_pref:
        run(commands[-1])

def route_add(args):
    name = valid_name(args.name)
    all_routes = routes()
    if name in all_routes:
        raise ValueError('线路已存在；使用原线路或先 route-remove')
    src = str(ipaddress.ip_address(args.source))
    match = next((x for x in local_sources() if x['source'] == src and x['interface'] == args.interface), None)
    if not match:
        raise ValueError('指定 IP 不在指定网卡上')
    used = {r['table'] for r in all_routes.values()}
    table = args.table or next(i for i in range(24000, 25000) if i not in used)
    if table in used or any(r['source'] == src for r in all_routes.values()):
        raise ValueError('源 IP 或路由表已由另一条线路管理')
    r = dict(match, gateway=str(ipaddress.ip_address(args.gateway)), table=table)
    family = '-4' if validate_route(r) == 4 else '-6'
    # Refuse adoption/overwrite of routes not already owned by this manager.
    existing = run(['ip', family, 'route', 'show', 'table', table], check=False)
    occupied = any(x.get('priority') == table for x in json.loads(run(['ip', family, '-j', 'rule'])))
    if existing or occupied:
        raise ValueError('路由表/优先级已占用，请指定空闲 --table')
    try:
        route_apply_one(r)
        all_routes[name] = r
        save(ROOT / 'routes.json', all_routes)
        persist_routes()
    except Exception:
        for cmd in route_commands(r, delete=True):
            run(cmd, check=False)
        all_routes.pop(name, None)
        save(ROOT / 'routes.json', all_routes)
        raise
    print('线路已添加: ' + name)

def persist_routes():
    text = f'''[Unit]
Description=LeiKwan relay source routes
Wants=network-online.target
After=network-online.target
Before=lkr.target
[Service]
Type=oneshot
ExecStart=/usr/bin/python3 {SELF} routes-apply
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
'''
    atomic('/etc/systemd/system/lkr-routes.service', text, 0o644)
    run(['systemctl', 'daemon-reload'])
    run(['systemctl', 'enable', 'lkr-routes.service'])

def route_remove(name):
    all_routes = routes()
    if any(n.get('egress') == name for n in nodes()):
        raise ValueError('仍有节点使用该线路，请先 relay-set 或 remove')
    r = all_routes[name]
    for cmd in route_commands(r, delete=True):
        run(cmd, check=False)
    del all_routes[name]
    save(ROOT / 'routes.json', all_routes)
    print('已移除工具管理的源地址路由: ' + name)

def keypair():
    output = run([BIN / 'xray', 'x25519'])
    pairs = dict(re.findall(r'(?m)^([^:\n]+):\s*(\S+)', output))
    public = pairs.get('Password (PublicKey)') or pairs.get('Password') or pairs.get('PublicKey')
    if not public or not pairs.get('PrivateKey'):
        raise ValueError('无法解析 Xray x25519 输出')
    return pairs['PrivateKey'], public

def validate_upstream(p):
    if p.get('protocol') not in ('reality', 'anytls'):
        raise ValueError('上游仅支持 REALITY / AnyTLS')
    p['host'] = host(p['host'])
    p['port'] = port(p['port'])
    p['sni'] = host(p.get('sni', 'www.cloudflare.com'))
    if p['protocol'] == 'reality':
        uuid.UUID(p['uuid'])
        if not re.fullmatch(r'[A-Za-z0-9_-]{43}', p['public_key']):
            raise ValueError('无效 REALITY public key')
        if not re.fullmatch(r'(?:[a-fA-F0-9]{2}){0,8}', p.get('short_id', '')):
            raise ValueError('无效 short ID')
        if p.get('flow', '') not in ('', 'xtls-rprx-vision'):
            raise ValueError('不支持该 VLESS flow')
    else:
        if not isinstance(p.get('password'), str) or not p['password']:
            raise ValueError('AnyTLS 密码不能为空')
        if p.get('insecure'):
            raise ValueError('不接受 insecure AnyTLS；使用有效证书或包含证书的 lkr:// 配对信息')
        if p.get('certificate') and '-----BEGIN CERTIFICATE-----' not in p['certificate']:
            raise ValueError('无效 PEM 证书')
    return p

def parse_upstream(value):
    if value.startswith('@'):
        value = Path(value[1:]).read_text().strip()
    elif '://' not in value:
        value = Path(value).read_text().strip()
    if value.startswith('lkr://'):
        p = json.loads(unb64(value[6:]))
    elif value.startswith(('vless://', 'anytls://')):
        u = urllib.parse.urlsplit(value)
        q = {k: v[-1] for k, v in urllib.parse.parse_qs(u.query).items()}
        p = {'host': u.hostname, 'port': u.port or 443, 'sni': q.get('sni') or q.get('peer') or u.hostname}
        if u.scheme == 'vless':
            if q.get('security') != 'reality' or q.get('type', 'tcp') not in ('tcp', 'raw'):
                raise ValueError('只支持 VLESS REALITY TCP/raw 上游')
            if q.get('encryption', 'none') != 'none':
                raise ValueError('上游 REALITY 使用 encryption=none')
            p.update(protocol='reality', uuid=urllib.parse.unquote(u.username or ''),
                     public_key=q.get('pbk', ''), short_id=q.get('sid', ''),
                     flow=q.get('flow', ''), fingerprint=q.get('fp', 'chrome'))
        else:
            p.update(protocol='anytls', password=urllib.parse.unquote(u.username or ''),
                     insecure=q.get('insecure', q.get('allowInsecure', '0')).lower() in ('1', 'true'))
    else:
        p = json.loads(value)
    return validate_upstream(p)

def upstream_outbound(p, egress=None):
    p = validate_upstream(copy.deepcopy(p))
    out = {'type': 'vless' if p['protocol'] == 'reality' else 'anytls', 'tag': 'upstream',
           'server': p['host'], 'server_port': p['port']}
    tls = {'enabled': True, 'server_name': p['sni']}
    if p['protocol'] == 'reality':
        out.update(uuid=p['uuid'], flow=p.get('flow', 'xtls-rprx-vision'), packet_encoding='xudp')
        tls.update(utls={'enabled': True, 'fingerprint': p.get('fingerprint', 'chrome')},
                   reality={'enabled': True, 'public_key': p['public_key'], 'short_id': p.get('short_id', '')})
    else:
        out['password'] = p['password']
        if p.get('certificate'):
            tls['certificate'] = [p['certificate']]
    out['tls'] = tls
    if egress:
        out['bind_interface'] = egress['interface']
        key = 'inet4_bind_address' if ipaddress.ip_address(egress['source']).version == 4 else 'inet6_bind_address'
        out[key] = egress['source']
        # Prevent the opposite address family silently leaving by another path.
        try:
            if ipaddress.ip_address(p['host']).version != ipaddress.ip_address(egress['source']).version:
                raise ValueError('上游地址和线路的 IP 版本不一致')
        except ValueError as exc:
            if '不一致' in str(exc):
                raise
            # Explicit DNS resolving remains in this upstream's dialer.
            out['domain_resolver'] = {'server': 'local', 'strategy': 'ipv4_only' if key.startswith('inet4') else 'ipv6_only'}
    return out

def render(n, directory=None, route_map=None):
    directory = Path(directory or node_path(n['name']))
    sb = {'log': {'level': 'warn', 'timestamp': True},
          'dns': {'servers': [{'type': 'local', 'tag': 'local'}]},
          'inbounds': [], 'outbounds': [], 'route': {}}
    xr = None
    listen = {'listen': n.get('listen', '::'), 'listen_port': n['port'], 'tag': 'entry'}
    if n['role'] == 'exit':
        if n['protocol'] == 'reality':
            inbound = dict(listen, type='vless', users=[{'uuid': n['uuid'], 'flow': 'xtls-rprx-vision'}],
                           tls={'enabled': True, 'server_name': n['sni'], 'reality': {
                               'enabled': True, 'handshake': {'server': n['target'], 'server_port': n['target_port']},
                               'private_key': n['private_key'], 'short_id': [n['short_id']]}})
        else:
            inbound = dict(listen, type='anytls', users=[{'name': n['name'], 'password': n['password']}],
                           tls={'enabled': True, 'server_name': n['sni'],
                                'certificate_path': str(directory / 'cert.pem'), 'key_path': str(directory / 'key.pem')})
        sb['inbounds'] = [inbound]
        sb['outbounds'] = [{'type': 'direct', 'tag': 'direct'}]
        sb['route'] = {'rules': [{'ip_is_private': True, 'action': 'reject'}],
                       'final': 'direct', 'default_domain_resolver': 'local'}
    else:
        r = (routes() if route_map is None else route_map).get(n.get('egress'))
        if n.get('egress') and r is None:
            raise ValueError('未知线路: ' + n['egress'])
        sb['outbounds'] = [upstream_outbound(n['upstream'], r)]
        sb['route'] = {'final': 'upstream', 'default_domain_resolver': 'local'}
        sb['inbounds'] = [{'type': 'socks', 'tag': 'bridge', 'listen': '127.0.0.1', 'listen_port': n['bridge_port']}]
        if n['protocol'] == 'ss2022':
            sb['inbounds'].append(dict(listen, type='shadowsocks', method=n['method'], password=n['password']))
        elif n['protocol'] == 'snell5':
            sb['inbounds'].append(dict(listen, type='snell', version=5, psk=n['password']))
        else:
            xr = {'log': {'loglevel': 'warning'}, 'inbounds': [{
                'tag': 'entry', 'listen': n.get('listen', '::'), 'port': n['port'], 'protocol': 'vless',
                'settings': {'clients': [{'id': n['uuid']}], 'decryption': n['decryption']},
                'streamSettings': {'network': 'raw', 'security': 'none'}}],
                'outbounds': [{'protocol': 'socks', 'tag': 'upstream', 'settings': {
                    'servers': [{'address': '127.0.0.1', 'port': n['bridge_port']} ]}}]}
    return sb, xr

def public_profile(n):
    p = {k: n[k] for k in ('protocol', 'host', 'port', 'sni')}
    if n['protocol'] == 'reality':
        p.update(uuid=n['uuid'], public_key=n['public_key'], short_id=n['short_id'], flow='xtls-rprx-vision')
    else:
        p.update(password=n['password'], certificate=n['certificate'])
    return p

def client(n, local_port=1080, server=None):
    addr = server or n['host']
    if n['role'] == 'exit':
        out = upstream_outbound(public_profile(n))
        out['server'] = addr
    elif n['protocol'] == 'ss2022':
        out = {'type': 'shadowsocks', 'tag': 'upstream', 'server': addr, 'server_port': n['port'],
               'method': n['method'], 'password': n['password']}
    elif n['protocol'] == 'snell5':
        # sing-box's v4 client interoperates with the v5 TCP server.
        out = {'type': 'snell', 'tag': 'upstream', 'server': addr, 'server_port': n['port'],
               'version': 4, 'psk': n['password']}
    else:
        return 'xray', {'log': {'loglevel': 'warning'}, 'inbounds': [{'listen': '127.0.0.1', 'port': local_port,
            'protocol': 'socks', 'settings': {'udp': True}}], 'outbounds': [{'protocol': 'vless', 'settings': {
                'vnext': [{'address': addr, 'port': n['port'], 'users': [{'id': n['uuid'], 'encryption': n['encryption']}]}]},
            'streamSettings': {'network': 'raw', 'security': 'none'}}]}
    return 'sing-box', {'log': {'level': 'warn'}, 'dns': {'servers': [{'type': 'local', 'tag': 'local'}]},
        'inbounds': [{'type': 'socks', 'listen': '127.0.0.1', 'listen_port': local_port}],
        'outbounds': [out], 'route': {'final': 'upstream', 'default_domain_resolver': 'local'}}

def share(n):
    address = f"{authority(n['host'])}:{n['port']}"
    fragment = urllib.parse.quote(n['name'])
    if n['protocol'] == 'ss2022':
        return f"ss://{b64(n['method'] + ':' + n['password'])}@{address}#{fragment}"
    if n['protocol'] == 'snell5':
        return f"{n['name']} = snell, {n['host']}, {n['port']}, psk={n['password']}, version=5, reuse=true\n# Surge 建议 block-quic=all；本实现不支持 Snell v5 专用 QUIC Proxy"
    if n['protocol'] == 'vlessenc':
        query = {'encryption': n['encryption'], 'security': 'none', 'type': 'tcp'}
        return f"vless://{n['uuid']}@{address}?{urllib.parse.urlencode(query)}#{fragment}"
    p = public_profile(n)
    if n['protocol'] == 'reality':
        query = {'encryption': 'none', 'security': 'reality', 'sni': n['sni'], 'fp': 'chrome',
                 'pbk': n['public_key'], 'sid': n['short_id'], 'flow': 'xtls-rprx-vision', 'type': 'tcp'}
        uri = f"vless://{n['uuid']}@{address}?{urllib.parse.urlencode(query)}#{fragment}"
    else:
        uri = '# AnyTLS 自签证书随 lkr 配对信息传递，或使用 client.json；不生成跳过验证的链接。'
    return uri + '\nlkr://' + b64(json.dumps(p, separators=(',', ':')))

def free_port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]

def check_ports(n):
    # Fail before replacing files; existing node updates retain their own ports.
    previous = read(node_path(n['name']) / 'node.json')
    for p in {n['port']} | ({n['bridge_port']} if n['role'] == 'relay' else set()):
        if previous and p in (previous['port'], previous.get('bridge_port')):
            continue
        for fam, bind in [(socket.AF_INET, '0.0.0.0'), (socket.AF_INET6, '::')]:
            for kind in (socket.SOCK_STREAM, socket.SOCK_DGRAM):
                try:
                    with socket.socket(fam, kind) as s:
                        if fam == socket.AF_INET6:
                            s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
                        s.bind((bind, p))
                except OSError as exc:
                    if exc.errno not in (97, 99):
                        raise ValueError(f'端口 {p} 已占用') from exc

def service_text(n, core):
    cmd = f'{BIN / core} run ' + (f'-c {node_path(n["name"]) / "sing-box.json"}' if core == 'sing-box'
                                    else f'-config {node_path(n["name"]) / "xray.json"}')
    deps = f'Requires=lkr-routes.service\nAfter=lkr-routes.service\n' if n.get('egress') else ''
    if core == 'xray':
        deps += f'Requires={unit(n["name"], "sing-box")}\nAfter={unit(n["name"], "sing-box")}\n'
    return f'''[Unit]
Description=LeiKwan relay {n['name']} ({core})
Wants=network-online.target
After=network-online.target
{deps}[Service]
ExecStart={cmd}
Restart=on-failure
RestartSec=3
LimitNOFILE=65536
UMask=0077
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
[Install]
WantedBy=multi-user.target
'''

def apply_node(n, cert_files=None):
    valid_name(n['name'])
    n['host'] = host(n['host'])
    n['port'] = port(n['port'])
    ipaddress.ip_address(n.get('listen', '::'))
    install()
    check_ports(n)
    target = node_path(n['name'])
    target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    cores = ['sing-box'] + (['xray'] if n['protocol'] == 'vlessenc' else [])
    with tempfile.TemporaryDirectory(prefix='.stage-', dir=target.parent) as tmp:
        stage = Path(tmp)
        if target.exists():
            shutil.copytree(target, stage, dirs_exist_ok=True)
        if cert_files:
            for file, content in cert_files.items():
                atomic(stage / file, content)
        sb, xr = render(n, stage)
        save(stage / 'sing-box.json', sb)
        if xr:
            save(stage / 'xray.json', xr)
        run([BIN / 'sing-box', 'check', '-c', stage / 'sing-box.json'])
        if xr:
            run([BIN / 'xray', 'run', '-test', '-config', stage / 'xray.json'])
        save(stage / 'node.json', n)
        atomic(stage / 'share.txt', share(n) + '\n')
        core, config = client(n)
        save(stage / f'client-{core}.json', config)
        old_units = {c: service_file(n['name'], c).read_text() if service_file(n['name'], c).exists() else None for c in cores}
        active = {c: run(['systemctl', 'is-active', unit(n['name'], c)], check=False) == 'active' for c in cores}
        backup = None
        if target.exists():
            backup = ROOT / 'backups' / (n['name'] + '-' + str(time.time_ns()))
            backup.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            shutil.copytree(target, backup)
        try:
            # Validated certificate paths must refer to the final directory.
            sb, xr = render(n, target)
            save(stage / 'sing-box.json', sb)
            target.mkdir(mode=0o700, exist_ok=True)
            for f in stage.iterdir():
                if f.is_file():
                    atomic(target / f.name, f.read_text())
            for c in cores:
                atomic(service_file(n['name'], c), service_text(n, c), 0o644)
            run(['systemctl', 'daemon-reload'])
            for c in cores:
                run(['systemctl', 'enable', unit(n['name'], c)])
                run(['systemctl', 'restart', unit(n['name'], c)])
            time.sleep(1)
            for c in cores:
                if run(['systemctl', 'is-active', unit(n['name'], c)], check=False) != 'active':
                    raise RuntimeError('服务未运行: ' + unit(n['name'], c))
        except Exception:
            for c in reversed(cores):
                run(['systemctl', 'stop', unit(n['name'], c)], check=False)
            shutil.rmtree(target)
            if backup:
                shutil.copytree(backup, target)
            for c, text in old_units.items():
                if text is None:
                    run(['systemctl', 'disable', unit(n['name'], c)], check=False)
                    service_file(n['name'], c).unlink(missing_ok=True)
                else:
                    atomic(service_file(n['name'], c), text, 0o644)
            run(['systemctl', 'daemon-reload'], check=False)
            for c, was_active in active.items():
                if was_active:
                    run(['systemctl', 'start', unit(n['name'], c)], check=False)
            raise
    print(f"已部署 {n['name']}；连接信息: {target / 'share.txt'}")

def exit_add(a):
    if (node_path(a.name) / 'node.json').exists():
        raise ValueError('节点名称已存在')
    n = dict(name=valid_name(a.name), role='exit', protocol=a.protocol, host=host(a.host),
             port=port(a.port), listen=a.listen, sni=host(a.sni), uuid=str(uuid.uuid4()))
    install()
    cert_files = None
    if a.protocol == 'reality':
        n['private_key'], n['public_key'] = keypair()
        n.update(short_id=secrets.token_hex(8), target=host(a.target or a.sni), target_port=port(a.target_port))
    else:
        n['password'] = secrets.token_urlsafe(32)
        with tempfile.TemporaryDirectory() as tmp:
            cert, key = Path(tmp) / 'cert.pem', Path(tmp) / 'key.pem'
            run(['openssl', 'req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:prime256v1',
                 '-nodes', '-keyout', key, '-out', cert, '-days', '3650', '-subj', '/CN=' + n['sni'],
                 '-addext', 'subjectAltName=DNS:' + n['sni'], '-addext', 'basicConstraints=critical,CA:TRUE'])
            n['certificate'] = cert.read_text()
            cert_files = {'cert.pem': n['certificate'], 'key.pem': key.read_text()}
    apply_node(n, cert_files)

def relay_add(a):
    if (node_path(a.name) / 'node.json').exists():
        raise ValueError('节点名称已存在')
    n = dict(name=valid_name(a.name), role='relay', protocol=a.protocol, host=host(a.host),
             port=port(a.port), listen=a.listen, egress=a.egress, upstream=parse_upstream(a.upstream),
             bridge_port=a.bridge_port or free_port())
    if n['bridge_port'] == n['port']:
        raise ValueError('公网端口与本地桥接端口不能相同')
    if a.protocol == 'vlessenc':
        install()
        private, public = keypair()
        n.update(uuid=str(uuid.uuid4()), decryption='mlkem768x25519plus.native.600s.' + private,
                 encryption='mlkem768x25519plus.native.1rtt.' + public)
    else:
        n.update(method='2022-blake3-aes-128-gcm', password=(base64.b64encode(secrets.token_bytes(16)).decode()
                                                        if a.protocol == 'ss2022' else secrets.token_urlsafe(32)))
    apply_node(n)

def relay_set(a):
    n = read(node_path(a.name) / 'node.json')
    if not n or n['role'] != 'relay':
        raise ValueError('找不到中转节点')
    if a.egress is not None:
        n['egress'] = None if a.egress == 'default' else a.egress
    if a.upstream:
        n['upstream'] = parse_upstream(a.upstream)
    apply_node(n)

def remove(name):
    target = node_path(name)
    if not (target / 'node.json').exists():
        raise ValueError('找不到节点')
    backup = ROOT / 'backups' / (name + '-removed-' + str(time.time_ns()))
    backup.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    shutil.copytree(target, backup)
    for core in ('xray', 'sing-box'):
        if service_file(name, core).exists():
            run(['systemctl', 'disable', '--now', unit(name, core)])
            service_file(name, core).unlink()
    run(['systemctl', 'daemon-reload'])
    shutil.rmtree(target)
    print('节点已移除；备份: ' + str(backup))

def tcp_samples(target, target_port, source, count):
    durations = []
    failures = 0
    family = socket.AF_INET6 if ipaddress.ip_address(target).version == 6 else socket.AF_INET
    for _ in range(count):
        with socket.socket(family) as s:
            s.settimeout(3)
            if source:
                s.bind((source, 0))
            start = time.monotonic()
            try:
                s.connect((target, target_port))
                durations.append((time.monotonic() - start) * 1000)
            except OSError:
                failures += 1
        time.sleep(0.1)
    return {'attempts': count, 'success': len(durations), 'failed': failures,
            'median_ms': round(statistics.median(durations), 2) if durations else None,
            'jitter_ms': round(statistics.pstdev(durations), 2) if durations else None}

def probe(a):
    target = str(ipaddress.ip_address(a.target))
    selected = routes()
    if a.egress:
        selected = {name: selected[name] for name in a.egress}
    if not selected:
        raise ValueError('先 route-add 配置线路')
    result = {'target': target, 'port': a.port, 'unix_time': int(time.time()), 'routes': {}}
    for name, r in selected.items():
        if ipaddress.ip_address(r['source']).version != ipaddress.ip_address(target).version:
            continue
        route_apply_one(r)
        samples = tcp_samples(target, a.port, r['source'], a.count)
        samples['source'] = r['source']
        samples['interface'] = r['interface']
        trace = ''
        commands = []
        if shutil.which('mtr'):
            commands.append(['mtr', '-n', '-r', '-w', '-c', str(a.count), '-a', r['source'], '-T', '-P', str(a.port), target])
        if shutil.which('traceroute'):
            commands.append(['traceroute', '-n', '-T', '-p', str(a.port), '-s', r['source'], '-m', '24', '-w', '0.3', '-q', '1', target])
        if a.nexttrace and shutil.which('nexttrace'):
            commands.append(['nexttrace', '-n', '-T', '-p', str(a.port), '-s', r['source'], target])
        for cmd in commands:
            try:
                trace += '\n' + Path(cmd[0]).name + '\n' + run(cmd, check=False, timeout=50) + '\n'
            except subprocess.TimeoutExpired:
                trace += '\n' + Path(cmd[0]).name + ': timeout\n'
        # Infer only when actual observed hops match known backbone ranges.
        samples['observed_backbone'] = ('CN2' if re.search(r'\b59\.43\.', trace) else
                                        '9929' if re.search(r'\b(?:210\.13|218\.105|210\.14)\.', trace) else 'unknown')
        samples['trace'] = trace
        result['routes'][name] = samples
        print(name + ': ' + json.dumps({k: v for k, v in samples.items() if k != 'trace'}, ensure_ascii=False))
        print(trace)
    eligible = [(name, v) for name, v in result['routes'].items() if v['success']]
    if eligible:
        result['recommended'] = min(eligible, key=lambda item: (item[1]['failed'] / item[1]['attempts'],
                                       item[1]['median_ms'], item[1]['jitter_ms']))[0]
        print('本轮建议: ' + result['recommended'] + '（先比较目标端口连接失败率，再比较中位延迟和抖动；未自动切换）')
    else:
        result['recommended'] = None
        print('所有线路均失败，不作推荐')
    if a.output:
        save(Path(a.output), result)

def socks_udp_query(local_port, dns_server='1.1.1.1'):
    """An actual DNS datagram through SOCKS UDP ASSOCIATE, not TCP DNS."""
    def exact(stream, size):
        data = b''
        while len(data) < size:
            chunk = stream.recv(size - len(data))
            if not chunk:
                raise RuntimeError('SOCKS 连接提前关闭')
            data += chunk
        return data
    with socket.create_connection(('127.0.0.1', local_port), 5) as control:
        control.settimeout(15)
        control.sendall(b'\x05\x01\x00')
        if exact(control, 2) != b'\x05\x00':
            raise RuntimeError('SOCKS 认证协商失败')
        control.sendall(b'\x05\x03\x00\x01' + b'\0' * 6)
        reply = exact(control, 4)
        if reply[:2] != b'\x05\x00':
            raise RuntimeError('SOCKS UDP ASSOCIATE 失败')
        if reply[3] == 1:
            relay = socket.inet_ntop(socket.AF_INET, exact(control, 4))
        elif reply[3] == 4:
            relay = socket.inet_ntop(socket.AF_INET6, exact(control, 16))
        else:
            raise RuntimeError('SOCKS UDP 返回未知地址格式')
        relay_port = struct.unpack('!H', exact(control, 2))[0]
        if relay in ('0.0.0.0', '::'):
            relay = '127.0.0.1'
        family = socket.AF_INET6 if ':' in relay else socket.AF_INET
        ident = secrets.randbelow(65536)
        question = b'\x07example\x03com\x00\x00\x01\x00\x01'
        query = struct.pack('!HHHHHH', ident, 0x100, 1, 0, 0, 0) + question
        packet = b'\x00\x00\x00\x01' + socket.inet_aton(dns_server) + struct.pack('!H', 53) + query
        with socket.socket(family, socket.SOCK_DGRAM) as udp:
            udp.settimeout(15)
            udp.sendto(packet, (relay, relay_port))
            response, _ = udp.recvfrom(8192)
        if len(response) < 10 or response[:3] != b'\0\0\0':
            raise RuntimeError('无效 SOCKS UDP 回复')
        offset = {1: 10, 4: 22}.get(response[3])
        if response[3] == 3:
            offset = 7 + response[4]
        if offset is None or len(response) < offset + 12:
            raise RuntimeError('SOCKS UDP 回复截断')
        msg_id, flags, _, answers, _, _ = struct.unpack('!HHHHHH', response[offset:offset + 12])
        if msg_id != ident or not flags & 0x8000 or flags & 0xf or answers == 0:
            raise RuntimeError('UDP DNS 未获得有效解析结果')
        return {'udp_dns': 'ok', 'server': dns_server, 'question': 'example.com A', 'answers': answers}

def test_node(a):
    n = read(node_path(a.name) / 'node.json')
    if not n:
        raise ValueError('找不到节点')
    listen_port = free_port()
    core, cfg = client(n, listen_port, a.server or '::1')
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / 'client.json'
        save(path, cfg)
        cmd = [BIN / core, 'run', '-c' if core == 'sing-box' else '-config', path]
        with open(Path(tmp) / 'client.log', 'w+') as log:
            proc = subprocess.Popen([str(x) for x in cmd], stdout=log, stderr=log)
            try:
                for _ in range(50):
                    if proc.poll() is not None:
                        raise RuntimeError('测试客户端启动失败')
                    try:
                        with socket.create_connection(('127.0.0.1', listen_port), 0.1):
                            break
                    except OSError:
                        time.sleep(0.1)
                print(run(['curl', '-fsS', '--max-time', '30', '--socks5-hostname', f'127.0.0.1:{listen_port}', a.url], timeout=35))
                if a.udp:
                    print(json.dumps(socks_udp_query(listen_port), ensure_ascii=False))
            finally:
                proc.terminate()
                try:
                    proc.wait(5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()

def menu():
    print('LeiKwan Relay ' + VERSION + '\n1) 查看节点/服务\n2) 添加落地\n3) 添加中转\n4) 切换中转线路/落地\n5) 查看连接信息\n6) 查看本机地址/线路\n7) 添加源地址线路\n8) 比较线路\n9) 测试节点\n0) 退出')
    pick = input('选择: ').strip()
    def ask(label, default=None):
        value = input(label + (f' [{default}]' if default else '') + ': ').strip()
        return value or default
    if pick == '0':
        return
    if pick == '1':
        argv = ['list']
    elif pick == '2':
        argv = ['exit-add', '--name', ask('名称'), '--protocol', ask('协议 reality/anytls', 'reality'),
                '--host', ask('客户端可达 IP/域名'), '--port', ask('监听端口', '18443'), '--sni', ask('SNI', 'www.cloudflare.com')]
    elif pick == '3':
        print('可用线路: ' + ', '.join(routes()))
        argv = ['relay-add', '--name', ask('名称'), '--protocol', ask('协议 ss2022/vlessenc/snell5', 'ss2022'),
                '--host', ask('客户端可达 IP/域名（NAT 机器可用公网 IPv6）'), '--port', ask('监听端口', '20001'),
                '--upstream', ask('落地 lkr:// 或 vless:// 链接或文件路径')]
        egress = ask('线路名称（留空使用系统默认）')
        if egress:
            argv += ['--egress', egress]
    elif pick == '4':
        argv = ['relay-set', '--name', ask('中转名称')]
        egress = ask('新线路名称，default 为系统默认（留空保留）')
        upstream = ask('新落地链接/文件（留空保留）')
        if egress:
            argv += ['--egress', egress]
        if upstream:
            argv += ['--upstream', upstream]
    elif pick in ('5', '9'):
        argv = ['show' if pick == '5' else 'test', '--name', ask('名称')]
    elif pick == '6':
        argv = ['routes']
    elif pick == '7':
        argv = ['route-add', '--name', ask('线路名称'), '--interface', ask('网卡'),
                '--source', ask('本机源 IP'), '--gateway', ask('对应网关')]
    elif pick == '8':
        argv = ['probe', '--target', ask('落地 IP'), '--port', ask('落地端口', '18443')]
    else:
        raise ValueError('无效选择')
    dispatch(parser().parse_args(argv))

def parser():
    p = argparse.ArgumentParser(description='SS2022 / VLESS Encryption / Snell v5 → REALITY / AnyTLS；独立服务、按节点选线路')
    p.add_argument('--version', action='version', version=VERSION)
    sub = p.add_subparsers(dest='command')
    sub.add_parser('install')
    sub.add_parser('list')
    sub.add_parser('routes')
    sub.add_parser('routes-apply')
    q = sub.add_parser('route-add')
    for opt in ('name', 'interface', 'source', 'gateway'):
        q.add_argument('--' + opt, required=True)
    q.add_argument('--table', type=int)
    q = sub.add_parser('route-remove')
    q.add_argument('--name', required=True)
    q = sub.add_parser('exit-add')
    q.add_argument('--name', required=True)
    q.add_argument('--protocol', choices=['reality', 'anytls'], required=True)
    q.add_argument('--host', required=True)
    q.add_argument('--port', type=port, default=18443)
    q.add_argument('--listen', default='::')
    q.add_argument('--sni', default='www.cloudflare.com')
    q.add_argument('--target')
    q.add_argument('--target-port', type=port, default=443)
    q = sub.add_parser('relay-add')
    q.add_argument('--name', required=True)
    q.add_argument('--protocol', choices=['ss2022', 'vlessenc', 'snell5'], required=True)
    q.add_argument('--host', required=True)
    q.add_argument('--port', type=port, required=True)
    q.add_argument('--listen', default='::')
    q.add_argument('--upstream', required=True)
    q.add_argument('--egress')
    q.add_argument('--bridge-port', type=port)
    q = sub.add_parser('relay-set')
    q.add_argument('--name', required=True)
    q.add_argument('--upstream')
    q.add_argument('--egress')
    q = sub.add_parser('probe')
    q.add_argument('--target', required=True)
    q.add_argument('--port', type=port, default=18443)
    q.add_argument('--count', type=int, choices=range(3, 101), default=10)
    q.add_argument('--egress', action='append')
    q.add_argument('--output')
    q.add_argument('--nexttrace', action='store_true')
    q = sub.add_parser('test')
    q.add_argument('--name', required=True)
    q.add_argument('--server', help='覆盖入口地址，默认 ::1；远端测试可填实际公网地址')
    q.add_argument('--url', default='https://www.cloudflare.com/cdn-cgi/trace')
    q.add_argument('--udp', action='store_true', help='额外验证 SOCKS UDP 经完整链路查询公共 DNS')
    for cmd in ('show', 'remove'):
        q = sub.add_parser(cmd)
        q.add_argument('--name', required=True)
    return p

def dispatch(a):
    if a.command == 'install':
        install()
    elif a.command == 'exit-add':
        exit_add(a)
    elif a.command == 'relay-add':
        relay_add(a)
    elif a.command == 'relay-set':
        relay_set(a)
    elif a.command == 'remove':
        remove(a.name)
    elif a.command == 'show':
        print((node_path(a.name) / 'share.txt').read_text())
        print('客户端 JSON: ' + ', '.join(str(x) for x in node_path(a.name).glob('client-*.json')))
    elif a.command == 'list':
        for n in nodes():
            state = run(['systemctl', 'is-active', unit(n['name'], 'sing-box')], check=False)
            if n['protocol'] == 'vlessenc':
                state += '/' + run(['systemctl', 'is-active', unit(n['name'], 'xray')], check=False)
            print(f"{n['name']:24s} {n['role']:5s} {n['protocol']:10s} :{n['port']} {n.get('egress') or 'default'} {state}")
    elif a.command == 'routes':
        print(json.dumps({'local_addresses': local_sources(), 'managed_routes': routes()}, indent=2, ensure_ascii=False))
    elif a.command == 'route-add':
        route_add(a)
    elif a.command == 'route-remove':
        route_remove(a.name)
    elif a.command == 'routes-apply':
        for r in routes().values():
            route_apply_one(r)
    elif a.command == 'probe':
        probe(a)
    elif a.command == 'test':
        test_node(a)
    else:
        menu()

def main():
    args = parser().parse_args()
    if os.geteuid() != 0:
        raise ValueError('请使用 root / sudo 运行')
    if not Path('/run/systemd/system').exists():
        raise ValueError('需要 Linux systemd；当前支持 Debian 12/13、Ubuntu 22.04/24.04')
    ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
    ROOT.chmod(0o700)
    BASE.mkdir(parents=True, exist_ok=True, mode=0o700)
    # The routes unit can start while a node command holds the node lock.
    # Separate locks prevent deadlock and still serialize route mutations.
    lock_name = '.routes.lock' if args.command in ('route-add', 'route-remove', 'routes-apply', 'probe') else '.lock'
    with open(ROOT / lock_name, 'w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError('另一个管理命令正在运行')
        dispatch(args)

if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError, RuntimeError, subprocess.SubprocessError) as exc:
        print('错误: ' + str(exc), file=sys.stderr)
        sys.exit(1)
LEIKWAN_RELAY_PYTHON_PAYLOAD
chmod 700 "$payload"
mv -f -- "$payload" /opt/leikwan-relay/manager.py
trap - EXIT
cat > /usr/local/bin/lkr <<'LEIKWAN_RELAY_LAUNCHER'
#!/usr/bin/env bash
exec python3 /opt/leikwan-relay/manager.py "$@"
LEIKWAN_RELAY_LAUNCHER
chmod 755 /usr/local/bin/lkr
exec python3 /opt/leikwan-relay/manager.py "$@"
