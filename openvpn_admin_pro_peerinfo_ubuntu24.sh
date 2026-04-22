#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

APP_DIR="/var/www/html/ovpn-admin"
DATA_DIR="$APP_DIR/data"
DOWNLOAD_DIR="$APP_DIR/downloads"
DB_FILE="$DATA_DIR/ovpn.sqlite"
PKI_DIR="/etc/openvpn/pki-webadmin"
OPENVPN_LOG_DIR="/var/log/openvpn"
ADMIN_USER="openvpn"
ADMIN_PASS="Easin112233@"
DEFAULT_USER="Easin"
DEFAULT_USER_PASS="Easin112233@"
UDP_PORT="1194"
TCP_PORT="443"
UDP_SUBNET="10.8.0.0 255.255.255.0"
TCP_SUBNET="10.9.0.0 255.255.255.0"

detect_public_ip() {
  local ip=""
  for url in https://api.ipify.org https://ifconfig.me https://ipv4.icanhazip.com; do
    ip="$(curl -4 -fsSL "$url" 2>/dev/null | tr -d '\r\n' || true)"
    [[ -n "$ip" ]] && break
  done
  if [[ -z "$ip" ]]; then
    ip="$(hostname -I | awk '{print $1}')"
  fi
  echo "$ip"
}

SERVER_IP="$(detect_public_ip)"
if [[ -z "$SERVER_IP" ]]; then
  echo "Could not detect public IP."
  exit 1
fi

NET_IFACE="$(ip route get 1.1.1.1 | awk '/dev/ {for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')"
: "${NET_IFACE:=eth0}"

echo "[1/10] Installing packages..."
apt-get update
apt-get install -y openvpn easy-rsa apache2 php libapache2-mod-php php-sqlite3 php-cli sqlite3 curl unzip openssl ca-certificates php-mbstring

echo "[2/10] Preparing directories..."
mkdir -p "$APP_DIR" "$DATA_DIR" "$DOWNLOAD_DIR" "$PKI_DIR" "$OPENVPN_LOG_DIR" /etc/openvpn/server /usr/local/bin

echo "[3/10] Enabling IP forwarding..."
cat >/etc/sysctl.d/99-openvpn-forward.conf <<'EOF'
net.ipv4.ip_forward=1
EOF
sysctl --system >/dev/null

echo "[4/10] Configuring firewall/NAT..."
cat >/usr/local/bin/ovpn-iptables-apply.sh <<EOF
#!/usr/bin/env bash
set -e
iptables -t nat -C POSTROUTING -s 10.8.0.0/24 -o ${NET_IFACE} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o ${NET_IFACE} -j MASQUERADE
iptables -t nat -C POSTROUTING -s 10.9.0.0/24 -o ${NET_IFACE} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s 10.9.0.0/24 -o ${NET_IFACE} -j MASQUERADE
iptables -C INPUT -p udp --dport ${UDP_PORT} -j ACCEPT 2>/dev/null || iptables -A INPUT -p udp --dport ${UDP_PORT} -j ACCEPT
iptables -C INPUT -p tcp --dport ${TCP_PORT} -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport ${TCP_PORT} -j ACCEPT
iptables -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport 80 -j ACCEPT
iptables -C INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
EOF
chmod +x /usr/local/bin/ovpn-iptables-apply.sh

cat >/etc/systemd/system/ovpn-iptables.service <<'EOF'
[Unit]
Description=Apply iptables rules for OpenVPN webadmin
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ovpn-iptables-apply.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

echo "[5/10] Building OpenVPN PKI..."
rm -rf /root/easy-rsa
make-cadir /root/easy-rsa
cd /root/easy-rsa
./easyrsa init-pki
EASYRSA_BATCH=1 ./easyrsa build-ca nopass <<<''
EASYRSA_BATCH=1 ./easyrsa build-server-full server nopass
./easyrsa gen-dh
openvpn --genkey secret pki/ta.key
cp pki/ca.crt "$PKI_DIR/"
cp pki/issued/server.crt "$PKI_DIR/"
cp pki/private/server.key "$PKI_DIR/"
cp pki/dh.pem "$PKI_DIR/"
cp pki/ta.key "$PKI_DIR/"
chmod 600 "$PKI_DIR/server.key" "$PKI_DIR/ta.key"

echo "[6/10] Creating SQLite database..."
sqlite3 "$DB_FILE" <<'SQL'
PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS admins (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  username TEXT UNIQUE NOT NULL,
  password_hash TEXT NOT NULL,
  created_at TEXT DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS users (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  username TEXT UNIQUE NOT NULL,
  password_hash TEXT NOT NULL,
  created_at TEXT DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS connection_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  event_type TEXT NOT NULL,
  event_time TEXT DEFAULT CURRENT_TIMESTAMP,
  username TEXT,
  common_name TEXT,
  real_ip TEXT,
  virtual_ip TEXT,
  platform TEXT,
  platform_version TEXT,
  openvpn_version TEXT,
  gui_version TEXT,
  ssl_library TEXT,
  hwaddr TEXT,
  trusted_ip TEXT,
  trusted_port TEXT,
  untrusted_ip TEXT,
  untrusted_port TEXT,
  source_instance TEXT,
  raw_peer_info TEXT,
  app_hint TEXT
);
SQL

ADMIN_HASH="$(php -r "echo password_hash('${ADMIN_PASS}', PASSWORD_DEFAULT);")"
USER_HASH="$(php -r "echo password_hash('${DEFAULT_USER_PASS}', PASSWORD_DEFAULT);")"
sqlite3 "$DB_FILE" "INSERT OR REPLACE INTO admins(username,password_hash) VALUES('${ADMIN_USER}','${ADMIN_HASH//\'/\'\'}');"
sqlite3 "$DB_FILE" "INSERT OR REPLACE INTO users(username,password_hash) VALUES('${DEFAULT_USER}','${USER_HASH//\'/\'\'}');"

echo "[7/10] Writing auth/log/profile helper scripts..."
cat >/usr/local/bin/ovpn-auth.php <<'PHP'
<?php
$db = new SQLite3('/var/www/html/ovpn-admin/data/ovpn.sqlite');
$user = getenv('username') ?: '';
$pass = getenv('password') ?: '';
if ($user === '' || $pass === '') { exit(1); }
$stmt = $db->prepare('SELECT password_hash FROM users WHERE username = :u LIMIT 1');
$stmt->bindValue(':u', $user, SQLITE3_TEXT);
$res = $stmt->execute();
$row = $res ? $res->fetchArray(SQLITE3_ASSOC) : false;
if ($row && isset($row['password_hash']) && password_verify($pass, $row['password_hash'])) {
    exit(0);
}
exit(1);
PHP

cat >/usr/local/bin/ovpn-auth.sh <<'EOF'
#!/usr/bin/env bash
exec php /usr/local/bin/ovpn-auth.php
EOF
chmod +x /usr/local/bin/ovpn-auth.sh

cat >/usr/local/bin/ovpn-log-event.php <<'PHP'
<?php
$db = new SQLite3('/var/www/html/ovpn-admin/data/ovpn.sqlite');
$db->busyTimeout(5000);

function envv($k) {
    $v = getenv($k);
    return $v === false ? '' : (string)$v;
}

function pick_app_hint(array $peerInfo): string {
    $preferred = ['UV_APP_PACKAGE', 'UV_PACKAGE_NAME', 'UV_APP_NAME', 'IV_GUI_VER', 'IV_PLAT', 'IV_VER'];
    foreach ($preferred as $key) {
        if (!empty($peerInfo[$key])) return (string)$peerInfo[$key];
    }
    return '';
}

$peerInfo = [];
foreach ($_ENV as $key => $value) {
    if (
        strpos($key, 'IV_') === 0 ||
        strpos($key, 'UV_') === 0 ||
        in_array($key, [
            'trusted_ip','trusted_port','untrusted_ip','untrusted_port',
            'ifconfig_pool_remote_ip','ifconfig_pool_local_ip',
            'common_name','username','script_type','daemon_pid'
        ], true)
    ) {
        $peerInfo[$key] = (string)$value;
    }
}
ksort($peerInfo);

$appHint = pick_app_hint($peerInfo);
$stmt = $db->prepare('INSERT INTO connection_events(event_type, username, common_name, real_ip, virtual_ip, platform, platform_version, openvpn_version, gui_version, ssl_library, hwaddr, trusted_ip, trusted_port, untrusted_ip, untrusted_port, source_instance, raw_peer_info, app_hint) VALUES (:event_type,:username,:common_name,:real_ip,:virtual_ip,:platform,:platform_version,:openvpn_version,:gui_version,:ssl_library,:hwaddr,:trusted_ip,:trusted_port,:untrusted_ip,:untrusted_port,:source_instance,:raw_peer_info,:app_hint)');
$stmt->bindValue(':event_type', envv('script_type') === 'client-disconnect' ? 'disconnect' : 'connect', SQLITE3_TEXT);
$stmt->bindValue(':username', envv('username'), SQLITE3_TEXT);
$stmt->bindValue(':common_name', envv('common_name'), SQLITE3_TEXT);
$stmt->bindValue(':real_ip', envv('trusted_ip'), SQLITE3_TEXT);
$stmt->bindValue(':virtual_ip', envv('ifconfig_pool_remote_ip'), SQLITE3_TEXT);
$stmt->bindValue(':platform', envv('IV_PLAT'), SQLITE3_TEXT);
$stmt->bindValue(':platform_version', envv('IV_PLAT_VER'), SQLITE3_TEXT);
$stmt->bindValue(':openvpn_version', envv('IV_VER'), SQLITE3_TEXT);
$stmt->bindValue(':gui_version', envv('IV_GUI_VER'), SQLITE3_TEXT);
$stmt->bindValue(':ssl_library', envv('IV_SSL'), SQLITE3_TEXT);
$stmt->bindValue(':hwaddr', envv('IV_HWADDR'), SQLITE3_TEXT);
$stmt->bindValue(':trusted_ip', envv('trusted_ip'), SQLITE3_TEXT);
$stmt->bindValue(':trusted_port', envv('trusted_port'), SQLITE3_TEXT);
$stmt->bindValue(':untrusted_ip', envv('untrusted_ip'), SQLITE3_TEXT);
$stmt->bindValue(':untrusted_port', envv('untrusted_port'), SQLITE3_TEXT);
$stmt->bindValue(':source_instance', envv('daemon_pid'), SQLITE3_TEXT);
$stmt->bindValue(':raw_peer_info', json_encode($peerInfo, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE), SQLITE3_TEXT);
$stmt->bindValue(':app_hint', $appHint, SQLITE3_TEXT);
$stmt->execute();
PHP

cat >/usr/local/bin/ovpn-log-event.sh <<'EOF'
#!/usr/bin/env bash
exec php /usr/local/bin/ovpn-log-event.php
EOF
chmod +x /usr/local/bin/ovpn-log-event.sh

cat >/usr/local/bin/ovpn-make-profile.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
USER_NAME="${1:?username required}"
SERVER_ADDR="${2:?server ip or hostname required}"
OUT_DIR="/var/www/html/ovpn-admin/downloads"
PKI_DIR="/etc/openvpn/pki-webadmin"
mkdir -p "$OUT_DIR"
cat >"${OUT_DIR}/${USER_NAME}.ovpn" <<PROFILE
client
dev tun
nobind
persist-key
persist-tun
auth-user-pass
auth-nocache
remote ${SERVER_ADDR} 1194 udp
remote ${SERVER_ADDR} 443 tcp
remote-random
resolv-retry infinite
connect-retry 3 10
proto udp
remote-cert-tls server
data-ciphers AES-256-GCM:AES-128-GCM
auth SHA256
verb 3
pull
setenv UV_APP_PACKAGE unknown
setenv UV_APP_NAME unknown
setenv UV_PROFILE_USER ${USER_NAME}
push-peer-info
<ca>
$(cat ${PKI_DIR}/ca.crt)
</ca>
<tls-crypt>
$(cat ${PKI_DIR}/ta.key)
</tls-crypt>
PROFILE
chmod 644 "${OUT_DIR}/${USER_NAME}.ovpn"
EOF
chmod +x /usr/local/bin/ovpn-make-profile.sh

cat >/usr/local/bin/ovpn-user-manage.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
DB="/var/www/html/ovpn-admin/data/ovpn.sqlite"
SERVER_ADDR="${SERVER_ADDR_OVERRIDE:-$(curl -4 -fsSL https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')}"
cmd="${1:-}"
case "$cmd" in
  add)
    user="${2:?username}"
    pass="${3:?password}"
    hash="$(php -r "echo password_hash('$pass', PASSWORD_DEFAULT);")"
    sqlite3 "$DB" "INSERT INTO users(username,password_hash) VALUES('${user//\'/\'\'}','${hash//\'/\'\'}');"
    /usr/local/bin/ovpn-make-profile.sh "$user" "$SERVER_ADDR"
    echo "User added: $user"
    ;;
  update)
    user="${2:?username}"
    pass="${3:?password}"
    hash="$(php -r "echo password_hash('$pass', PASSWORD_DEFAULT);")"
    sqlite3 "$DB" "UPDATE users SET password_hash='${hash//\'/\'\'}', updated_at=CURRENT_TIMESTAMP WHERE username='${user//\'/\'\'}';"
    /usr/local/bin/ovpn-make-profile.sh "$user" "$SERVER_ADDR"
    echo "User updated: $user"
    ;;
  delete)
    user="${2:?username}"
    sqlite3 "$DB" "DELETE FROM users WHERE username='${user//\'/\'\'}';"
    rm -f "/var/www/html/ovpn-admin/downloads/${user}.ovpn"
    echo "User deleted: $user"
    ;;
  regen)
    user="${2:?username}"
    /usr/local/bin/ovpn-make-profile.sh "$user" "$SERVER_ADDR"
    echo "Profile regenerated: $user"
    ;;
  *)
    echo "Usage: $0 {add|update|delete|regen} username [password]"
    exit 1
    ;;
esac
EOF
chmod +x /usr/local/bin/ovpn-user-manage.sh

/usr/local/bin/ovpn-make-profile.sh "$DEFAULT_USER" "$SERVER_IP"

echo "[8/10] Writing OpenVPN configs..."
cat >/etc/openvpn/server/server-udp.conf <<'EOF'
port 1194
proto udp
dev tun
user nobody
group nogroup
persist-key
persist-tun
topology subnet
server 10.8.0.0 255.255.255.0
ifconfig-pool-persist /var/log/openvpn/ipp-udp.txt
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS 8.8.8.8"
keepalive 10 120
data-ciphers AES-256-GCM:AES-128-GCM
auth SHA256
ca /etc/openvpn/pki-webadmin/ca.crt
cert /etc/openvpn/pki-webadmin/server.crt
key /etc/openvpn/pki-webadmin/server.key
dh /etc/openvpn/pki-webadmin/dh.pem
tls-crypt /etc/openvpn/pki-webadmin/ta.key
verify-client-cert none
username-as-common-name
auth-user-pass-verify /usr/local/bin/ovpn-auth.sh via-env
duplicate-cn
client-to-client
status /var/log/openvpn/openvpn-status-udp.log 10
status-version 3
log-append /var/log/openvpn/server-udp.log
verb 4
script-security 2
client-connect /usr/local/bin/ovpn-log-event.sh
client-disconnect /usr/local/bin/ovpn-log-event.sh
explicit-exit-notify 1
EOF

cat >/etc/openvpn/server/server-tcp.conf <<'EOF'
port 443
proto tcp
dev tun
user nobody
group nogroup
persist-key
persist-tun
topology subnet
server 10.9.0.0 255.255.255.0
ifconfig-pool-persist /var/log/openvpn/ipp-tcp.txt
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS 8.8.8.8"
keepalive 10 120
data-ciphers AES-256-GCM:AES-128-GCM
auth SHA256
ca /etc/openvpn/pki-webadmin/ca.crt
cert /etc/openvpn/pki-webadmin/server.crt
key /etc/openvpn/pki-webadmin/server.key
dh /etc/openvpn/pki-webadmin/dh.pem
tls-crypt /etc/openvpn/pki-webadmin/ta.key
verify-client-cert none
username-as-common-name
auth-user-pass-verify /usr/local/bin/ovpn-auth.sh via-env
duplicate-cn
client-to-client
status /var/log/openvpn/openvpn-status-tcp.log 10
status-version 3
log-append /var/log/openvpn/server-tcp.log
verb 4
script-security 2
client-connect /usr/local/bin/ovpn-log-event.sh
client-disconnect /usr/local/bin/ovpn-log-event.sh
EOF

echo "[9/10] Writing admin panel..."
cat >"$APP_DIR/config.php" <<'PHP'
<?php
session_start();
date_default_timezone_set('UTC');
define('DB_PATH', __DIR__ . '/data/ovpn.sqlite');
define('DOWNLOAD_DIR', __DIR__ . '/downloads');

function db() {
    static $db = null;
    if ($db === null) {
        $db = new SQLite3(DB_PATH);
        $db->busyTimeout(5000);
    }
    return $db;
}
function esc($v){ return htmlspecialchars((string)$v, ENT_QUOTES, 'UTF-8'); }
function require_login() {
    if (empty($_SESSION['admin_user'])) {
        header('Location: login.php');
        exit;
    }
}
function admin_login($u, $p) {
    $stmt = db()->prepare('SELECT username, password_hash FROM admins WHERE username=:u LIMIT 1');
    $stmt->bindValue(':u', $u, SQLITE3_TEXT);
    $res = $stmt->execute();
    $row = $res ? $res->fetchArray(SQLITE3_ASSOC) : false;
    return $row && password_verify($p, $row['password_hash']);
}
function users_all() {
    $res = db()->query('SELECT id, username, created_at, updated_at FROM users ORDER BY id DESC');
    $rows = [];
    while ($row = $res->fetchArray(SQLITE3_ASSOC)) { $rows[] = $row; }
    return $rows;
}
function user_get($id) {
    $stmt = db()->prepare('SELECT id, username, created_at, updated_at FROM users WHERE id=:id LIMIT 1');
    $stmt->bindValue(':id', (int)$id, SQLITE3_INTEGER);
    $res = $stmt->execute();
    return $res ? $res->fetchArray(SQLITE3_ASSOC) : false;
}
function latest_logs($limit = 200, $search = '') {
    if ($search !== '') {
        $stmt = db()->prepare('SELECT * FROM connection_events WHERE username LIKE :s OR common_name LIKE :s OR real_ip LIKE :s OR app_hint LIKE :s OR gui_version LIKE :s ORDER BY id DESC LIMIT :lim');
        $stmt->bindValue(':s', '%' . $search . '%', SQLITE3_TEXT);
        $stmt->bindValue(':lim', (int)$limit, SQLITE3_INTEGER);
        $res = $stmt->execute();
    } else {
        $stmt = db()->prepare('SELECT * FROM connection_events ORDER BY id DESC LIMIT :lim');
        $stmt->bindValue(':lim', (int)$limit, SQLITE3_INTEGER);
        $res = $stmt->execute();
    }
    $rows = [];
    while ($row = $res->fetchArray(SQLITE3_ASSOC)) { $rows[] = $row; }
    return $rows;
}
function dashboard_stats() {
    $stats = [
        'total_users' => (int)db()->querySingle('SELECT COUNT(*) FROM users'),
        'total_events' => (int)db()->querySingle('SELECT COUNT(*) FROM connection_events'),
        'today_connects' => (int)db()->querySingle("SELECT COUNT(*) FROM connection_events WHERE event_type='connect' AND date(event_time)=date('now')"),
        'gui_rows' => (int)db()->querySingle("SELECT COUNT(*) FROM connection_events WHERE COALESCE(gui_version,'') <> ''")
    ];
    return $stats;
}
function active_clients() {
    $files = ['/var/log/openvpn/openvpn-status-udp.log','/var/log/openvpn/openvpn-status-tcp.log'];
    $clients = [];
    foreach ($files as $file) {
        if (!is_file($file)) continue;
        $lines = @file($file, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
        if (!$lines) continue;
        foreach ($lines as $line) {
            $parts = explode("\t", $line);
            if (count($parts) >= 11 && $parts[0] === 'CLIENT_LIST') {
                $clients[] = [
                    'common_name' => $parts[1] ?? '',
                    'real_address' => $parts[2] ?? '',
                    'bytes_received' => $parts[3] ?? '',
                    'bytes_sent' => $parts[4] ?? '',
                    'connected_since' => $parts[5] ?? '',
                    'virtual_address' => $parts[6] ?? '',
                    'username' => $parts[8] ?? '',
                    'client_id' => $parts[9] ?? '',
                    'peer_id' => $parts[10] ?? '',
                    'cipher' => $parts[11] ?? '',
                    'source' => basename($file),
                ];
            }
        }
    }
    return $clients;
}
function profile_path($username) {
    return DOWNLOAD_DIR . '/' . $username . '.ovpn';
}
function cli($cmd) {
    exec($cmd . ' 2>&1', $out, $code);
    return [$code, implode("\n", $out)];
}
function pretty_json($json) {
    if (!$json) return '';
    $arr = json_decode($json, true);
    if (!is_array($arr)) return (string)$json;
    return json_encode($arr, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
}
PHP

cat >"$APP_DIR/style.css" <<'CSS'
:root{
  --bg:#08111f;
  --bg2:#0d1729;
  --card:#111c31;
  --card2:#17253d;
  --muted:#9eb0d0;
  --text:#eef4ff;
  --accent:#4f8cff;
  --accent2:#19d1a2;
  --danger:#ff5f78;
  --line:#243653;
  --warn:#ffb54a;
}
*{box-sizing:border-box}
html,body{margin:0;padding:0}
body{font-family:Inter,Segoe UI,Arial,sans-serif;background:linear-gradient(180deg,var(--bg),var(--bg2));color:var(--text)}
a{text-decoration:none;color:inherit}
.wrap{display:grid;grid-template-columns:270px 1fr;min-height:100vh}
.sidebar{background:rgba(7,12,22,.95);border-right:1px solid var(--line);padding:18px;position:sticky;top:0;height:100vh}
.brand{font-size:23px;font-weight:900;letter-spacing:.4px;margin-bottom:8px}
.brand-sub{color:var(--muted);font-size:13px;margin-bottom:18px}
.nav a{display:flex;align-items:center;gap:10px;padding:13px 14px;border:1px solid var(--line);border-radius:16px;margin-bottom:10px;background:#101a2b}
.nav a:hover{background:#15243e}
.main{padding:22px}
.topbar{display:flex;justify-content:space-between;gap:12px;align-items:center;margin-bottom:18px;flex-wrap:wrap}
.title{font-size:28px;font-weight:900}
.muted{color:var(--muted)}
.grid{display:grid;grid-template-columns:repeat(4,1fr);gap:16px}
.card{background:linear-gradient(180deg,rgba(18,28,48,.98),rgba(15,24,41,.96));border:1px solid var(--line);border-radius:22px;padding:18px;box-shadow:0 12px 30px rgba(0,0,0,.18)}
.card h3{margin:0 0 10px}
.metric{font-size:36px;font-weight:900}
.row{display:grid;grid-template-columns:1fr 1fr;gap:16px}
.kv{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:12px}
.kv .cell{background:#0f1829;border:1px solid var(--line);border-radius:16px;padding:14px}
table{width:100%;border-collapse:collapse;min-width:920px}
th,td{padding:12px 10px;border-bottom:1px solid var(--line);text-align:left;vertical-align:top}
th{color:#b7c7e6;font-size:12px;text-transform:uppercase;letter-spacing:.5px}
.badge{display:inline-block;padding:6px 10px;border-radius:999px;background:#17345e;border:1px solid #2d5a9c;font-size:12px}
.badge.green{background:#10382d;border-color:#1a6f5a}
.badge.warn{background:#3b2b10;border-color:#90641a}
.btn{display:inline-flex;align-items:center;justify-content:center;gap:8px;background:linear-gradient(135deg,var(--accent),#6da2ff);color:white;padding:10px 14px;border:none;border-radius:14px;cursor:pointer;font-weight:800}
.btn.secondary{background:#17253d}
.btn.green{background:linear-gradient(135deg,#0fb88e,var(--accent2))}
.btn.red{background:linear-gradient(135deg,#d93b55,var(--danger))}
.btn.warn{background:linear-gradient(135deg,#bf7e12,var(--warn)); color:#111}
input,textarea{width:100%;padding:12px 14px;border-radius:14px;border:1px solid var(--line);background:#0d1626;color:var(--text)}
textarea{min-height:300px;white-space:pre;font-family:ui-monospace,Consolas,monospace}
.flash{padding:12px 14px;border-radius:14px;margin-bottom:14px}
.flash.ok{background:#12382f;border:1px solid #1d6b58}
.flash.err{background:#3a1820;border:1px solid #6e2c3a}
.small{font-size:12px}
.panel-actions{display:flex;gap:10px;flex-wrap:wrap}
.table-wrap{overflow:auto}
pre{white-space:pre-wrap;word-break:break-word;background:#0e1626;border:1px solid var(--line);border-radius:16px;padding:14px;max-height:340px;overflow:auto}
.searchbar{display:flex;gap:10px;flex-wrap:wrap}
.login-shell{min-height:100vh;display:grid;place-items:center;padding:20px}
.login-card{max-width:440px;width:100%;background:rgba(18,27,45,.98);border:1px solid var(--line);border-radius:26px;padding:28px}
.note{background:#101a2b;border:1px solid var(--line);padding:12px 14px;border-radius:14px}
@media (max-width: 1100px){
  .wrap{grid-template-columns:1fr}
  .sidebar{position:static;height:auto}
  .grid{grid-template-columns:1fr 1fr}
  .row,.kv{grid-template-columns:1fr}
}
@media (max-width: 680px){
  .grid{grid-template-columns:1fr}
  .title{font-size:22px}
  .main{padding:14px}
  th,td{font-size:12px;padding:9px 6px}
}
CSS

cat >"$APP_DIR/login.php" <<'PHP'
<?php require __DIR__ . '/config.php';
$error = '';
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $u = trim($_POST['username'] ?? '');
    $p = (string)($_POST['password'] ?? '');
    if (admin_login($u, $p)) {
        $_SESSION['admin_user'] = $u;
        header('Location: index.php');
        exit;
    }
    $error = 'Invalid login';
}
?>
<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>OpenVPN Admin Login</title><link rel="stylesheet" href="style.css"></head>
<body>
<div class="login-shell">
  <div class="login-card">
    <div class="brand">OpenVPN Admin Pro</div>
    <div class="brand-sub">Modern panel with peer-info capture, logs and copyable profiles.</div>
    <?php if ($error): ?><div class="flash err"><?=esc($error)?></div><?php endif; ?>
    <form method="post">
      <label>Admin Username</label>
      <input name="username" value="openvpn" required>
      <div style="height:12px"></div>
      <label>Password</label>
      <input type="password" name="password" required>
      <div style="height:16px"></div>
      <button class="btn" type="submit">Login</button>
    </form>
    <div style="height:16px"></div>
    <div class="small muted">Installer default login is generated automatically. Change it after first login.</div>
  </div>
</div>
</body></html>
PHP

cat >"$APP_DIR/logout.php" <<'PHP'
<?php require __DIR__ . '/config.php'; session_destroy(); header('Location: login.php');
PHP

cat >"$APP_DIR/_layout_top.php" <<'PHP'
<?php require_once __DIR__ . '/config.php'; require_login(); ?>
<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>OpenVPN Admin Pro</title><link rel="stylesheet" href="style.css"></head><body>
<div class="wrap">
<aside class="sidebar">
  <div class="brand">OpenVPN Admin Pro</div>
  <div class="brand-sub">Logged in as <?=esc($_SESSION['admin_user'])?></div>
  <nav class="nav">
    <a href="index.php">Dashboard</a>
    <a href="users.php">Users</a>
    <a href="add_user.php">New User</a>
    <a href="logs.php">Connection Logs</a>
    <a href="change_password.php">Change Admin Password</a>
    <a href="logout.php">Logout</a>
  </nav>
</aside>
<main class="main">
PHP

cat >"$APP_DIR/_layout_bottom.php" <<'PHP'
</main></div></body></html>
PHP

cat >"$APP_DIR/index.php" <<'PHP'
<?php require __DIR__ . '/_layout_top.php';
$clients = active_clients();
$users = users_all();
$logs = latest_logs(8);
$stats = dashboard_stats();
?>
<div class="topbar">
  <div class="title">Dashboard</div>
  <div class="panel-actions">
    <a class="btn secondary" href="users.php">Manage Users</a>
    <a class="btn secondary" href="logs.php">Open Logs</a>
  </div>
</div>

<div class="grid">
  <div class="card"><h3>Active Connected</h3><div class="metric"><?=count($clients)?></div><div class="muted">Live sessions from OpenVPN status logs</div></div>
  <div class="card"><h3>Total Users</h3><div class="metric"><?=$stats['total_users']?></div><div class="muted">Saved in panel database</div></div>
  <div class="card"><h3>Today Connects</h3><div class="metric"><?=$stats['today_connects']?></div><div class="muted">Connect events recorded today</div></div>
  <div class="card"><h3>GUI Info Rows</h3><div class="metric"><?=$stats['gui_rows']?></div><div class="muted">Rows where peer-info exposed GUI/App hint</div></div>
</div>

<div style="height:18px"></div>
<div class="row">
  <div class="card">
    <h3>Live Sessions</h3>
    <div class="table-wrap">
      <table>
        <thead><tr><th>User</th><th>Real Address</th><th>Virtual IP</th><th>Connected Since</th><th>Cipher</th><th>Source</th></tr></thead>
        <tbody>
        <?php foreach ($clients as $c): ?>
          <tr>
            <td><?=esc($c['username'] ?: $c['common_name'])?></td>
            <td><?=esc($c['real_address'])?></td>
            <td><?=esc($c['virtual_address'])?></td>
            <td><?=esc($c['connected_since'])?></td>
            <td><?=esc($c['cipher'])?></td>
            <td><span class="badge"><?=esc($c['source'])?></span></td>
          </tr>
        <?php endforeach; if (!$clients): ?>
          <tr><td colspan="6" class="muted">No active clients right now.</td></tr>
        <?php endif; ?>
        </tbody>
      </table>
    </div>
  </div>

  <div class="card">
    <h3>Latest Peer Info</h3>
    <?php foreach ($logs as $r): ?>
      <div class="note" style="margin-bottom:12px">
        <div><strong><?=esc($r['username'] ?: $r['common_name'])?></strong> <span class="badge <?= $r['event_type']==='connect' ? 'green' : 'warn' ?>"><?=esc($r['event_type'])?></span></div>
        <div class="small muted" style="margin-top:6px"><?=esc($r['event_time'])?> · <?=esc($r['real_ip'])?></div>
        <div style="margin-top:8px">GUI/App: <strong><?=esc($r['app_hint'] ?: 'Not sent by client')?></strong></div>
        <div class="small muted">Platform: <?=esc(trim(($r['platform'] ?? '') . ' ' . ($r['platform_version'] ?? '')))?> · OpenVPN: <?=esc($r['openvpn_version'])?></div>
      </div>
    <?php endforeach; if (!$logs): ?>
      <div class="muted">No recent log rows.</div>
    <?php endif; ?>
  </div>
</div>
<?php require __DIR__ . '/_layout_bottom.php'; ?>
PHP

cat >"$APP_DIR/users.php" <<'PHP'
<?php require __DIR__ . '/_layout_top.php'; $users = users_all(); ?>
<div class="topbar"><div class="title">Users</div><a class="btn green" href="add_user.php">+ Add New User</a></div>
<div class="card">
  <div class="table-wrap">
    <table>
      <thead><tr><th>ID</th><th>Username</th><th>Created</th><th>Updated</th><th>Download</th><th>Show Config</th><th>Actions</th></tr></thead>
      <tbody>
      <?php foreach ($users as $u): ?>
      <tr>
        <td><?=esc($u['id'])?></td>
        <td><?=esc($u['username'])?></td>
        <td><?=esc($u['created_at'])?></td>
        <td><?=esc($u['updated_at'])?></td>
        <td><a class="btn secondary" href="download.php?u=<?=urlencode($u['username'])?>">Download</a></td>
        <td><a class="btn secondary" href="show_config.php?u=<?=urlencode($u['username'])?>">Show Config</a></td>
        <td>
          <div class="panel-actions">
            <a class="btn secondary" href="edit_user.php?id=<?=$u['id']?>">Edit</a>
            <a class="btn red" href="delete_user.php?id=<?=$u['id']?>" onclick="return confirm('Delete this user?')">Delete</a>
          </div>
        </td>
      </tr>
      <?php endforeach; if (!$users): ?>
      <tr><td colspan="7" class="muted">No users yet.</td></tr>
      <?php endif; ?>
      </tbody>
    </table>
  </div>
</div>
<?php require __DIR__ . '/_layout_bottom.php'; ?>
PHP

cat >"$APP_DIR/add_user.php" <<'PHP'
<?php require __DIR__ . '/_layout_top.php';
$msg=''; $err='';
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $u = trim($_POST['username'] ?? '');
    $p = (string)($_POST['password'] ?? '');
    if ($u === '' || $p === '') { $err = 'Username and password required'; }
    else {
        [$code,$out] = cli('/usr/local/bin/ovpn-user-manage.sh add ' . escapeshellarg($u) . ' ' . escapeshellarg($p));
        if ($code === 0) $msg = $out; else $err = $out;
    }
}
?>
<div class="topbar"><div class="title">Add New User</div><a class="btn secondary" href="users.php">Back to Users</a></div>
<div class="card" style="max-width:760px">
<?php if($msg): ?><div class="flash ok"><?=esc($msg)?></div><?php endif; ?>
<?php if($err): ?><div class="flash err"><?=esc($err)?></div><?php endif; ?>
<form method="post">
<label>Username</label><input name="username" required>
<div style="height:12px"></div>
<label>Password</label><input name="password" required>
<div style="height:16px"></div>
<button class="btn green" type="submit">Create User + Generate OVPN</button>
</form>
</div>
<?php require __DIR__ . '/_layout_bottom.php'; ?>
PHP

cat >"$APP_DIR/edit_user.php" <<'PHP'
<?php require __DIR__ . '/_layout_top.php';
$id = (int)($_GET['id'] ?? 0);
$user = user_get($id);
if (!$user) { echo '<div class="card">User not found.</div>'; require __DIR__ . '/_layout_bottom.php'; exit; }
$msg=''; $err='';
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $p = (string)($_POST['password'] ?? '');
    if ($p === '') $err = 'New password required';
    else {
        [$code,$out] = cli('/usr/local/bin/ovpn-user-manage.sh update ' . escapeshellarg($user['username']) . ' ' . escapeshellarg($p));
        if ($code === 0) $msg = $out; else $err = $out;
    }
}
?>
<div class="topbar"><div class="title">Edit User</div><a class="btn secondary" href="users.php">Back to Users</a></div>
<div class="card" style="max-width:760px">
<?php if($msg): ?><div class="flash ok"><?=esc($msg)?></div><?php endif; ?>
<?php if($err): ?><div class="flash err"><?=esc($err)?></div><?php endif; ?>
<div class="muted">Username: <strong><?=esc($user['username'])?></strong></div>
<div style="height:12px"></div>
<form method="post">
<label>New Password</label><input name="password" required>
<div style="height:16px"></div>
<button class="btn green" type="submit">Update Password + Regenerate OVPN</button>
</form>
</div>
<?php require __DIR__ . '/_layout_bottom.php'; ?>
PHP

cat >"$APP_DIR/delete_user.php" <<'PHP'
<?php require __DIR__ . '/config.php'; require_login();
$id = (int)($_GET['id'] ?? 0);
$user = user_get($id);
if ($user) { cli('/usr/local/bin/ovpn-user-manage.sh delete ' . escapeshellarg($user['username'])); }
header('Location: users.php');
PHP

cat >"$APP_DIR/download.php" <<'PHP'
<?php require __DIR__ . '/config.php'; require_login();
$u = preg_replace('/[^A-Za-z0-9_.@-]/', '', $_GET['u'] ?? '');
$file = profile_path($u);
if (!$u || !is_file($file)) { http_response_code(404); exit('Profile not found'); }
header('Content-Type: application/octet-stream');
header('Content-Disposition: attachment; filename="' . basename($file) . '"');
header('Content-Length: ' . filesize($file));
readfile($file);
PHP

cat >"$APP_DIR/show_config.php" <<'PHP'
<?php require __DIR__ . '/_layout_top.php';
$u = preg_replace('/[^A-Za-z0-9_.@-]/', '', $_GET['u'] ?? '');
$file = profile_path($u);
$content = is_file($file) ? file_get_contents($file) : '';
?>
<div class="topbar"><div class="title">Show Config</div><a class="btn secondary" href="users.php">Back to Users</a></div>
<div class="card">
  <div class="panel-actions" style="justify-content:space-between;margin-bottom:12px">
    <div><strong><?=esc($u)?></strong> <span class="muted">Copyable .ovpn content</span></div>
    <a class="btn secondary" href="download.php?u=<?=urlencode($u)?>">Download</a>
  </div>
  <textarea readonly onclick="this.select()"><?=esc($content)?></textarea>
</div>
<?php require __DIR__ . '/_layout_bottom.php'; ?>
PHP

cat >"$APP_DIR/logs.php" <<'PHP'
<?php require __DIR__ . '/_layout_top.php';
$q = trim($_GET['q'] ?? '');
$rows = latest_logs(300, $q);
if (isset($_GET['export']) && $_GET['export'] === 'csv') {
    header('Content-Type: text/csv');
    header('Content-Disposition: attachment; filename="ovpn-logs.csv"');
    $fp = fopen('php://output', 'w');
    fputcsv($fp, ['time','event','user','real_ip','virtual_ip','platform','platform_version','openvpn_version','gui_version','app_hint']);
    foreach ($rows as $r) {
        fputcsv($fp, [$r['event_time'],$r['event_type'],$r['username'] ?: $r['common_name'],$r['real_ip'],$r['virtual_ip'],$r['platform'],$r['platform_version'],$r['openvpn_version'],$r['gui_version'],$r['app_hint']]);
    }
    fclose($fp);
    exit;
}
?>
<div class="topbar">
  <div class="title">Connection Logs</div>
  <div class="panel-actions">
    <a class="btn secondary" href="index.php">Dashboard</a>
    <a class="btn secondary" href="logs.php?export=csv<?= $q !== '' ? '&q=' . urlencode($q) : '' ?>">Export CSV</a>
  </div>
</div>

<div class="card" style="margin-bottom:18px">
  <div class="searchbar">
    <form method="get" style="display:flex;gap:10px;flex-wrap:wrap;width:100%">
      <input name="q" value="<?=esc($q)?>" placeholder="Search by user, IP, GUI/App hint">
      <button class="btn" type="submit">Search</button>
      <a class="btn secondary" href="logs.php">Reset</a>
    </form>
  </div>
  <div style="height:12px"></div>
  <div class="note">
    This panel stores as much peer-info as the client sends. Best-case fields are GUI/App hint, platform, platform version, OpenVPN version, SSL library and any UV_* values the client exposes.
  </div>
</div>

<div class="card">
  <div class="table-wrap">
    <table>
      <thead><tr><th>Time</th><th>Event</th><th>User</th><th>Real IP</th><th>Virtual IP</th><th>GUI/App Hint</th><th>Platform</th><th>OpenVPN</th><th>Raw Peer Info</th></tr></thead>
      <tbody>
      <?php foreach ($rows as $r): ?>
      <tr>
        <td><?=esc($r['event_time'])?></td>
        <td><span class="badge <?= $r['event_type']==='connect' ? 'green' : 'warn' ?>"><?=esc($r['event_type'])?></span></td>
        <td><?=esc($r['username'] ?: $r['common_name'])?></td>
        <td><?=esc($r['real_ip'])?></td>
        <td><?=esc($r['virtual_ip'])?></td>
        <td><?=esc($r['app_hint'] ?: $r['gui_version'] ?: 'Not sent')?></td>
        <td><?=esc(trim(($r['platform'] ?? '') . ' ' . ($r['platform_version'] ?? '')))?></td>
        <td><?=esc($r['openvpn_version'])?></td>
        <td><pre><?=esc(pretty_json($r['raw_peer_info']))?></pre></td>
      </tr>
      <?php endforeach; if(!$rows): ?>
      <tr><td colspan="9" class="muted">No log rows yet.</td></tr>
      <?php endif; ?>
      </tbody>
    </table>
  </div>
</div>
<?php require __DIR__ . '/_layout_bottom.php'; ?>
PHP

cat >"$APP_DIR/change_password.php" <<'PHP'
<?php require __DIR__ . '/_layout_top.php';
$msg=''; $err='';
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $current = (string)($_POST['current_password'] ?? '');
    $new = (string)($_POST['new_password'] ?? '');
    if (!admin_login($_SESSION['admin_user'], $current)) {
        $err = 'Current password is incorrect';
    } elseif ($new === '') {
        $err = 'New password required';
    } else {
        $hash = password_hash($new, PASSWORD_DEFAULT);
        $stmt = db()->prepare('UPDATE admins SET password_hash=:p WHERE username=:u');
        $stmt->bindValue(':p', $hash, SQLITE3_TEXT);
        $stmt->bindValue(':u', $_SESSION['admin_user'], SQLITE3_TEXT);
        $stmt->execute();
        $msg = 'Admin password changed successfully';
    }
}
?>
<div class="topbar"><div class="title">Change Admin Password</div><a class="btn secondary" href="index.php">Dashboard</a></div>
<div class="card" style="max-width:760px">
<?php if($msg): ?><div class="flash ok"><?=esc($msg)?></div><?php endif; ?>
<?php if($err): ?><div class="flash err"><?=esc($err)?></div><?php endif; ?>
<form method="post">
<label>Current Password</label><input type="password" name="current_password" required>
<div style="height:12px"></div>
<label>New Password</label><input type="password" name="new_password" required>
<div style="height:16px"></div>
<button class="btn green" type="submit">Update Password</button>
</form>
</div>
<?php require __DIR__ . '/_layout_bottom.php'; ?>
PHP

chown -R www-data:www-data "$APP_DIR"
chmod -R 755 "$APP_DIR"
chmod 775 "$DATA_DIR" "$DOWNLOAD_DIR"
chown root:www-data "$DB_FILE"
chmod 664 "$DB_FILE"

a2enmod php* >/dev/null 2>&1 || true
systemctl enable apache2
systemctl restart apache2

echo "[10/10] Enabling services..."
systemctl daemon-reload
systemctl enable ovpn-iptables.service
systemctl start ovpn-iptables.service
systemctl enable openvpn-server@server-udp.service
systemctl enable openvpn-server@server-tcp.service
systemctl restart openvpn-server@server-udp.service
systemctl restart openvpn-server@server-tcp.service

echo
echo "==============================================="
echo "OpenVPN Admin Pro installation finished"
echo "Panel URL: http://${SERVER_IP}/ovpn-admin/"
echo "Admin user: ${ADMIN_USER}"
echo "Admin pass: ${ADMIN_PASS}"
echo "Default VPN user: ${DEFAULT_USER}"
echo "Default VPN pass: ${DEFAULT_USER_PASS}"
echo "Default OVPN file: ${DOWNLOAD_DIR}/${DEFAULT_USER}.ovpn"
echo
echo "CLI manage user:"
echo "  /usr/local/bin/ovpn-user-manage.sh add USER PASS"
echo "  /usr/local/bin/ovpn-user-manage.sh update USER PASS"
echo "  /usr/local/bin/ovpn-user-manage.sh delete USER"
echo
echo "Peer-info note:"
echo "  GUI/App hint is only shown when the client actually sends IV_GUI_VER or UV_* fields."
echo "==============================================="
