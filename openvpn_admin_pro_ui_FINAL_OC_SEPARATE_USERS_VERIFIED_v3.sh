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
BIN_DIR="/usr/local/bin"

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

echo "[1/12] Removing old install if present..."
systemctl stop openvpn-server@server-udp openvpn-server@server-tcp apache2 ovpn-iptables.service 2>/dev/null || true
systemctl disable openvpn-server@server-udp openvpn-server@server-tcp ovpn-iptables.service 2>/dev/null || true
rm -rf "$APP_DIR" "$PKI_DIR"
rm -f "$OVPN_DIR/server-udp.conf" "$OVPN_DIR/server-tcp.conf"
rm -f "$BIN_DIR/ovpn-auth.php" "$BIN_DIR/ovpn-log-event.php" "$BIN_DIR/ovpn-make-profile.sh" "$BIN_DIR/ovpn-user-manage.sh" "$BIN_DIR/ovpn-iptables-apply.sh"
rm -f /etc/systemd/system/ovpn-iptables.service
rm -f "$LOG_DIR"/server-udp.log "$LOG_DIR"/server-tcp.log "$LOG_DIR"/openvpn-status-udp.log "$LOG_DIR"/openvpn-status-tcp.log "$LOG_DIR"/ipp-udp.txt "$LOG_DIR"/ipp-tcp.txt
systemctl daemon-reload || true

echo "[2/12] Installing packages..."
apt-get update
apt-get install -y openvpn easy-rsa apache2 php libapache2-mod-php php-sqlite3 php-cli sqlite3 curl openssl ca-certificates acl netcat-openbsd

echo "[3/12] Creating directories..."
mkdir -p "$APP_DIR" "$DATA_DIR" "$DOWNLOAD_DIR" "$PKI_DIR" "$OVPN_DIR" "$LOG_DIR" "$BIN_DIR"
chown -R www-data:www-data "$APP_DIR"
chmod -R 755 "$APP_DIR"
chown root:www-data "$LOG_DIR"
chmod 750 "$LOG_DIR"
setfacl -m u:www-data:rx "$LOG_DIR" 2>/dev/null || true
setfacl -d -m u:www-data:rx "$LOG_DIR" 2>/dev/null || true

echo "[4/12] Enabling IP forwarding..."
cat >/etc/sysctl.d/99-openvpn-forward.conf <<SYSCTL
net.ipv4.ip_forward=1
SYSCTL
sysctl --system >/dev/null

echo "[5/12] Configuring firewall/NAT..."
cat >"$BIN_DIR/ovpn-iptables-apply.sh" <<RULES
#!/usr/bin/env bash
set -e
iptables -t nat -C POSTROUTING -s 10.8.0.0/24 -o ${NET_IFACE} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o ${NET_IFACE} -j MASQUERADE
iptables -t nat -C POSTROUTING -s 10.9.0.0/24 -o ${NET_IFACE} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s 10.9.0.0/24 -o ${NET_IFACE} -j MASQUERADE
iptables -t nat -C POSTROUTING -s 10.20.30.0/24 -o ${NET_IFACE} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s 10.20.30.0/24 -o ${NET_IFACE} -j MASQUERADE
iptables -C FORWARD -s 10.20.30.0/24 -j ACCEPT 2>/dev/null || iptables -A FORWARD -s 10.20.30.0/24 -j ACCEPT
iptables -C FORWARD -d 10.20.30.0/24 -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || iptables -A FORWARD -d 10.20.30.0/24 -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -C INPUT -p udp --dport ${UDP_PORT} -j ACCEPT 2>/dev/null || iptables -A INPUT -p udp --dport ${UDP_PORT} -j ACCEPT
iptables -C INPUT -p tcp --dport ${TCP_PORT} -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport ${TCP_PORT} -j ACCEPT
iptables -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport 80 -j ACCEPT
RULES
chmod +x "$BIN_DIR/ovpn-iptables-apply.sh"
"$BIN_DIR/ovpn-iptables-apply.sh" || true

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

echo "[6/12] Generating PKI..."
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
# Allow Apache/PHP (www-data) to read CA and tls-crypt key for profile generation
chown -R root:www-data "$PKI_DIR"
chmod 750 "$PKI_DIR"
chmod 640 "$PKI_DIR/server.key" "$PKI_DIR/ta.key"
chmod 644 "$PKI_DIR/ca.crt" "$PKI_DIR/server.crt" "$PKI_DIR/dh.pem"

echo "[7/12] Creating database..."
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
  blocked INTEGER NOT NULL DEFAULT 0,
  notes TEXT DEFAULT '',
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
  time_duration INTEGER DEFAULT 0,
  rx_bytes INTEGER DEFAULT 0,
  tx_bytes INTEGER DEFAULT 0,
  raw_peer_info TEXT,
  app_hint TEXT
);
SQL

ADMIN_HASH="$(php -r "echo password_hash('${ADMIN_PASS}', PASSWORD_DEFAULT);")"
USER_HASH="$(php -r "echo password_hash('${DEFAULT_USER_PASS}', PASSWORD_DEFAULT);")"
sqlite3 "$DB_FILE" "INSERT OR REPLACE INTO admins(username,password_hash) VALUES('${ADMIN_USER}','$ADMIN_HASH');"
sqlite3 "$DB_FILE" "INSERT OR REPLACE INTO users(username,password_hash,blocked) VALUES('${DEFAULT_USER}','$USER_HASH',0);"

echo "[8/12] Writing helper scripts..."
cat >"$BIN_DIR/ovpn-auth.php" <<'PHP'
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

$stmt = $db->prepare('SELECT password_hash, blocked FROM users WHERE username = :u LIMIT 1');
$stmt->bindValue(':u', $user, SQLITE3_TEXT);
$res = $stmt->execute();
$row = $res ? $res->fetchArray(SQLITE3_ASSOC) : false;

if (!$row) exit(1);
if ((int)($row['blocked'] ?? 0) === 1) exit(1);
if (!empty($row['password_hash']) && password_verify($pass, $row['password_hash'])) exit(0);
exit(1);
PHP
chmod +x "$BIN_DIR/ovpn-auth.php"

cat >"$BIN_DIR/ovpn-log-event.php" <<'PHP'
#!/usr/bin/env php
<?php
$db = new SQLite3('/var/www/html/ovpn-admin/data/ovpn.sqlite');
$db->busyTimeout(5000);

function envv($k){
    $v=getenv($k);
    return $v===false ? '' : (string)$v;
}
$peer = [];
foreach ($_SERVER as $k=>$v) {
    if (strpos($k,'IV_')===0 || strpos($k,'UV_')===0 || in_array($k,[
        'username','common_name','trusted_ip','trusted_port','ifconfig_pool_remote_ip',
        'script_type','bytes_received','bytes_sent','time_duration'
    ], true)) {
        $peer[$k]=(string)$v;
    }
}
$appHint = $peer['UV_APP_PACKAGE'] ?? ($peer['UV_APP_NAME'] ?? ($peer['IV_GUI_VER'] ?? ($peer['IV_PLAT'] ?? '')));
$eventType = envv('script_type') === 'client-disconnect' ? 'disconnect' : 'connect';
$stmt = $db->prepare('INSERT INTO connection_events(
    event_type,username,common_name,real_ip,virtual_ip,platform,platform_version,openvpn_version,gui_version,ssl_library,hwaddr,time_duration,rx_bytes,tx_bytes,raw_peer_info,app_hint
) VALUES (
    :event_type,:username,:common_name,:real_ip,:virtual_ip,:platform,:platform_version,:openvpn_version,:gui_version,:ssl_library,:hwaddr,:time_duration,:rx_bytes,:tx_bytes,:raw_peer_info,:app_hint
)');
$stmt->bindValue(':event_type', $eventType, SQLITE3_TEXT);
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
$stmt->bindValue(':time_duration', (int)(envv('time_duration') ?: 0), SQLITE3_INTEGER);
$stmt->bindValue(':rx_bytes', (int)(envv('bytes_received') ?: 0), SQLITE3_INTEGER);
$stmt->bindValue(':tx_bytes', (int)(envv('bytes_sent') ?: 0), SQLITE3_INTEGER);
$stmt->bindValue(':raw_peer_info', json_encode($peer, JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES), SQLITE3_TEXT);
$stmt->bindValue(':app_hint', (string)$appHint, SQLITE3_TEXT);
$stmt->execute();
PHP
chmod +x "$BIN_DIR/ovpn-log-event.php"

cat >"$BIN_DIR/ovpn-make-profile.sh" <<'MK'
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
chmod +x "$BIN_DIR/ovpn-make-profile.sh"

cat >"$BIN_DIR/ovpn-kill-user.sh" <<'KILL'
#!/usr/bin/env bash
set -euo pipefail
USER_NAME="${1:-}"
[[ -n "$USER_NAME" ]] || exit 0
for port in 7505 7506; do
  printf "kill %s\nquit\n" "$USER_NAME" | nc -N 127.0.0.1 "$port" >/dev/null 2>&1 || true
  printf "kill %s\nquit\n" "CN=$USER_NAME" | nc -N 127.0.0.1 "$port" >/dev/null 2>&1 || true
  printf "status 3\nquit\n" | nc -N 127.0.0.1 "$port" >/dev/null 2>&1 || true
done
KILL
chmod +x "$BIN_DIR/ovpn-kill-user.sh"

cat >"$BIN_DIR/ovpn-user-manage.sh" <<'USR'
#!/usr/bin/env bash
set -euo pipefail
DB="/var/www/html/ovpn-admin/data/ovpn.sqlite"
SERVER_ADDR="${SERVER_ADDR_OVERRIDE:-$(curl -4 -fsSL https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')}"
cmd="${1:-}"
user="${2:-}"
pass="${3:-}"
sql_escape() { printf "%s" "$1" | sed "s/'/''/g"; }

case "$cmd" in
  add)
    [[ -n "$user" && -n "$pass" ]] || { echo "Usage: add user pass"; exit 1; }
    hash="$(php -r 'echo password_hash($argv[1], PASSWORD_DEFAULT);' "$pass")"
    sqlite3 "$DB" "INSERT INTO users(username,password_hash,blocked,notes) VALUES('$(sql_escape "$user")','$(sql_escape "$hash")',0,'');"
    /usr/local/bin/ovpn-make-profile.sh "$user" "$SERVER_ADDR"
    echo "User added: $user"
    ;;
  update)
    [[ -n "$user" && -n "$pass" ]] || { echo "Usage: update user pass"; exit 1; }
    hash="$(php -r 'echo password_hash($argv[1], PASSWORD_DEFAULT);' "$pass")"
    sqlite3 "$DB" "UPDATE users SET password_hash='$(sql_escape "$hash")', updated_at=CURRENT_TIMESTAMP WHERE username='$(sql_escape "$user")';"
    /usr/local/bin/ovpn-make-profile.sh "$user" "$SERVER_ADDR"
    echo "User updated: $user"
    ;;
  delete)
    [[ -n "$user" ]] || { echo "Usage: delete user"; exit 1; }
    sqlite3 "$DB" "DELETE FROM users WHERE username='$(sql_escape "$user")';"
    rm -f "/var/www/html/ovpn-admin/downloads/$user.ovpn"
    echo "User deleted: $user"
    ;;
  block)
    [[ -n "$user" ]] || { echo "Usage: block user"; exit 1; }
    sqlite3 "$DB" "UPDATE users SET blocked=1, updated_at=CURRENT_TIMESTAMP WHERE username='$(sql_escape "$user")';"
    /usr/local/bin/ovpn-kill-user.sh "$user"
    echo "User blocked: $user"
    ;;
  unblock)
    [[ -n "$user" ]] || { echo "Usage: unblock user"; exit 1; }
    sqlite3 "$DB" "UPDATE users SET blocked=0, updated_at=CURRENT_TIMESTAMP WHERE username='$(sql_escape "$user")';"
    echo "User unblocked: $user"
    ;;
  regen)
    [[ -n "$user" ]] || { echo "Usage: regen user"; exit 1; }
    /usr/local/bin/ovpn-make-profile.sh "$user" "$SERVER_ADDR"
    echo "Profile regenerated: $user"
    ;;
  *)
    echo "Usage: $0 {add|update|delete|block|unblock|regen} user [pass]"
    exit 1
    ;;
esac
USR
chmod +x "$BIN_DIR/ovpn-user-manage.sh"

"$BIN_DIR/ovpn-make-profile.sh" "$DEFAULT_USER" "$SERVER_ADDR"

echo "[9/12] Writing OpenVPN configs..."
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
auth-user-pass-verify ${BIN_DIR}/ovpn-auth.php via-file
script-security 3
duplicate-cn
client-to-client
status ${LOG_DIR}/openvpn-status-udp.log 3
status-version 3
management 127.0.0.1 7505
log-append ${LOG_DIR}/server-udp.log
verb 4
client-connect ${BIN_DIR}/ovpn-log-event.php
client-disconnect ${BIN_DIR}/ovpn-log-event.php
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
auth-user-pass-verify ${BIN_DIR}/ovpn-auth.php via-file
script-security 3
duplicate-cn
client-to-client
status ${LOG_DIR}/openvpn-status-tcp.log 3
status-version 3
management 127.0.0.1 7506
log-append ${LOG_DIR}/server-tcp.log
verb 4
client-connect ${BIN_DIR}/ovpn-log-event.php
client-disconnect ${BIN_DIR}/ovpn-log-event.php
CONF

echo "[10/12] Writing web panel..."
cat >"$APP_DIR/config.php" <<'PHP'
<?php
session_start();
date_default_timezone_set('UTC');

define('DB_PATH', __DIR__ . '/data/ovpn.sqlite');
define('DOWNLOAD_DIR', __DIR__ . '/downloads');

function db(){
    static $db=null;
    if($db===null){
        $db=new SQLite3(DB_PATH);
        $db->busyTimeout(5000);
    }
    return $db;
}
function esc($v){ return htmlspecialchars((string)$v, ENT_QUOTES, 'UTF-8'); }
function require_login(){ if(empty($_SESSION['admin_user'])){ header('Location: login.php'); exit; } }
function admin_login($u,$p){
    $st=db()->prepare('SELECT username,password_hash FROM admins WHERE username=:u LIMIT 1');
    $st->bindValue(':u',$u,SQLITE3_TEXT);
    $r=$st->execute();
    $row=$r?$r->fetchArray(SQLITE3_ASSOC):false;
    return $row && password_verify($p,$row['password_hash']);
}
function cli($cmd){ exec($cmd.' 2>&1',$out,$code); return [$code, implode("\n",$out)]; }
function profile_path($u){ return DOWNLOAD_DIR.'/'.$u.'.ovpn'; }
function pretty_json($json){
    $arr=json_decode((string)$json,true);
    return is_array($arr)?json_encode($arr, JSON_PRETTY_PRINT|JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES):(string)$json;
}
function human_bytes($bytes){
    $bytes=(float)$bytes;
    $units=['B','KB','MB','GB','TB'];
    $i=0;
    while($bytes>=1024 && $i<count($units)-1){ $bytes/=1024; $i++; }
    return ($i===0 ? (string)(int)$bytes : number_format($bytes,2)).' '.$units[$i];
}
function users_all(){
    $res=db()->query("SELECT id,username,blocked,created_at,updated_at FROM users ORDER BY id DESC");
    $rows=[]; while($row=$res->fetchArray(SQLITE3_ASSOC)) $rows[]=$row;
    return $rows;
}
function user_get($id){
    $st=db()->prepare('SELECT * FROM users WHERE id=:id LIMIT 1');
    $st->bindValue(':id',(int)$id,SQLITE3_INTEGER);
    $r=$st->execute();
    return $r?$r->fetchArray(SQLITE3_ASSOC):false;
}
function latest_logs($limit=300,$search=''){
    if($search!==''){
        $st=db()->prepare("SELECT * FROM connection_events WHERE event_type='connect' AND (username LIKE :s OR real_ip LIKE :s OR gui_version LIKE :s) ORDER BY id DESC LIMIT :l");
        $st->bindValue(':s','%'.$search.'%',SQLITE3_TEXT);
        $st->bindValue(':l',(int)$limit,SQLITE3_INTEGER);
        $r=$st->execute();
    } else {
        $st=db()->prepare("SELECT * FROM connection_events WHERE event_type='connect' ORDER BY id DESC LIMIT :l");
        $st->bindValue(':l',(int)$limit,SQLITE3_INTEGER);
        $r=$st->execute();
    }
    $rows=[]; while($row=$r->fetchArray(SQLITE3_ASSOC)) $rows[]=$row;
    return $rows;
}
function parse_status_file($file){
    $rows=[];
    if(!is_file($file) || !is_readable($file)) return $rows;
    $lines=@file($file, FILE_IGNORE_NEW_LINES|FILE_SKIP_EMPTY_LINES);
    if(!$lines) return $rows;
    $clients=[]; $routes=[];
    foreach($lines as $line){
        if(strpos($line,'CLIENT_LIST')===0){
            $p=preg_split('/[	,]/', $line);
            $common=$p[1] ?? '';
            $real=$p[2] ?? '';
            $key=$common.'|'.$real;
            $clients[$key]=[
                'common_name'=>$common,
                'real_address'=>$real,
                'bytes_received'=>(int)($p[3] ?? 0),
                'bytes_sent'=>(int)($p[4] ?? 0),
                'connected_since'=>$p[5] ?? '',
                'virtual_address'=>'',
                'username'=>$p[8] ?? ($p[7] ?? $common),
                'cipher'=>$p[count($p)-1] ?? '',
            ];
        } elseif(strpos($line,'ROUTING_TABLE')===0){
            $p=preg_split('/[	,]/', $line);
            $routes[]=[
                'virtual_address'=>$p[1] ?? '',
                'common_name'=>$p[2] ?? '',
                'real_address'=>$p[3] ?? '',
                'username'=>$p[5] ?? '',
            ];
        }
    }
    foreach($routes as $rt){
        foreach($clients as $key=>$cl){
            if(($rt['common_name']!=='' && $rt['common_name']===$cl['common_name']) || ($rt['real_address']!=='' && $rt['real_address']===$cl['real_address'])){
                if($rt['virtual_address']!=='') $clients[$key]['virtual_address']=$rt['virtual_address'];
                if(($clients[$key]['username'] ?? '')==='' && $rt['username']!=='') $clients[$key]['username']=$rt['username'];
            }
        }
    }
    return array_values($clients);
}
function active_from_events(){
    $sql = "SELECT e1.username,e1.common_name,e1.real_ip AS real_address,e1.virtual_ip AS virtual_address,e1.event_time AS connected_since,e1.gui_version
            FROM connection_events e1
            INNER JOIN (
                SELECT COALESCE(username,'' ) AS u, COALESCE(real_ip,'' ) AS ip, MAX(id) AS max_id
                FROM connection_events
                WHERE COALESCE(username,'')<>''
                GROUP BY COALESCE(username,''), COALESCE(real_ip,'')
            ) latest ON latest.max_id=e1.id
            WHERE e1.event_type='connect'";
    $res=db()->query($sql);
    $rows=[];
    while($row=$res->fetchArray(SQLITE3_ASSOC)){
        $rows[]=[
            'common_name'=>$row['common_name'] ?: $row['username'],
            'real_address'=>$row['real_address'] ?: '-',
            'bytes_received'=>0,
            'bytes_sent'=>0,
            'connected_since'=>$row['connected_since'] ?: '',
            'virtual_address'=>$row['virtual_address'] ?: '-',
            'username'=>$row['username'] ?: ($row['common_name'] ?: ''),
            'cipher'=>'',
            'source'=>'EVENT',
            'gui_version'=>$row['gui_version'] ?? '',
        ];
    }
    return $rows;
}
function active_clients(){
    $rows=[];
    foreach(['/var/log/openvpn/openvpn-status-udp.log'=>'UDP','/var/log/openvpn/openvpn-status-tcp.log'=>'TCP'] as $file=>$source){
        foreach(parse_status_file($file) as $r){
            $r['source']=$source;
            if(($r['username'] ?? '')==='') $r['username']=$r['common_name'] ?? '';
            $r['gui_version']=last_gui_for_user($r['username'] ?: ($r['common_name'] ?? ''));
            $rows[]=$r;
        }
    }
    if(!$rows) $rows=active_from_events();
    return $rows;
}
function active_clients_by_user(){
    $map=[];
    foreach(active_clients() as $row){
        $u = $row['username'] ?: $row['common_name'];
        if($u==='') continue;
        if(!isset($map[$u])) $map[$u]=[];
        $map[$u][]=$row;
    }
    return $map;
}
function dashboard_stats(){
    $active=active_clients();
    return [
        'total_users'=>(int)db()->querySingle('SELECT COUNT(*) FROM users'),
        'active_connections'=>count($active),
        'active_users'=>count(array_unique(array_map(fn($x)=>($x['username'] ?: $x['common_name']), $active))),
        'today_connects'=>(int)db()->querySingle("SELECT COUNT(*) FROM connection_events WHERE event_type='connect' AND date(event_time)=date('now')"),
        'gui_rows'=>(int)db()->querySingle("SELECT COUNT(*) FROM connection_events WHERE event_type='connect' AND COALESCE(gui_version,'')<>''")
    ];
}
function last_gui_for_user($username){
    $st=db()->prepare("SELECT gui_version FROM connection_events WHERE username=:u AND COALESCE(gui_version,'')<>'' ORDER BY id DESC LIMIT 1");
    $st->bindValue(':u',$username,SQLITE3_TEXT);
    $r=$st->execute();
    $row=$r?$r->fetchArray(SQLITE3_ASSOC):false;
    return $row['gui_version'] ?? '';
}
function render_header($title='OpenVPN Admin'){
?>
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="refresh" content="15">
<title><?=esc($title)?></title>
<link rel="stylesheet" href="style.css">
</head>
<body>
<div class="shell">
<header class="site-header">
  <div class="brand-wrap">
    <button class="menu-btn" type="button" onclick="document.body.classList.toggle('menu-open')">☰</button>
    <div>
      <div class="brand">OpenVPN Admin</div>
      <div class="sub">Logged in as <?=esc($_SESSION['admin_user'] ?? '')?></div>
    </div>
  </div>
  <a class="refresh-btn" href="<?=esc(basename($_SERVER['PHP_SELF']).(!empty($_SERVER['QUERY_STRING'])?'?'.$_SERVER['QUERY_STRING']:''))?>">Refresh</a>
</header>
<div class="layout">
  <aside class="sidebar">
    <nav class="menu">
      <a href="index.php">Dashboard</a>
      <a href="users.php">Users</a>
      <a href="new_user.php">New User</a>
      <a href="logs.php">Connection Logs</a>
      <a href="change_password.php">Change Admin Password</a>
      <a href="logout.php">Logout</a>
    </nav>
  </aside>
  <main class="content">
<?php
}
function render_footer(){
?>
  </main>
</div>
</div>
<script>
document.addEventListener('click', function(e){
  if (e.target.matches('.overlay-close')) document.body.classList.remove('menu-open');
});
</script>
</body>
</html>
<?php
}
PHP

cat >"$APP_DIR/style.css" <<'CSS'
:root{
  --bg:#071120;
  --bg2:#0b1730;
  --panel:#0e1b34;
  --panel2:#101f3c;
  --line:#223557;
  --text:#eef4ff;
  --muted:#9cb2d8;
  --blue:#4f8cff;
  --green:#22c793;
  --red:#ff5f78;
  --yellow:#ffbf47;
  --shadow:0 16px 40px rgba(0,0,0,.28);
}
*{box-sizing:border-box}
html,body{margin:0;padding:0}
body{
  font-family:Inter,Segoe UI,Arial,sans-serif;
  color:var(--text);
  background:
    radial-gradient(1200px 600px at 10% 0%, #0e2450 0%, transparent 60%),
    linear-gradient(180deg,var(--bg),var(--bg2));
}
a{text-decoration:none;color:inherit}
.shell{min-height:100vh}
.site-header{
  position:sticky;top:0;z-index:60;
  display:flex;align-items:center;justify-content:space-between;
  gap:16px;padding:18px 20px;
  background:rgba(7,17,32,.88);backdrop-filter:blur(14px);
  border-bottom:1px solid rgba(255,255,255,.06)
}
.brand-wrap{display:flex;align-items:center;gap:14px}
.menu-btn,.refresh-btn{
  border:1px solid var(--line);
  background:linear-gradient(180deg,#112246,#0d1a35);
  color:var(--text);
  border-radius:14px;
  padding:10px 14px;
  cursor:pointer;
}
.brand{font-size:clamp(28px,4vw,42px);font-weight:800;letter-spacing:-.02em}
.sub{color:var(--muted);margin-top:4px}
.layout{display:flex;gap:20px;max-width:1400px;margin:0 auto;padding:20px}
.sidebar{
  width:260px;flex:0 0 260px;
  background:rgba(14,27,52,.78);
  border:1px solid var(--line);
  border-radius:24px;padding:18px;box-shadow:var(--shadow);
  height:fit-content;position:sticky;top:96px
}
.menu{display:grid;gap:10px}
.menu a{
  padding:14px 16px;border-radius:16px;
  background:rgba(255,255,255,.02);
  border:1px solid var(--line);
}
.menu a:hover{background:#132446}
.content{flex:1;min-width:0}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:16px}
.card{
  background:linear-gradient(180deg,rgba(17,31,58,.96),rgba(14,26,50,.96));
  border:1px solid var(--line);border-radius:24px;padding:20px;box-shadow:var(--shadow)
}
.section-title{font-size:18px;font-weight:700;margin:0 0 12px}
.kpi{font-size:38px;font-weight:800;margin-top:10px}
.muted{color:var(--muted)}
.badge{display:inline-flex;align-items:center;gap:6px;border-radius:999px;padding:6px 10px;font-size:12px;border:1px solid var(--line);background:#122342}
.badge.green{background:rgba(34,199,147,.12);border-color:rgba(34,199,147,.3);color:#8fe7c7}
.badge.red{background:rgba(255,95,120,.12);border-color:rgba(255,95,120,.3);color:#ffb0bf}
.badge.yellow{background:rgba(255,191,71,.12);border-color:rgba(255,191,71,.3);color:#ffd78d}
.toolbar{display:flex;justify-content:space-between;align-items:center;gap:12px;flex-wrap:wrap;margin-bottom:14px}
input,textarea,button{font:inherit}
input,textarea{
  width:100%;padding:13px 14px;
  color:var(--text);
  background:#091425;border:1px solid var(--line);border-radius:16px;
}
textarea{min-height:180px}
.btn{
  display:inline-flex;align-items:center;justify-content:center;gap:8px;
  border:none;border-radius:14px;padding:11px 16px;cursor:pointer;color:#fff;
  background:var(--blue)
}
.btn.green{background:var(--green)}
.btn.red{background:var(--red)}
.btn.gray{background:#23375e}
.btn.yellow{background:var(--yellow);color:#1c2130}
.flash{padding:13px 16px;border-radius:16px;margin-bottom:14px;background:#12332a;border:1px solid #1d5d4f}
.flash.error{background:#3d1923;border-color:#7f3343}
.table-wrap{overflow:auto;border:1px solid var(--line);border-radius:18px}
table{width:100%;border-collapse:collapse;min-width:900px}
th,td{padding:14px 12px;border-bottom:1px solid rgba(255,255,255,.06);text-align:left;vertical-align:top}
th{color:#b7c8e6;font-size:13px}
td{font-size:14px}
.actions{display:flex;gap:8px;flex-wrap:wrap}
.small{font-size:12px;color:var(--muted)}
.code{
  white-space:pre-wrap;word-break:break-word;
  background:#08111f;border:1px solid var(--line);
  padding:14px;border-radius:16px;overflow:auto
}
.row-stack{display:grid;gap:4px}
.stat-inline{display:flex;gap:10px;flex-wrap:wrap}
.empty{padding:30px 14px;color:var(--muted);text-align:center}
.user-card-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:14px}
.user-mini{display:grid;gap:8px;padding:16px;border:1px solid var(--line);border-radius:18px;background:rgba(255,255,255,.02)}
@media (max-width: 980px){
  .layout{padding:14px}
  .sidebar{
    position:fixed;left:14px;top:88px;bottom:14px;width:min(84vw,320px);
    transform:translateX(-120%);transition:transform .22s ease;z-index:80;overflow:auto
  }
  body.menu-open .sidebar{transform:translateX(0)}
  .content{width:100%}
}
CSS

cat >"$APP_DIR/login.php" <<'PHP'
<?php require __DIR__.'/config.php'; if(!empty($_SESSION['admin_user'])){ header('Location: index.php'); exit; } $err=''; if($_SERVER['REQUEST_METHOD']==='POST'){ if(admin_login(trim($_POST['username'] ?? ''), $_POST['password'] ?? '')){ $_SESSION['admin_user']=trim($_POST['username']); header('Location: index.php'); exit; } $err='Invalid username or password'; } ?>
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>OpenVPN Admin Login</title>
<link rel="stylesheet" href="style.css">
</head>
<body>
<div class="layout" style="max-width:680px;min-height:100vh;align-items:center;justify-content:center">
  <div class="card" style="width:100%">
    <div class="brand">OpenVPN Admin</div>
    <div class="sub">Login with the generated admin account</div>
    <br>
    <?php if($err): ?><div class="flash error"><?=esc($err)?></div><?php endif; ?>
    <form method="post">
      <label>Username</label>
      <input name="username" value="openvpn" required>
      <br><br>
      <label>Password</label>
      <input type="password" name="password" required>
      <br><br>
      <button class="btn" type="submit">Login</button>
    </form>
  </div>
</div>
</body>
</html>
PHP

cat >"$APP_DIR/index.php" <<'PHP'
<?php require __DIR__.'/config.php'; require_login(); $stats=dashboard_stats(); $active=active_clients(); render_header('Dashboard'); ?>
<div class="grid">
  <div class="card"><div class="muted">Total users</div><div class="kpi"><?=$stats['total_users']?></div></div>
  <div class="card"><div class="muted">Active connections</div><div class="kpi"><?=$stats['active_connections']?></div></div>
  <div class="card"><div class="muted">Active users</div><div class="kpi"><?=$stats['active_users']?></div></div>
  <div class="card"><div class="muted">Today connects</div><div class="kpi"><?=$stats['today_connects']?></div></div>
  <div class="card"><div class="muted">Rows with GUI version</div><div class="kpi"><?=$stats['gui_rows']?></div></div>
</div>

<div class="card" style="margin-top:18px">
  <div class="toolbar">
    <div>
      <h2 class="section-title" style="margin-bottom:6px">Active connected devices</h2>
      <div class="small">Refresh the page to update the live device table.</div>
    </div>
    <span class="badge green"><?=$stats['active_connections']?> active now</span>
  </div>
  <div class="table-wrap">
    <table>
      <tr>
        <th>User</th><th>GUI Version</th><th>Real IP</th><th>Virtual IP</th><th>Since</th><th>Download</th><th>Upload</th><th>Action</th>
      </tr>
      <?php if(!$active): ?>
        <tr><td colspan="8" class="empty">No active devices right now. Connect a device and refresh after a few seconds.</td></tr>
      <?php else: foreach($active as $c): $u=($c['username'] ?: $c['common_name']); $isBlocked=(int)db()->querySingle("SELECT blocked FROM users WHERE username='".SQLite3::escapeString($u)."' LIMIT 1"); ?>
        <tr>
          <td><strong><?=esc($u)?></strong></td>
          <td class="small"><?=esc($c['gui_version'] ?: last_gui_for_user($u) ?: '-')?></td>
          <td><?=esc($c['real_address'])?></td>
          <td><?=esc($c['virtual_address'] ?: '-')?></td>
          <td><?=esc($c['connected_since'])?></td>
          <td><?=esc(human_bytes($c['bytes_received'] ?? 0))?></td>
          <td><?=esc(human_bytes($c['bytes_sent'] ?? 0))?></td>
          <td>
            <div class="actions">
              <?php if($isBlocked===1): ?>
                <a class="btn yellow" href="unblock_user.php?u=<?=urlencode($u)?>">Unblock</a>
              <?php else: ?>
                <a class="btn red" href="block_user.php?u=<?=urlencode($u)?>" onclick="return confirm('Block this user?')">Block</a>
              <?php endif; ?>
            </div>
          </td>
        </tr>
      <?php endforeach; endif; ?>
    </table>
  </div>
</div>
<?php render_footer(); ?>
PHP

cat >"$APP_DIR/users.php" <<'PHP'
<?php require __DIR__.'/config.php'; require_login(); $users=users_all(); render_header('Users'); ?>
<div class="card">
  <div class="toolbar">
    <div>
      <h2 class="section-title" style="margin-bottom:6px">All users</h2>
      <div class="small">Only added usernames are shown here.</div>
    </div>
    <span class="badge"><?=count($users)?> users</span>
  </div>
  <div class="table-wrap">
    <table style="min-width:720px">
      <tr>
        <th>Username</th><th>Created</th><th>Actions</th>
      </tr>
      <?php if(!$users): ?>
        <tr><td colspan="3" class="empty">No users found.</td></tr>
      <?php else: foreach($users as $u): ?>
        <tr>
          <td><strong><?=esc($u['username'])?></strong></td>
          <td><?=esc($u['created_at'])?></td>
          <td>
            <div class="actions">
              <a class="btn green" href="download.php?u=<?=urlencode($u['username'])?>">Download</a>
              <a class="btn gray" href="show_config.php?u=<?=urlencode($u['username'])?>">Config</a>
              <a class="btn" href="edit_user.php?id=<?=$u['id']?>">Edit</a>
              <a class="btn red" href="delete_user.php?id=<?=$u['id']?>" onclick="return confirm('Delete this user?')">Delete</a>
            </div>
          </td>
        </tr>
      <?php endforeach; endif; ?>
    </table>
  </div>
</div>
<?php render_footer(); ?>
PHP

cat >"$APP_DIR/new_user.php" <<'PHP'
<?php require __DIR__.'/config.php'; require_login(); $msg=''; $err=''; if($_SERVER['REQUEST_METHOD']==='POST'){ $u=trim($_POST['username']??''); $p=$_POST['password']??''; if($u!=='' && $p!==''){ [$code,$out]=cli('/usr/local/bin/ovpn-user-manage.sh add '.escapeshellarg($u).' '.escapeshellarg($p)); if($code===0){ $msg=$out ?: 'User created'; } else { $err=$out ?: 'Failed'; } } else { $err='Username and password are required'; } } render_header('New User'); ?>
<div class="card">
  <h2 class="section-title">Create user</h2>
  <?php if($msg): ?><div class="flash"><?=esc($msg)?></div><?php endif; ?>
  <?php if($err): ?><div class="flash error"><?=esc($err)?></div><?php endif; ?>
  <form method="post">
    <label>Username</label>
    <input name="username" required>
    <br><br>
    <label>Password</label>
    <input name="password" required>
    <br><br>
    <button class="btn" type="submit">Create user</button>
  </form>
</div>
<?php render_footer(); ?>
PHP

cat >"$APP_DIR/edit_user.php" <<'PHP'
<?php require __DIR__.'/config.php'; require_login(); $id=(int)($_GET['id']??0); $user=user_get($id); if(!$user){ http_response_code(404); exit('User not found'); } $msg=''; $err=''; if($_SERVER['REQUEST_METHOD']==='POST'){ $p=$_POST['password']??''; if($p!==''){ [$code,$out]=cli('/usr/local/bin/ovpn-user-manage.sh update '.escapeshellarg($user['username']).' '.escapeshellarg($p)); if($code===0){ $msg=$out ?: 'User updated'; } else { $err=$out ?: 'Failed'; } } else { $err='Password is required'; } } render_header('Edit User'); ?>
<div class="card">
  <div class="toolbar">
    <div><h2 class="section-title" style="margin-bottom:6px">Edit user</h2><div class="small">Username: <strong><?=esc($user['username'])?></strong></div></div>
    <a class="btn gray" href="users.php">Back to users</a>
  </div>
  <?php if($msg): ?><div class="flash"><?=esc($msg)?></div><?php endif; ?>
  <?php if($err): ?><div class="flash error"><?=esc($err)?></div><?php endif; ?>
  <form method="post">
    <label>New password</label>
    <input name="password" required>
    <br><br>
    <button class="btn" type="submit">Update password</button>
  </form>
</div>
<?php render_footer(); ?>
PHP

cat >"$APP_DIR/delete_user.php" <<'PHP'
<?php require __DIR__.'/config.php'; require_login(); $id=(int)($_GET['id']??0); $u=user_get($id); if($u){ cli('/usr/local/bin/ovpn-user-manage.sh delete '.escapeshellarg($u['username'])); } header('Location: users.php');
PHP

cat >"$APP_DIR/block_user.php" <<'PHP'
<?php require __DIR__.'/config.php'; require_login(); $u=trim($_GET['u'] ?? ''); if($u!==''){ cli('/usr/local/bin/ovpn-user-manage.sh block '.escapeshellarg($u)); } header('Location: '.($_SERVER['HTTP_REFERER'] ?? 'users.php'));
PHP

cat >"$APP_DIR/unblock_user.php" <<'PHP'
<?php require __DIR__.'/config.php'; require_login(); $u=trim($_GET['u'] ?? ''); if($u!==''){ cli('/usr/local/bin/ovpn-user-manage.sh unblock '.escapeshellarg($u)); } header('Location: '.($_SERVER['HTTP_REFERER'] ?? 'users.php'));
PHP

cat >"$APP_DIR/download.php" <<'PHP'
<?php require __DIR__.'/config.php'; require_login(); $u=basename($_GET['u']??''); $p=profile_path($u); if(!is_file($p)){ http_response_code(404); exit('Profile not found'); } header('Content-Type: application/octet-stream'); header('Content-Disposition: attachment; filename="'.$u.'.ovpn"'); readfile($p);
PHP

cat >"$APP_DIR/show_config.php" <<'PHP'
<?php require __DIR__.'/config.php'; require_login(); $u=basename($_GET['u']??''); $p=profile_path($u); if(!is_file($p)){ http_response_code(404); exit('Profile not found'); } $cfg=file_get_contents($p); render_header('Show Config'); ?>
<div class="card">
  <div class="toolbar">
    <div><h2 class="section-title" style="margin-bottom:6px">Config: <?=esc($u)?></h2><div class="small">You can copy this text directly.</div></div>
    <a class="btn gray" href="users.php">Back to users</a>
  </div>
  <div class="code"><?=esc($cfg)?></div>
</div>
<?php render_footer(); ?>
PHP

cat >"$APP_DIR/logs.php" <<'PHP'
<?php
require __DIR__.'/config.php';
require_login();
$q=trim($_GET['q']??'');
$rows=latest_logs(300,$q);
if(isset($_GET['csv'])){
    header('Content-Type:text/csv');
    header('Content-Disposition: attachment; filename="ovpn-connect-logs.csv"');
    $f=fopen('php://output','w');
    fputcsv($f,['time','username','ip','gui_version']);
    foreach($rows as $r){
        fputcsv($f,[$r['event_time'],$r['username'] ?: $r['common_name'],$r['real_ip'],$r['gui_version']]);
    }
    exit;
}
render_header('Connection Logs');
?>
<div class="card">
  <div class="toolbar">
    <div>
      <h2 class="section-title" style="margin-bottom:6px">Connection logs</h2>
      <div class="small">Only connected device logs are shown here.</div>
    </div>
    <a class="btn" href="logs.php?csv=1<?= $q!=='' ? '&q='.urlencode($q) : '' ?>">Export CSV</a>
  </div>
  <form method="get" class="actions" style="margin-bottom:14px">
    <input name="q" placeholder="Search username, IP, GUI version" value="<?=esc($q)?>">
    <button class="btn gray" type="submit">Search</button>
  </form>
  <div class="table-wrap">
    <table style="min-width:760px">
      <tr>
        <th>Time</th><th>User</th><th>IP</th><th>GUI Version</th>
      </tr>
      <?php if(!$rows): ?>
        <tr><td colspan="4" class="empty">No connected logs yet.</td></tr>
      <?php else: foreach($rows as $r): ?>
        <tr>
          <td><?=esc($r['event_time'])?></td>
          <td><?=esc($r['username'] ?: $r['common_name'])?></td>
          <td><?=esc($r['real_ip'])?></td>
          <td class="small"><?=esc($r['gui_version'] ?: '-')?></td>
        </tr>
      <?php endforeach; endif; ?>
    </table>
  </div>
</div>
<?php render_footer(); ?>
PHP

cat >"$APP_DIR/change_password.php" <<'PHP'
<?php require __DIR__.'/config.php'; require_login(); $msg=''; $err=''; if($_SERVER['REQUEST_METHOD']==='POST'){ $cur=$_POST['current_password']??''; $new=$_POST['new_password']??''; if(admin_login($_SESSION['admin_user'],$cur) && $new!==''){ $hash=password_hash($new, PASSWORD_DEFAULT); $st=db()->prepare('UPDATE admins SET password_hash=:h WHERE username=:u'); $st->bindValue(':h',$hash,SQLITE3_TEXT); $st->bindValue(':u',$_SESSION['admin_user'],SQLITE3_TEXT); $st->execute(); $msg='Admin password updated'; } else { $err='Current password is incorrect'; } } render_header('Change Admin Password'); ?>
<div class="card">
  <h2 class="section-title">Change admin password</h2>
  <?php if($msg): ?><div class="flash"><?=esc($msg)?></div><?php endif; ?>
  <?php if($err): ?><div class="flash error"><?=esc($err)?></div><?php endif; ?>
  <form method="post">
    <label>Current password</label>
    <input type="password" name="current_password" required>
    <br><br>
    <label>New password</label>
    <input type="password" name="new_password" required>
    <br><br>
    <button class="btn" type="submit">Update password</button>
  </form>
</div>
<?php render_footer(); ?>
PHP

cat >"$APP_DIR/logout.php" <<'PHP'
<?php require __DIR__.'/config.php'; session_destroy(); header('Location: login.php');
PHP

echo "[11/12] Setting permissions..."
chown -R www-data:www-data "$APP_DIR"
chmod -R 755 "$APP_DIR"
chmod -R 777 "$DOWNLOAD_DIR" "$DATA_DIR"
chmod 644 "$APP_DIR"/*.php "$APP_DIR"/*.css
chmod 666 "$DB_FILE"
# Re-apply PKI permissions after app setup to avoid future permission regressions
chown -R root:www-data "$PKI_DIR"
chmod 750 "$PKI_DIR"
chmod 640 "$PKI_DIR/ta.key" "$PKI_DIR/server.key"
chmod 644 "$PKI_DIR/ca.crt" "$PKI_DIR/server.crt" "$PKI_DIR/dh.pem"

echo "[12/12] Enabling services..."
a2enmod rewrite >/dev/null || true
systemctl daemon-reload
systemctl enable apache2 >/dev/null
systemctl enable ovpn-iptables.service >/dev/null
systemctl enable openvpn-server@server-udp >/dev/null
systemctl enable openvpn-server@server-tcp >/dev/null
systemctl restart apache2
systemctl restart ovpn-iptables.service || true
systemctl restart openvpn-server@server-udp
systemctl restart openvpn-server@server-tcp

echo
echo "Done."
echo "Panel URL: http://${SERVER_ADDR}/ovpn-admin/"
echo "Admin user: ${ADMIN_USER}"
echo "Admin pass: ${ADMIN_PASS}"
echo "Default VPN user: ${DEFAULT_USER}"
echo "Default VPN pass: ${DEFAULT_USER_PASS}"
echo
echo "One username can connect multiple devices at the same time because duplicate-cn is enabled."


echo "[13/16] Installing OpenConnect..."
apt-get update >/dev/null 2>&1 || true
apt-get install -y ocserv gnutls-bin python3 sudo >/dev/null 2>&1 || true

OC_DIR="/etc/ocserv"
OC_SSL_DIR="$OC_DIR/ssl"
OC_PASSFILE="$OC_DIR/ocpasswd"
OC_USERS_CSV="/var/www/html/ovpn-admin/data/oc_users.csv"

mkdir -p "$OC_DIR" "$OC_SSL_DIR"
touch "$OC_PASSFILE"
chmod 600 "$OC_PASSFILE"
chown root:root "$OC_PASSFILE"

openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
  -keyout "$OC_SSL_DIR/server-key.pem" \
  -out "$OC_SSL_DIR/server-cert.pem" \
  -subj "/CN=${SERVER_ADDR}" \
  -addext "subjectAltName=IP:${SERVER_ADDR}" >/dev/null 2>&1 || true
chmod 600 "$OC_SSL_DIR/server-key.pem"
chmod 644 "$OC_SSL_DIR/server-cert.pem"

cat >/etc/ocserv/ocserv.conf <<EOF
auth = "plain[passwd=/etc/ocserv/ocpasswd]"
tcp-port = 4443
udp-port = 4443
run-as-user = nobody
run-as-group = daemon
socket-file = /run/ocserv-socket
server-cert = ${OC_SSL_DIR}/server-cert.pem
server-key = ${OC_SSL_DIR}/server-key.pem
max-clients = 100000
max-same-clients = 0
default-domain = ${SERVER_ADDR}
ipv4-network = 10.20.30.0
ipv4-netmask = 255.255.255.0
dns = 1.1.1.1
dns = 8.8.8.8
tunnel-all-dns = true
route = default
keepalive = 32400
dpd = 90
mobile-dpd = 1800
switch-to-tcp-timeout = 25
try-mtu-discovery = false
compression = false
isolate-workers = true
server-stats-reset-time = 604800
device = vpns
predictable-ips = true
cisco-client-compat = true
dtls-legacy = true
EOF

# ensure firewall/NAT rules for OpenConnect
iptables -t nat -C POSTROUTING -s 10.20.30.0/24 -o ${NET_IFACE} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s 10.20.30.0/24 -o ${NET_IFACE} -j MASQUERADE
iptables -C FORWARD -s 10.20.30.0/24 -j ACCEPT 2>/dev/null || iptables -A FORWARD -s 10.20.30.0/24 -j ACCEPT
iptables -C FORWARD -d 10.20.30.0/24 -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || iptables -A FORWARD -d 10.20.30.0/24 -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -C INPUT -p tcp --dport 4443 -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport 4443 -j ACCEPT
iptables -C INPUT -p udp --dport 4443 -j ACCEPT 2>/dev/null || iptables -A INPUT -p udp --dport 4443 -j ACCEPT

# separate OpenConnect users store (plaintext for panel display, hashed in ocpasswd)
cat >/usr/local/bin/oc-user-manage.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
PASSFILE="/etc/ocserv/ocpasswd"
CSV="/var/www/html/ovpn-admin/data/oc_users.csv"

mkdir -p /etc/ocserv
touch "$PASSFILE"
touch "$CSV"

cmd="${1:-}"
user="${2:-}"
pass="${3:-}"

init_csv() {
  touch "$CSV"
  chmod 664 "$CSV"
  chown root:www-data "$CSV" 2>/dev/null || true
}
ensure_no_header() {
  init_csv
}
upsert_csv() {
  local u="$1" p="$2" blocked="${3:-0}"
  ensure_no_header
  grep -vE "^${u//\./\\.}\|" "$CSV" > "${CSV}.tmp" 2>/dev/null || true
  printf '%s|%s|%s\n' "$u" "$p" "$blocked" >> "${CSV}.tmp"
  mv "${CSV}.tmp" "$CSV"
  chmod 664 "$CSV"
  chown root:www-data "$CSV" 2>/dev/null || true
}
delete_csv() {
  local u="$1"
  ensure_no_header
  grep -vE "^${u//\./\\.}\|" "$CSV" > "${CSV}.tmp" 2>/dev/null || true
  mv "${CSV}.tmp" "$CSV"
  chmod 664 "$CSV"
  chown root:www-data "$CSV" 2>/dev/null || true
}
get_csv_pass() {
  local u="$1"
  awk -F'|' -v U="$u" '$1==U{print $2; exit}' "$CSV" 2>/dev/null || true
}
kill_user() {
  local u="$1"
  if command -v occtl >/dev/null 2>&1; then
    occtl disconnect user "$u" >/dev/null 2>&1 || true
    occtl disconnect id "$u" >/dev/null 2>&1 || true
  fi
}
case "$cmd" in
  add)
    [[ -n "$user" && -n "$pass" ]] || exit 1
    printf '%s\n%s\n' "$pass" "$pass" | ocpasswd -c "$PASSFILE" "$user" >/dev/null
    upsert_csv "$user" "$pass" "0"
    echo "User added: $user"
    ;;
  update)
    [[ -n "$user" && -n "$pass" ]] || exit 1
    printf '%s\n%s\n' "$pass" "$pass" | ocpasswd -c "$PASSFILE" "$user" >/dev/null
    upsert_csv "$user" "$pass" "0"
    echo "User updated: $user"
    ;;
  delete)
    [[ -n "$user" ]] || exit 1
    ocpasswd -c "$PASSFILE" -d "$user" >/dev/null 2>&1 || true
    delete_csv "$user"
    kill_user "$user"
    echo "User deleted: $user"
    ;;
  block)
    [[ -n "$user" ]] || exit 1
    p="$(get_csv_pass "$user")"
    [[ -n "$p" ]] || p="blocked"
    upsert_csv "$user" "$p" "1"
    ocpasswd -c "$PASSFILE" -d "$user" >/dev/null 2>&1 || true
    kill_user "$user"
    echo "User blocked: $user"
    ;;
  unblock)
    [[ -n "$user" ]] || exit 1
    p="$(get_csv_pass "$user")"
    [[ -n "$p" ]] || exit 1
    printf '%s\n%s\n' "$p" "$p" | ocpasswd -c "$PASSFILE" "$user" >/dev/null
    upsert_csv "$user" "$p" "0"
    echo "User unblocked: $user"
    ;;
  *)
    echo "Usage: $0 {add|update|delete|block|unblock} USER [PASS]"
    exit 1
    ;;
esac
EOF
chmod 755 /usr/local/bin/oc-user-manage.sh
chown root:root /usr/local/bin/oc-user-manage.sh

cat >/usr/local/bin/oc-sessions.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if command -v occtl >/dev/null 2>&1; then
  occtl show users 2>/dev/null || true
fi
EOF
chmod 755 /usr/local/bin/oc-sessions.sh
chown root:root /usr/local/bin/oc-sessions.sh

cat >/etc/sudoers.d/ovpn-oc-users <<'EOF'
www-data ALL=(root) NOPASSWD: /usr/local/bin/oc-user-manage.sh
www-data ALL=(root) NOPASSWD: /usr/local/bin/oc-sessions.sh
EOF
chmod 440 /etc/sudoers.d/ovpn-oc-users
visudo -cf /etc/sudoers.d/ovpn-oc-users >/dev/null

# seed default OpenConnect user
/usr/local/bin/oc-user-manage.sh add "${DEFAULT_USER}" "${DEFAULT_USER_PASS}" >/dev/null 2>&1 || true
chown root:www-data "$OC_USERS_CSV" 2>/dev/null || true
chmod 664 "$OC_USERS_CSV" 2>/dev/null || true

python3 - <<'PY'
from pathlib import Path
cfg = Path('/var/www/html/ovpn-admin/config.php')
s = cfg.read_text()
anchor = '<a href="change_password.php">Change Admin Password</a>'
if 'openconnect.php' not in s:
    s = s.replace(anchor, '<a href="openconnect.php">OpenConnect</a>\n      '+anchor)
cfg.write_text(s)
PY

cat >"$APP_DIR/openconnect.php" <<'PHP'
<?php
require __DIR__.'/config.php';
require_login();

function oc_users_csv_path(){ return __DIR__ . '/data/oc_users.csv'; }

function oc_users_all(){
    $rows=[];
    $f=oc_users_csv_path();
    if(!is_file($f)) return $rows;
    foreach(file($f, FILE_IGNORE_NEW_LINES|FILE_SKIP_EMPTY_LINES) as $line){
        $p=explode('|',$line);
        $rows[]=[
            'username'=>$p[0] ?? '',
            'password'=>$p[1] ?? '',
            'blocked'=>(int)($p[2] ?? 0),
        ];
    }
    return $rows;
}
function oc_user_get($u){
    foreach(oc_users_all() as $row){ if($row['username']===$u) return $row; }
    return null;
}
function oc_sessions(){
    $out=shell_exec("sudo /usr/local/bin/oc-sessions.sh 2>/dev/null");
    if(!$out) return [];
    $sessions=[]; $current=[];
    foreach(preg_split("/\r?\n/", trim($out)) as $line){
        $line=trim($line);
        if($line==='') continue;
        if(preg_match('/^id:\s*(.+)$/i',$line,$m)){
            if($current) $sessions[]=$current;
            $current=['id'=>$m[1]];
            continue;
        }
        if(preg_match('/^([A-Za-z0-9 _-]+):\s*(.*)$/',$line,$m)){
            $k=strtolower(str_replace(' ','_',$m[1]));
            $current[$k]=$m[2];
        }
    }
    if($current) $sessions[]=$current;
    return $sessions;
}
$msg=''; $err='';
if($_SERVER['REQUEST_METHOD']==='POST'){
    $action=$_POST['action'] ?? '';
    $u=trim($_POST['username'] ?? '');
    $p=$_POST['password'] ?? '';
    if($action==='add'){
        if($u!=='' && $p!==''){
            [$code,$out]=cli('sudo /usr/local/bin/oc-user-manage.sh add '.escapeshellarg($u).' '.escapeshellarg($p));
            if($code===0){ $msg='User added'; } else { $err=$out ?: 'Failed'; }
        } else $err='Username and password are required';
    } elseif($action==='update'){
        if($u!=='' && $p!==''){
            [$code,$out]=cli('sudo /usr/local/bin/oc-user-manage.sh update '.escapeshellarg($u).' '.escapeshellarg($p));
            if($code===0){ $msg='User updated'; } else { $err=$out ?: 'Failed'; }
        } else $err='Username and password are required';
    }
}
if(isset($_GET['delete'])){
    [$code,$out]=cli('sudo /usr/local/bin/oc-user-manage.sh delete '.escapeshellarg($_GET['delete']));
    header('Location: openconnect.php'); exit;
}
if(isset($_GET['block'])){
    [$code,$out]=cli('sudo /usr/local/bin/oc-user-manage.sh block '.escapeshellarg($_GET['block']));
    header('Location: openconnect.php'); exit;
}
if(isset($_GET['unblock'])){
    [$code,$out]=cli('sudo /usr/local/bin/oc-user-manage.sh unblock '.escapeshellarg($_GET['unblock']));
    header('Location: openconnect.php'); exit;
}
$editUser = isset($_GET['edit']) ? oc_user_get($_GET['edit']) : null;
$users = oc_users_all();
$sessions = oc_sessions();
render_header('OpenConnect');
?>
<div class="grid">
  <div class="card"><div class="muted">OpenConnect max capacity</div><div class="kpi">100000</div></div>
  <div class="card"><div class="muted">OpenConnect active now</div><div class="kpi"><?=count($sessions)?></div></div>
  <div class="card"><div class="muted">OpenConnect total users</div><div class="kpi"><?=count($users)?></div></div>
</div>

<div class="card" style="margin-top:18px">
  <h2 class="section-title">OpenConnect users</h2>
  <div class="small">এই page-এর username/password দিয়েই OpenConnect login হবে।</div>
  <br>
  <?php if($msg): ?><div class="flash"><?=esc($msg)?></div><?php endif; ?>
  <?php if($err): ?><div class="flash error"><?=esc($err)?></div><?php endif; ?>

  <form method="post" class="toolbar">
    <input type="hidden" name="action" value="<?= $editUser ? 'update' : 'add' ?>">
    <div style="flex:1;min-width:180px">
      <label>Username</label>
      <input name="username" value="<?=esc($editUser['username'] ?? '')?>" <?= $editUser ? 'readonly' : '' ?> required>
    </div>
    <div style="flex:1;min-width:180px">
      <label>Password</label>
      <input name="password" value="<?=esc($editUser['password'] ?? '')?>" required>
    </div>
    <div style="padding-top:24px">
      <button class="btn" type="submit"><?= $editUser ? 'Update' : 'Add' ?></button>
    </div>
    <?php if($editUser): ?>
      <div style="padding-top:24px"><a class="btn gray" href="openconnect.php">Cancel</a></div>
    <?php endif; ?>
  </form>

  <div class="table-wrap" style="margin-top:14px">
    <table style="min-width:860px">
      <tr><th>Username</th><th>Password</th><th>Status</th><th>Actions</th></tr>
      <?php if(!$users): ?>
        <tr><td colspan="4" class="empty">No OpenConnect users yet.</td></tr>
      <?php else: foreach($users as $u): ?>
        <tr>
          <td><strong><?=esc($u['username'])?></strong></td>
          <td><?=esc($u['password'])?></td>
          <td>
            <?php if((int)$u['blocked']===1): ?>
              <span class="badge red">Blocked</span>
            <?php else: ?>
              <span class="badge green">Active</span>
            <?php endif; ?>
          </td>
          <td>
            <div class="actions">
              <a class="btn" href="openconnect.php?edit=<?=urlencode($u['username'])?>">Edit</a>
              <?php if((int)$u['blocked']===1): ?>
                <a class="btn yellow" href="openconnect.php?unblock=<?=urlencode($u['username'])?>">Unblock</a>
              <?php else: ?>
                <a class="btn red" href="openconnect.php?block=<?=urlencode($u['username'])?>">Block</a>
              <?php endif; ?>
              <a class="btn gray" href="openconnect.php?delete=<?=urlencode($u['username'])?>" onclick="return confirm('Delete this OpenConnect user?')">Delete</a>
            </div>
          </td>
        </tr>
      <?php endforeach; endif; ?>
    </table>
  </div>
</div>

<div class="card" style="margin-top:18px">
  <div class="toolbar">
    <div>
      <h2 class="section-title" style="margin-bottom:6px">OpenConnect active sessions</h2>
      <div class="small">Connected OpenConnect users are shown here.</div>
    </div>
    <span class="badge green"><?=count($sessions)?> active</span>
  </div>
  <div class="table-wrap">
    <table style="min-width:860px">
      <tr><th>User</th><th>IP</th><th>VPN IP</th><th>Connected</th><th>Agent</th></tr>
      <?php if(!$sessions): ?>
        <tr><td colspan="5" class="empty">No active OpenConnect sessions.</td></tr>
      <?php else: foreach($sessions as $s): ?>
        <tr>
          <td><?=esc($s['username'] ?? $s['user'] ?? '-')?></td>
          <td><?=esc($s['ip'] ?? $s['remote_ip'] ?? '-')?></td>
          <td><?=esc($s['device_ip'] ?? $s['vpn_ip'] ?? '-')?></td>
          <td><?=esc($s['conn_time'] ?? $s['connected_at'] ?? '-')?></td>
          <td class="small"><?=esc($s['user_agent'] ?? $s['device'] ?? '-')?></td>
        </tr>
      <?php endforeach; endif; ?>
    </table>
  </div>
  <div class="small" style="margin-top:12px">OpenConnect URL: https://<?=esc($_SERVER['SERVER_ADDR'] ?: $_SERVER['SERVER_NAME'])?>:4443</div>
</div>
<?php render_footer(); ?>
PHP

echo "[14/16] Enabling OpenConnect..."
systemctl enable ocserv >/dev/null 2>&1 || true
systemctl restart ocserv || true

echo "[15/16] Restarting web panel..."
systemctl restart apache2 || true

echo "[16/16] Finalizing..."

echo
echo "CLI commands:"
echo "  /usr/local/bin/ovpn-user-manage.sh add USER PASS"
echo "  /usr/local/bin/ovpn-user-manage.sh update USER PASS"
echo "  /usr/local/bin/ovpn-user-manage.sh block USER"
echo "  /usr/local/bin/ovpn-user-manage.sh unblock USER"
echo "  /usr/local/bin/ovpn-user-manage.sh delete USER"
echo
echo "OpenConnect separate users:"
echo "  sudo /usr/local/bin/oc-user-manage.sh add USER PASS"
echo "  sudo /usr/local/bin/oc-user-manage.sh update USER PASS"
echo "  sudo /usr/local/bin/oc-user-manage.sh block USER"
echo "  sudo /usr/local/bin/oc-user-manage.sh unblock USER"
echo "  sudo /usr/local/bin/oc-user-manage.sh delete USER"
