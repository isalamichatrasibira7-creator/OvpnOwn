#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run as root"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

APP_DIR="/var/www/html/ovpn-admin"
DATA_DIR="$APP_DIR/data"
DOWNLOAD_DIR="$APP_DIR/downloads"
DB_FILE="$DATA_DIR/ovpn.sqlite"
PKI_DIR="/etc/openvpn/pki-webadmin"
OVPN_DIR="/etc/openvpn/server"
LOG_DIR="/var/log/openvpn"
ADMIN_USER="openvpn"
ADMIN_PASS="Easin112233@"
DEFAULT_USER="Easin"
DEFAULT_USER_PASS="Easin112233@"
UDP_PORT="1194"
TCP_PORT="443"

get_public_ip() {
  local ip=""
  for url in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me; do
    ip="$(curl -4 -fsSL "$url" 2>/dev/null | tr -d '\r\n' || true)"
    [[ -n "$ip" ]] && break
  done
  [[ -n "$ip" ]] || ip="$(hostname -I | awk '{print $1}')"
  echo "$ip"
}

SERVER_ADDR="$(get_public_ip)"
[[ -n "$SERVER_ADDR" ]] || { echo "Could not detect server IP"; exit 1; }
NET_IFACE="$(ip route get 1.1.1.1 | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
: "${NET_IFACE:=eth0}"

echo "[1/11] Installing packages..."
apt-get update
apt-get install -y openvpn easy-rsa apache2 php libapache2-mod-php php-sqlite3 php-cli sqlite3 curl openssl ca-certificates

echo "[2/11] Creating directories..."
mkdir -p "$APP_DIR" "$DATA_DIR" "$DOWNLOAD_DIR" "$PKI_DIR" "$OVPN_DIR" "$LOG_DIR" /usr/local/bin

echo "[3/11] Enabling IP forwarding..."
cat >/etc/sysctl.d/99-openvpn-forward.conf <<SYSCTL
net.ipv4.ip_forward=1
SYSCTL
sysctl --system >/dev/null

echo "[4/11] Configuring NAT + firewall rules..."
cat >/usr/local/bin/ovpn-iptables-apply.sh <<RULES
#!/usr/bin/env bash
set -e
iptables -t nat -C POSTROUTING -s 10.8.0.0/24 -o ${NET_IFACE} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o ${NET_IFACE} -j MASQUERADE
iptables -t nat -C POSTROUTING -s 10.9.0.0/24 -o ${NET_IFACE} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s 10.9.0.0/24 -o ${NET_IFACE} -j MASQUERADE
iptables -C INPUT -p udp --dport ${UDP_PORT} -j ACCEPT 2>/dev/null || iptables -A INPUT -p udp --dport ${UDP_PORT} -j ACCEPT
iptables -C INPUT -p tcp --dport ${TCP_PORT} -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport ${TCP_PORT} -j ACCEPT
iptables -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport 80 -j ACCEPT
RULES
chmod +x /usr/local/bin/ovpn-iptables-apply.sh
/usr/local/bin/ovpn-iptables-apply.sh || true

cat >/etc/systemd/system/ovpn-iptables.service <<'UNIT'
[Unit]
Description=Apply iptables rules for OpenVPN Admin
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ovpn-iptables-apply.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

echo "[5/11] Generating PKI..."
rm -rf /root/easy-rsa
make-cadir /root/easy-rsa
cd /root/easy-rsa
./easyrsa init-pki
EASYRSA_BATCH=1 ./easyrsa build-ca nopass <<<'\n'
EASYRSA_BATCH=1 ./easyrsa build-server-full server nopass
./easyrsa gen-dh
openvpn --genkey secret pki/ta.key
cp pki/ca.crt "$PKI_DIR/ca.crt"
cp pki/issued/server.crt "$PKI_DIR/server.crt"
cp pki/private/server.key "$PKI_DIR/server.key"
cp pki/dh.pem "$PKI_DIR/dh.pem"
cp pki/ta.key "$PKI_DIR/ta.key"
chmod 600 "$PKI_DIR/server.key" "$PKI_DIR/ta.key"
chmod 644 "$PKI_DIR/ca.crt" "$PKI_DIR/server.crt" "$PKI_DIR/dh.pem"

echo "[6/11] Creating database..."
sqlite3 "$DB_FILE" <<'SQL'
PRAGMA journal_mode=DELETE;
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
  raw_peer_info TEXT,
  app_hint TEXT
);
SQL

ADMIN_HASH="$(php -r "echo password_hash('${ADMIN_PASS}', PASSWORD_DEFAULT);")"
USER_HASH="$(php -r "echo password_hash('${DEFAULT_USER_PASS}', PASSWORD_DEFAULT);")"
sqlite3 "$DB_FILE" "INSERT OR REPLACE INTO admins(username,password_hash) VALUES('openvpn','$ADMIN_HASH');"
sqlite3 "$DB_FILE" "INSERT OR REPLACE INTO users(username,password_hash) VALUES('$DEFAULT_USER','$USER_HASH');"
chmod 666 "$DB_FILE"

cat >/usr/local/bin/ovpn-auth.php <<'PHP'
#!/usr/bin/env php
<?php
$db = new SQLite3('/var/www/html/ovpn-admin/data/ovpn.sqlite');
$db->busyTimeout(5000);
$user = '';
$pass = '';
if ($argc >= 2 && is_file($argv[1])) {
    $lines = @file($argv[1], FILE_IGNORE_NEW_LINES);
    if (isset($lines[0])) $user = trim($lines[0]);
    if (isset($lines[1])) $pass = trim($lines[1]);
} else {
    $user = getenv('username') ?: '';
    $pass = getenv('password') ?: '';
}
if ($user === '' || $pass === '') { exit(1); }
$stmt = $db->prepare('SELECT password_hash FROM users WHERE username = :u LIMIT 1');
$stmt->bindValue(':u', $user, SQLITE3_TEXT);
$res = $stmt->execute();
$row = $res ? $res->fetchArray(SQLITE3_ASSOC) : false;
if ($row && !empty($row['password_hash']) && password_verify($pass, $row['password_hash'])) {
    exit(0);
}
exit(1);
PHP
chmod +x /usr/local/bin/ovpn-auth.php

cat >/usr/local/bin/ovpn-log-event.php <<'PHP'
#!/usr/bin/env php
<?php
$db = new SQLite3('/var/www/html/ovpn-admin/data/ovpn.sqlite');
$db->busyTimeout(5000);
function envv($k){ $v=getenv($k); return $v===false ? '' : (string)$v; }
$peer = [];
foreach ($_ENV as $k=>$v) {
  if (strpos($k,'IV_')===0 || strpos($k,'UV_')===0 || in_array($k,['username','common_name','trusted_ip','trusted_port','ifconfig_pool_remote_ip','script_type'], true)) {
    $peer[$k]=(string)$v;
  }
}
ksort($peer);
$appHint = $peer['UV_APP_PACKAGE'] ?? ($peer['UV_APP_NAME'] ?? ($peer['IV_GUI_VER'] ?? ($peer['IV_PLAT'] ?? '')));
$stmt = $db->prepare('INSERT INTO connection_events(event_type,username,common_name,real_ip,virtual_ip,platform,platform_version,openvpn_version,gui_version,ssl_library,hwaddr,raw_peer_info,app_hint) VALUES (:event_type,:username,:common_name,:real_ip,:virtual_ip,:platform,:platform_version,:openvpn_version,:gui_version,:ssl_library,:hwaddr,:raw_peer_info,:app_hint)');
$stmt->bindValue(':event_type', envv('script_type')==='client-disconnect' ? 'disconnect' : 'connect', SQLITE3_TEXT);
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
$stmt->bindValue(':raw_peer_info', json_encode($peer, JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES), SQLITE3_TEXT);
$stmt->bindValue(':app_hint', (string)$appHint, SQLITE3_TEXT);
$stmt->execute();
PHP
chmod +x /usr/local/bin/ovpn-log-event.php

cat >/usr/local/bin/ovpn-make-profile.sh <<'MK'
#!/usr/bin/env bash
set -euo pipefail
USER_NAME="${1:?username required}"
SERVER_ADDR="${2:?server addr required}"
OUT_DIR="/var/www/html/ovpn-admin/downloads"
PKI_DIR="/etc/openvpn/pki-webadmin"
mkdir -p "$OUT_DIR"
cat >"$OUT_DIR/$USER_NAME.ovpn" <<PROFILE
client
dev tun
nobind
persist-key
persist-tun
auth-user-pass
auth-nocache
remote ${SERVER_ADDR} 1194 udp
remote ${SERVER_ADDR} 443 tcp-client
remote-random
resolv-retry infinite
connect-retry 3 10
remote-cert-tls server
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
data-ciphers-fallback AES-256-CBC
auth SHA256
verb 3
pull
push-peer-info
setenv UV_PROFILE_USER ${USER_NAME}
setenv UV_APP_PACKAGE unknown
setenv UV_APP_NAME unknown
<ca>
$(cat "$PKI_DIR/ca.crt")
</ca>
<tls-crypt>
$(cat "$PKI_DIR/ta.key")
</tls-crypt>
PROFILE
chmod 644 "$OUT_DIR/$USER_NAME.ovpn"
MK
chmod +x /usr/local/bin/ovpn-make-profile.sh

cat >/usr/local/bin/ovpn-user-manage.sh <<'USR'
#!/usr/bin/env bash
set -euo pipefail
DB="/var/www/html/ovpn-admin/data/ovpn.sqlite"
SERVER_ADDR="${SERVER_ADDR_OVERRIDE:-$(curl -4 -fsSL https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}') }"
cmd="${1:-}"
case "$cmd" in
  add)
    user="${2:?username}"
    pass="${3:?password}"
    hash="$(php -r "echo password_hash('$pass', PASSWORD_DEFAULT);")"
    sqlite3 "$DB" "INSERT INTO users(username,password_hash) VALUES('$user','$hash');"
    /usr/local/bin/ovpn-make-profile.sh "$user" "$SERVER_ADDR"
    echo "User added: $user"
    ;;
  update)
    user="${2:?username}"
    pass="${3:?password}"
    hash="$(php -r "echo password_hash('$pass', PASSWORD_DEFAULT);")"
    sqlite3 "$DB" "UPDATE users SET password_hash='$hash', updated_at=CURRENT_TIMESTAMP WHERE username='$user';"
    /usr/local/bin/ovpn-make-profile.sh "$user" "$SERVER_ADDR"
    echo "User updated: $user"
    ;;
  delete)
    user="${2:?username}"
    sqlite3 "$DB" "DELETE FROM users WHERE username='$user';"
    rm -f "/var/www/html/ovpn-admin/downloads/$user.ovpn"
    echo "User deleted: $user"
    ;;
  regen)
    user="${2:?username}"
    /usr/local/bin/ovpn-make-profile.sh "$user" "$SERVER_ADDR"
    echo "Profile regenerated: $user"
    ;;
  *)
    echo "Usage: $0 {add|update|delete|regen} user [pass]"
    exit 1
    ;;
esac
USR
chmod +x /usr/local/bin/ovpn-user-manage.sh
/usr/local/bin/ovpn-make-profile.sh "$DEFAULT_USER" "$SERVER_ADDR"

echo "[7/11] Writing OpenVPN configs..."
cat >"$OVPN_DIR/server-udp.conf" <<CONF
port ${UDP_PORT}
proto udp
dev tun
persist-key
persist-tun
topology subnet
server 10.8.0.0 255.255.255.0
ifconfig-pool-persist ${LOG_DIR}/ipp-udp.txt
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS 8.8.8.8"
keepalive 10 120
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
data-ciphers-fallback AES-256-CBC
auth SHA256
ca ${PKI_DIR}/ca.crt
cert ${PKI_DIR}/server.crt
key ${PKI_DIR}/server.key
dh ${PKI_DIR}/dh.pem
tls-crypt ${PKI_DIR}/ta.key
verify-client-cert none
username-as-common-name
auth-user-pass-verify /usr/local/bin/ovpn-auth.php via-file
script-security 3
duplicate-cn
client-to-client
status ${LOG_DIR}/openvpn-status-udp.log 10
status-version 3
log-append ${LOG_DIR}/server-udp.log
verb 4
client-connect /usr/local/bin/ovpn-log-event.php
client-disconnect /usr/local/bin/ovpn-log-event.php
explicit-exit-notify 1
CONF

cat >"$OVPN_DIR/server-tcp.conf" <<CONF
port ${TCP_PORT}
proto tcp-server
dev tun
persist-key
persist-tun
topology subnet
server 10.9.0.0 255.255.255.0
ifconfig-pool-persist ${LOG_DIR}/ipp-tcp.txt
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS 8.8.8.8"
keepalive 10 120
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
data-ciphers-fallback AES-256-CBC
auth SHA256
ca ${PKI_DIR}/ca.crt
cert ${PKI_DIR}/server.crt
key ${PKI_DIR}/server.key
dh ${PKI_DIR}/dh.pem
tls-crypt ${PKI_DIR}/ta.key
verify-client-cert none
username-as-common-name
auth-user-pass-verify /usr/local/bin/ovpn-auth.php via-file
script-security 3
duplicate-cn
client-to-client
status ${LOG_DIR}/openvpn-status-tcp.log 10
status-version 3
log-append ${LOG_DIR}/server-tcp.log
verb 4
client-connect /usr/local/bin/ovpn-log-event.php
client-disconnect /usr/local/bin/ovpn-log-event.php
CONF

echo "[8/11] Writing web panel..."
cat >"$APP_DIR/config.php" <<'PHP'
<?php
session_start();
date_default_timezone_set('UTC');
define('DB_PATH', __DIR__ . '/data/ovpn.sqlite');
define('DOWNLOAD_DIR', __DIR__ . '/downloads');
function db(){ static $db=null; if($db===null){ $db=new SQLite3(DB_PATH); $db->busyTimeout(5000);} return $db; }
function esc($v){ return htmlspecialchars((string)$v, ENT_QUOTES, 'UTF-8'); }
function require_login(){ if(empty($_SESSION['admin_user'])){ header('Location: login.php'); exit; } }
function admin_login($u,$p){ $st=db()->prepare('SELECT username,password_hash FROM admins WHERE username=:u LIMIT 1'); $st->bindValue(':u',$u,SQLITE3_TEXT); $r=$st->execute(); $row=$r?$r->fetchArray(SQLITE3_ASSOC):false; return $row && password_verify($p,$row['password_hash']); }
function users_all(){ $res=db()->query('SELECT id,username,created_at,updated_at FROM users ORDER BY id DESC'); $rows=[]; while($row=$res->fetchArray(SQLITE3_ASSOC)) $rows[]=$row; return $rows; }
function user_get($id){ $st=db()->prepare('SELECT * FROM users WHERE id=:id LIMIT 1'); $st->bindValue(':id',(int)$id,SQLITE3_INTEGER); $r=$st->execute(); return $r?$r->fetchArray(SQLITE3_ASSOC):false; }
function latest_logs($limit=200,$search=''){ if($search!==''){ $st=db()->prepare('SELECT * FROM connection_events WHERE username LIKE :s OR real_ip LIKE :s OR gui_version LIKE :s OR app_hint LIKE :s ORDER BY id DESC LIMIT :l'); $st->bindValue(':s','%'.$search.'%',SQLITE3_TEXT); $st->bindValue(':l',(int)$limit,SQLITE3_INTEGER); $r=$st->execute(); } else { $st=db()->prepare('SELECT * FROM connection_events ORDER BY id DESC LIMIT :l'); $st->bindValue(':l',(int)$limit,SQLITE3_INTEGER); $r=$st->execute(); } $rows=[]; while($row=$r->fetchArray(SQLITE3_ASSOC)) $rows[]=$row; return $rows; }
function active_clients(){ $files=['/var/log/openvpn/openvpn-status-udp.log','/var/log/openvpn/openvpn-status-tcp.log']; $rows=[]; foreach($files as $f){ if(!is_file($f)) continue; foreach(@file($f, FILE_IGNORE_NEW_LINES|FILE_SKIP_EMPTY_LINES) ?: [] as $line){ $p=explode("\t",$line); if(count($p)>=11 && $p[0]==='CLIENT_LIST'){ $rows[]=['common_name'=>$p[1]??'','real_address'=>$p[2]??'','bytes_received'=>$p[3]??'','bytes_sent'=>$p[4]??'','connected_since'=>$p[5]??'','virtual_address'=>$p[6]??'','username'=>$p[8]??'','source'=>basename($f)]; } } } return $rows; }
function dashboard_stats(){ return ['total_users'=>(int)db()->querySingle('SELECT COUNT(*) FROM users'),'total_events'=>(int)db()->querySingle('SELECT COUNT(*) FROM connection_events'),'today_connects'=>(int)db()->querySingle("SELECT COUNT(*) FROM connection_events WHERE event_type='connect' AND date(event_time)=date('now')"),'gui_rows'=>(int)db()->querySingle("SELECT COUNT(*) FROM connection_events WHERE COALESCE(gui_version,'')<>''")]; }
function profile_path($u){ return DOWNLOAD_DIR.'/'.$u.'.ovpn'; }
function cli($cmd){ exec($cmd.' 2>&1',$out,$code); return [$code, implode("\n",$out)]; }
function pretty_json($json){ $arr=json_decode((string)$json,true); return is_array($arr)?json_encode($arr, JSON_PRETTY_PRINT|JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES):(string)$json; }
PHP

cat >"$APP_DIR/style.css" <<'CSS'
:root{--bg:#08111f;--bg2:#0d1729;--card:#111c31;--muted:#9eb0d0;--text:#eef4ff;--accent:#4f8cff;--accent2:#19d1a2;--danger:#ff5f78;--line:#243653;}
*{box-sizing:border-box}html,body{margin:0;padding:0}body{font-family:Inter,Segoe UI,Arial,sans-serif;background:linear-gradient(180deg,var(--bg),var(--bg2));color:var(--text)}
a{color:inherit;text-decoration:none}.wrap{max-width:1200px;margin:0 auto;padding:20px}.top{display:flex;justify-content:space-between;align-items:center;margin-bottom:20px}.brand{font-size:34px;font-weight:800}.sub{color:var(--muted);margin-top:6px}.nav{display:flex;gap:10px;flex-wrap:wrap;margin:18px 0}.nav a{padding:12px 16px;background:#0d1b31;border:1px solid var(--line);border-radius:16px}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:16px}.card{background:rgba(17,28,49,.95);border:1px solid var(--line);border-radius:22px;padding:18px;box-shadow:0 10px 30px rgba(0,0,0,.22)}.kpi{font-size:30px;font-weight:800;margin-top:8px}.muted{color:var(--muted)}table{width:100%;border-collapse:collapse}th,td{padding:12px 10px;border-bottom:1px solid var(--line);font-size:14px;vertical-align:top}th{text-align:left;color:#b8c6e0}input,button,textarea{font:inherit}input,textarea{width:100%;padding:12px 14px;background:#0a1528;color:var(--text);border:1px solid var(--line);border-radius:14px}.btn{display:inline-block;padding:11px 16px;border:none;border-radius:14px;background:var(--accent);color:#fff;cursor:pointer}.btn.green{background:var(--accent2)}.btn.red{background:var(--danger)}.btn.gray{background:#223351}.flash{padding:13px 16px;border-radius:16px;margin-bottom:16px;background:#12332a;border:1px solid #1e6858}.code{white-space:pre-wrap;background:#091220;border:1px solid var(--line);padding:14px;border-radius:16px;overflow:auto}.login-card{max-width:460px;margin:40px auto}.actions{display:flex;gap:8px;flex-wrap:wrap}.small{font-size:12px;color:var(--muted)}
CSS

cat >"$APP_DIR/login.php" <<'PHP'
<?php require __DIR__.'/config.php'; if(!empty($_SESSION['admin_user'])){ header('Location: index.php'); exit; } $err=''; if($_SERVER['REQUEST_METHOD']==='POST'){ if(admin_login(trim($_POST['username'] ?? ''), $_POST['password'] ?? '')){ $_SESSION['admin_user']=trim($_POST['username']); header('Location: index.php'); exit; } $err='Invalid username or password'; } ?>
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>OpenVPN Admin Login</title><link rel="stylesheet" href="style.css"></head><body><div class="wrap"><div class="card login-card"><div class="brand">OpenVPN Admin Pro</div><div class="sub">Login with generated admin account</div><?php if($err): ?><div class="flash" style="background:#3b1820;border-color:#7d3142"><?=esc($err)?></div><?php endif; ?><form method="post"><label>Username</label><input name="username" value="openvpn" required><br><br><label>Password</label><input type="password" name="password" required><br><br><button class="btn" type="submit">Login</button></form></div></div></body></html>
PHP

cat >"$APP_DIR/index.php" <<'PHP'
<?php require __DIR__.'/config.php'; require_login(); $stats=dashboard_stats(); $active=active_clients(); ?>
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Dashboard</title><link rel="stylesheet" href="style.css"></head><body><div class="wrap"><div class="top"><div><div class="brand">OpenVPN Admin Pro</div><div class="sub">Logged in as <?=esc($_SESSION['admin_user'])?></div></div></div><div class="nav"><a href="index.php">Dashboard</a><a href="users.php">Users</a><a href="new_user.php">New User</a><a href="logs.php">Connection Logs</a><a href="change_password.php">Change Admin Password</a><a href="logout.php">Logout</a></div><div class="grid"><div class="card"><div class="muted">Total users</div><div class="kpi"><?=$stats['total_users']?></div></div><div class="card"><div class="muted">Total events</div><div class="kpi"><?=$stats['total_events']?></div></div><div class="card"><div class="muted">Today connects</div><div class="kpi"><?=$stats['today_connects']?></div></div><div class="card"><div class="muted">Rows with GUI version</div><div class="kpi"><?=$stats['gui_rows']?></div></div></div><div class="card" style="margin-top:18px"><h3>Active connected devices</h3><div style="overflow:auto"><table><tr><th>User</th><th>Common Name</th><th>Real Address</th><th>Virtual IP</th><th>Since</th><th>RX</th><th>TX</th><th>Source</th></tr><?php foreach($active as $c): ?><tr><td><?=esc($c['username'])?></td><td><?=esc($c['common_name'])?></td><td><?=esc($c['real_address'])?></td><td><?=esc($c['virtual_address'])?></td><td><?=esc($c['connected_since'])?></td><td><?=esc($c['bytes_received'])?></td><td><?=esc($c['bytes_sent'])?></td><td><?=esc($c['source'])?></td></tr><?php endforeach; ?></table></div></div></div></body></html>
PHP

cat >"$APP_DIR/users.php" <<'PHP'
<?php require __DIR__.'/config.php'; require_login(); $users=users_all(); ?>
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Users</title><link rel="stylesheet" href="style.css"></head><body><div class="wrap"><div class="nav"><a href="index.php">Dashboard</a><a href="users.php">Users</a><a href="new_user.php">New User</a><a href="logs.php">Connection Logs</a><a href="change_password.php">Change Admin Password</a><a href="logout.php">Logout</a></div><div class="card"><h2>All users</h2><div style="overflow:auto"><table><tr><th>Username</th><th>Created</th><th>Updated</th><th>Actions</th></tr><?php foreach($users as $u): ?><tr><td><?=esc($u['username'])?></td><td><?=esc($u['created_at'])?></td><td><?=esc($u['updated_at'])?></td><td><div class="actions"><a class="btn green" href="download.php?u=<?=urlencode($u['username'])?>">Download OVPN</a><a class="btn gray" href="show_config.php?u=<?=urlencode($u['username'])?>">Show Config</a><a class="btn" href="edit_user.php?id=<?=$u['id']?>">Edit</a><a class="btn red" href="delete_user.php?id=<?=$u['id']?>" onclick="return confirm('Delete this user?')">Delete</a></div></td></tr><?php endforeach; ?></table></div></div></div></body></html>
PHP

cat >"$APP_DIR/new_user.php" <<'PHP'
<?php require __DIR__.'/config.php'; require_login(); $msg=''; if($_SERVER['REQUEST_METHOD']==='POST'){ $u=trim($_POST['username']??''); $p=$_POST['password']??''; if($u!=='' && $p!==''){ [$code,$out]=cli('/usr/local/bin/ovpn-user-manage.sh add '.escapeshellarg($u).' '.escapeshellarg($p)); $msg=$out ?: ($code===0 ? 'User created' : 'Failed'); } } ?>
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>New User</title><link rel="stylesheet" href="style.css"></head><body><div class="wrap"><div class="nav"><a href="index.php">Dashboard</a><a href="users.php">Users</a><a href="new_user.php">New User</a><a href="logs.php">Connection Logs</a><a href="change_password.php">Change Admin Password</a><a href="logout.php">Logout</a></div><div class="card"><h2>Create user</h2><?php if($msg): ?><div class="flash"><?=esc($msg)?></div><?php endif; ?><form method="post"><label>Username</label><input name="username" required><br><br><label>Password</label><input name="password" required><br><br><button class="btn" type="submit">Create</button></form></div></div></body></html>
PHP

cat >"$APP_DIR/edit_user.php" <<'PHP'
<?php require __DIR__.'/config.php'; require_login(); $id=(int)($_GET['id']??0); $user=user_get($id); if(!$user){ http_response_code(404); exit('User not found'); } $msg=''; if($_SERVER['REQUEST_METHOD']==='POST'){ $p=$_POST['password']??''; if($p!==''){ [$code,$out]=cli('/usr/local/bin/ovpn-user-manage.sh update '.escapeshellarg($user['username']).' '.escapeshellarg($p)); $msg=$out ?: ($code===0 ? 'User updated' : 'Failed'); } } ?>
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Edit User</title><link rel="stylesheet" href="style.css"></head><body><div class="wrap"><div class="nav"><a href="users.php">Back to Users</a></div><div class="card"><h2>Edit user</h2><?php if($msg): ?><div class="flash"><?=esc($msg)?></div><?php endif; ?><div class="muted">Username: <b><?=esc($user['username'])?></b></div><br><form method="post"><label>New Password</label><input name="password" required><br><br><button class="btn" type="submit">Update Password</button></form></div></div></body></html>
PHP

cat >"$APP_DIR/delete_user.php" <<'PHP'
<?php require __DIR__.'/config.php'; require_login(); $id=(int)($_GET['id']??0); $u=user_get($id); if($u){ cli('/usr/local/bin/ovpn-user-manage.sh delete '.escapeshellarg($u['username'])); } header('Location: users.php');
PHP

cat >"$APP_DIR/download.php" <<'PHP'
<?php require __DIR__.'/config.php'; require_login(); $u=basename($_GET['u']??''); $p=profile_path($u); if(!is_file($p)){ http_response_code(404); exit('Profile not found'); } header('Content-Type: application/octet-stream'); header('Content-Disposition: attachment; filename="'.$u.'.ovpn"'); readfile($p);
PHP

cat >"$APP_DIR/show_config.php" <<'PHP'
<?php require __DIR__.'/config.php'; require_login(); $u=basename($_GET['u']??''); $p=profile_path($u); if(!is_file($p)){ http_response_code(404); exit('Profile not found'); } $cfg=file_get_contents($p); ?><!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Config</title><link rel="stylesheet" href="style.css"></head><body><div class="wrap"><div class="nav"><a href="users.php">Back to Users</a></div><div class="card"><h2>Config: <?=esc($u)?></h2><div class="code"><?=esc($cfg)?></div></div></div></body></html>
PHP

cat >"$APP_DIR/logs.php" <<'PHP'
<?php require __DIR__.'/config.php'; require_login(); $q=trim($_GET['q']??''); $rows=latest_logs(300,$q); if(isset($_GET['csv'])){ header('Content-Type:text/csv'); header('Content-Disposition: attachment; filename="ovpn-logs.csv"'); $f=fopen('php://output','w'); fputcsv($f,['time','event','username','common_name','real_ip','virtual_ip','platform','gui_version','app_hint']); foreach($rows as $r){ fputcsv($f,[$r['event_time'],$r['event_type'],$r['username'],$r['common_name'],$r['real_ip'],$r['virtual_ip'],$r['platform'],$r['gui_version'],$r['app_hint']]); } exit; } ?>
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Connection Logs</title><link rel="stylesheet" href="style.css"></head><body><div class="wrap"><div class="nav"><a href="index.php">Dashboard</a><a href="users.php">Users</a><a href="new_user.php">New User</a><a href="logs.php">Connection Logs</a><a href="change_password.php">Change Admin Password</a><a href="logout.php">Logout</a></div><div class="card"><div class="top"><h2>Connection logs</h2><a class="btn" href="logs.php?csv=1<?= $q!=='' ? '&q='.urlencode($q) : '' ?>">Export as CSV</a></div><form method="get" class="actions"><input name="q" placeholder="Search username, IP, GUI version" value="<?=esc($q)?>"><button class="btn gray" type="submit">Search</button></form><br><div style="overflow:auto"><table><tr><th>Time</th><th>Event</th><th>User</th><th>IP</th><th>Platform</th><th>GUI Version</th><th>App Hint</th><th>Raw Peer Info</th></tr><?php foreach($rows as $r): ?><tr><td><?=esc($r['event_time'])?></td><td><?=esc($r['event_type'])?></td><td><?=esc($r['username'] ?: $r['common_name'])?></td><td><?=esc($r['real_ip'])?><br><span class="small"><?=esc($r['virtual_ip'])?></span></td><td><?=esc($r['platform'])?></td><td><?=esc($r['gui_version'])?></td><td><?=esc($r['app_hint'])?></td><td><div class="code"><?=esc(pretty_json($r['raw_peer_info']))?></div></td></tr><?php endforeach; ?></table></div></div></div></body></html>
PHP

cat >"$APP_DIR/change_password.php" <<'PHP'
<?php require __DIR__.'/config.php'; require_login(); $msg=''; if($_SERVER['REQUEST_METHOD']==='POST'){ $cur=$_POST['current_password']??''; $new=$_POST['new_password']??''; if(admin_login($_SESSION['admin_user'],$cur) && $new!==''){ $hash=password_hash($new, PASSWORD_DEFAULT); $st=db()->prepare('UPDATE admins SET password_hash=:h WHERE username=:u'); $st->bindValue(':h',$hash,SQLITE3_TEXT); $st->bindValue(':u',$_SESSION['admin_user'],SQLITE3_TEXT); $st->execute(); $msg='Admin password updated'; } else { $msg='Current password is incorrect'; } } ?>
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Change Admin Password</title><link rel="stylesheet" href="style.css"></head><body><div class="wrap"><div class="nav"><a href="index.php">Dashboard</a><a href="users.php">Users</a><a href="new_user.php">New User</a><a href="logs.php">Connection Logs</a><a href="change_password.php">Change Admin Password</a><a href="logout.php">Logout</a></div><div class="card"><h2>Change admin password</h2><?php if($msg): ?><div class="flash"><?=esc($msg)?></div><?php endif; ?><form method="post"><label>Current Password</label><input type="password" name="current_password" required><br><br><label>New Password</label><input type="password" name="new_password" required><br><br><button class="btn" type="submit">Update</button></form></div></div></body></html>
PHP

cat >"$APP_DIR/logout.php" <<'PHP'
<?php require __DIR__.'/config.php'; session_destroy(); header('Location: login.php');
PHP

echo "[9/11] Setting permissions..."
chown -R www-data:www-data "$APP_DIR"
chmod -R 755 "$APP_DIR"
chmod -R 777 "$DOWNLOAD_DIR" "$DATA_DIR"
chmod 644 "$APP_DIR"/*.php "$APP_DIR"/*.css

echo "[10/11] Enabling services..."
a2enmod rewrite >/dev/null || true
systemctl restart apache2
systemctl daemon-reload
systemctl enable ovpn-iptables.service >/dev/null
systemctl enable openvpn-server@server-udp >/dev/null
systemctl enable openvpn-server@server-tcp >/dev/null
systemctl restart openvpn-server@server-udp
systemctl restart openvpn-server@server-tcp
systemctl restart ovpn-iptables.service || true

echo "[11/11] Done."
echo
echo "Panel URL: http://${SERVER_ADDR}/ovpn-admin/"
echo "Admin user: ${ADMIN_USER}"
echo "Admin pass: ${ADMIN_PASS}"
echo "Default VPN user: ${DEFAULT_USER}"
echo "Default VPN pass: ${DEFAULT_USER_PASS}"
echo
echo "CLI user commands:"
echo "  /usr/local/bin/ovpn-user-manage.sh add USER PASS"
echo "  /usr/local/bin/ovpn-user-manage.sh update USER PASS"
echo "  /usr/local/bin/ovpn-user-manage.sh delete USER"
