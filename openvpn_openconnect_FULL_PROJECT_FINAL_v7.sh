#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run as root"
  exit 1
fi

BASE_URL="https://raw.githubusercontent.com/isalamichatrasibira7-creator/OvpnOwn/main/openvpn_openconnect_FULL_PROJECT_FINAL_v6.sh"
TMP_BASE="/tmp/ovpn_oc_base_v6.sh"

export DEBIAN_FRONTEND=noninteractive

echo "[1/6] Running base full installer v6..."
curl -fsSL "$BASE_URL" -o "$TMP_BASE"
bash "$TMP_BASE"

APP_DIR="/var/www/html/ovpn-admin"
DATA_DIR="$APP_DIR/data"
mkdir -p "$DATA_DIR"

apt-get update -y >/dev/null 2>&1 || true
apt-get install -y sqlite3 python3 sudo >/dev/null 2>&1 || true

echo "[2/6] Fixing OpenConnect separate users storage..."
touch "$DATA_DIR/oc_users.csv"
chmod 664 "$DATA_DIR/oc_users.csv"
chown root:www-data "$DATA_DIR/oc_users.csv" || true
if ! grep -q '^Easin,' "$DATA_DIR/oc_users.csv" 2>/dev/null; then
  printf 'Easin,Easin112233@\n' >> "$DATA_DIR/oc_users.csv"
fi

cat >/usr/local/bin/oc-user-manage.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
PASSFILE="/etc/ocserv/ocpasswd"
CSV="/var/www/html/ovpn-admin/data/oc_users.csv"
mkdir -p "$(dirname "$CSV")"
touch "$CSV"
chmod 664 "$CSV"
chown root:www-data "$CSV" 2>/dev/null || true
cmd="${1:-}"
user="${2:-}"
pass="${3:-}"
case "$cmd" in
  add)
    [[ -n "$user" && -n "$pass" ]] || exit 1
    printf '%s\n%s\n' "$pass" "$pass" | ocpasswd -c "$PASSFILE" "$user" >/dev/null
    grep -v "^${user}," "$CSV" > "${CSV}.tmp" 2>/dev/null || true
    mv "${CSV}.tmp" "$CSV" 2>/dev/null || true
    printf '%s,%s\n' "$user" "$pass" >> "$CSV"
    ;;
  update)
    [[ -n "$user" && -n "$pass" ]] || exit 1
    printf '%s\n%s\n' "$pass" "$pass" | ocpasswd -c "$PASSFILE" "$user" >/dev/null
    grep -v "^${user}," "$CSV" > "${CSV}.tmp" 2>/dev/null || true
    mv "${CSV}.tmp" "$CSV" 2>/dev/null || true
    printf '%s,%s\n' "$user" "$pass" >> "$CSV"
    ;;
  delete)
    [[ -n "$user" ]] || exit 1
    ocpasswd -c "$PASSFILE" -d "$user" >/dev/null || true
    grep -v "^${user}," "$CSV" > "${CSV}.tmp" 2>/dev/null || true
    mv "${CSV}.tmp" "$CSV" 2>/dev/null || true
    ;;
  *)
    exit 1
    ;;
esac
SH
chmod 755 /usr/local/bin/oc-user-manage.sh
chown root:root /usr/local/bin/oc-user-manage.sh

cat >/etc/sudoers.d/ovpn-oc-users <<'SH'
www-data ALL=(root) NOPASSWD: /usr/local/bin/oc-user-manage.sh
SH
chmod 440 /etc/sudoers.d/ovpn-oc-users
visudo -cf /etc/sudoers.d/ovpn-oc-users >/dev/null

echo "[3/6] Preparing OpenConnect event database..."
sqlite3 "$DATA_DIR/oc_events.sqlite" <<'SQL'
CREATE TABLE IF NOT EXISTS oc_events(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  event_time TEXT DEFAULT CURRENT_TIMESTAMP,
  event_type TEXT,
  username TEXT,
  real_ip TEXT,
  vpn_ip TEXT,
  user_agent TEXT,
  duration INTEGER DEFAULT 0,
  bytes_in INTEGER DEFAULT 0,
  bytes_out INTEGER DEFAULT 0
);
SQL
chown www-data:www-data "$DATA_DIR/oc_events.sqlite" || true
chmod 664 "$DATA_DIR/oc_events.sqlite" || true

cat >/usr/local/bin/oc-event-log.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
DB="/var/www/html/ovpn-admin/data/oc_events.sqlite"
TYPE="${REASON:-connect}"
USER="${USERNAME:-${USER:-}}"
REAL_IP="${IP_REAL:-}"
VPN_IP="${IP_REMOTE:-}"
AGENT="${DEVICE:-${USER_AGENT:-}}"
DUR="${STATS_DURATION:-0}"
BIN="${STATS_BYTES_IN:-0}"
BOUT="${STATS_BYTES_OUT:-0}"
sqlite3 "$DB" <<SQL
INSERT INTO oc_events(event_type,username,real_ip,vpn_ip,user_agent,duration,bytes_in,bytes_out)
VALUES('$TYPE','${USER//\'/''}','${REAL_IP//\'/''}','${VPN_IP//\'/''}','${AGENT//\'/''}',${DUR:-0},${BIN:-0},${BOUT:-0});
SQL
SH
chmod 755 /usr/local/bin/oc-event-log.sh
chown root:root /usr/local/bin/oc-event-log.sh

if [[ -f /etc/ocserv/ocserv.conf ]]; then
  grep -q '^connect-script = /usr/local/bin/oc-event-log.sh' /etc/ocserv/ocserv.conf || echo 'connect-script = /usr/local/bin/oc-event-log.sh' >> /etc/ocserv/ocserv.conf
  grep -q '^disconnect-script = /usr/local/bin/oc-event-log.sh' /etc/ocserv/ocserv.conf || echo 'disconnect-script = /usr/local/bin/oc-event-log.sh' >> /etc/ocserv/ocserv.conf
fi

echo "[4/6] Rebuilding OpenConnect page with verified counters..."
cat > "$APP_DIR/openconnect.php" <<'PHP'
<?php
require __DIR__.'/config.php';
require_login();

function oc_users_csv_path(){ return __DIR__ . '/data/oc_users.csv'; }
function oc_read_users(){
    $f = oc_users_csv_path();
    $rows = [];
    if (!is_file($f) || !is_readable($f)) return $rows;
    $lines = file($f, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
    foreach($lines as $line){
        $parts = str_getcsv($line);
        if(count($parts) >= 2){
            $rows[] = ['username'=>$parts[0], 'password'=>$parts[1]];
        }
    }
    return $rows;
}
function oc_logs($limit=100){
    $db = new SQLite3(__DIR__.'/data/oc_events.sqlite');
    $db->busyTimeout(3000);
    $res = $db->query('SELECT * FROM oc_events ORDER BY id DESC LIMIT '.(int)$limit);
    $rows = [];
    while($row = $res->fetchArray(SQLITE3_ASSOC)) $rows[] = $row;
    return $rows;
}
function oc_active_sessions(){
    $db = new SQLite3(__DIR__.'/data/oc_events.sqlite');
    $db->busyTimeout(3000);
    $sql = "SELECT e1.* FROM oc_events e1 INNER JOIN (SELECT username, MAX(id) AS max_id FROM oc_events WHERE COALESCE(username,'')<>'' GROUP BY username) latest ON latest.max_id=e1.id WHERE e1.event_type='connect' ORDER BY e1.id DESC";
    $res = $db->query($sql);
    $rows = [];
    while($row = $res->fetchArray(SQLITE3_ASSOC)) $rows[] = $row;
    return $rows;
}
$msg=''; $err='';
if ($_SERVER['REQUEST_METHOD']==='POST' && isset($_POST['add_user'])) {
    $u = trim($_POST['username'] ?? '');
    $p = trim($_POST['password'] ?? '');
    if ($u === '' || $p === '') {
        $err = 'Username and password required';
    } else {
        exec('sudo /usr/local/bin/oc-user-manage.sh add '.escapeshellarg($u).' '.escapeshellarg($p).' 2>&1', $out, $code);
        if ($code === 0) $msg = 'User added';
        else $err = trim(implode("\n", $out)) ?: 'Failed';
    }
}
if (isset($_GET['delete']) && $_GET['delete'] !== '') {
    $u = trim($_GET['delete']);
    exec('sudo /usr/local/bin/oc-user-manage.sh delete '.escapeshellarg($u).' 2>&1', $out, $code);
    header('Location: openconnect.php');
    exit;
}
$users = oc_read_users();
$logs = oc_logs(50);
$sessions = oc_active_sessions();
$active = count($sessions);
$todayConnects = 0;
foreach($logs as $r){ if(($r['event_type'] ?? '') === 'connect' && substr($r['event_time'],0,10) === gmdate('Y-m-d')) $todayConnects++; }
render_header('OpenConnect');
?>
<div class="grid">
  <div class="card"><div class="muted">OpenConnect max capacity</div><div class="kpi">100000</div></div>
  <div class="card"><div class="muted">OpenConnect active now</div><div class="kpi"><?=esc($active)?></div></div>
  <div class="card"><div class="muted">OpenConnect total users</div><div class="kpi"><?=esc(count($users))?></div></div>
  <div class="card"><div class="muted">Today connected</div><div class="kpi"><?=esc($todayConnects)?></div></div>
</div>

<div class="card" style="margin-top:18px">
  <h2 class="section-title">OpenConnect users</h2>
  <div class="small">এই page-এর username/password দিয়েই OpenConnect login হবে।</div>
  <br>
  <?php if($msg): ?><div class="flash"><?=esc($msg)?></div><?php endif; ?>
  <?php if($err): ?><div class="flash error"><?=esc($err)?></div><?php endif; ?>
  <form method="post" class="actions" style="margin-bottom:14px">
    <input name="username" placeholder="Username" required>
    <input name="password" placeholder="Password" required>
    <button class="btn" name="add_user" value="1" type="submit">Add</button>
  </form>
  <div class="table-wrap">
    <table style="min-width:700px">
      <tr><th>Username</th><th>Password</th><th>Action</th></tr>
      <?php if(!$users): ?>
        <tr><td colspan="3" class="empty">No OpenConnect users yet.</td></tr>
      <?php else: foreach($users as $u): ?>
        <tr>
          <td><strong><?=esc($u['username'])?></strong></td>
          <td><?=esc($u['password'])?></td>
          <td><a class="btn red" href="?delete=<?=urlencode($u['username'])?>" onclick="return confirm('Delete this user?')">Delete</a></td>
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
    <span class="badge green"><?=esc($active)?> active</span>
  </div>
  <div class="table-wrap">
    <table style="min-width:900px">
      <tr><th>User</th><th>IP</th><th>VPN IP</th><th>Connected</th></tr>
      <?php if(!$sessions): ?>
        <tr><td colspan="4" class="empty">No active OpenConnect sessions.</td></tr>
      <?php else: foreach($sessions as $s): ?>
        <tr>
          <td><?=esc($s['username'])?></td>
          <td><?=esc($s['real_ip'])?></td>
          <td><?=esc($s['vpn_ip'])?></td>
          <td><?=esc($s['event_time'])?></td>
        </tr>
      <?php endforeach; endif; ?>
    </table>
  </div>
  <div class="small" style="margin-top:12px">OpenConnect URL: https://<?=esc($_SERVER['SERVER_ADDR'] ?: $_SERVER['SERVER_NAME'])?>:4443</div>
</div>

<div class="card" style="margin-top:18px">
  <h2 class="section-title">OpenConnect logs</h2>
  <div class="table-wrap">
    <table style="min-width:900px">
      <tr><th>Time</th><th>Event</th><th>User</th><th>IP</th><th>VPN IP</th></tr>
      <?php if(!$logs): ?>
        <tr><td colspan="5" class="empty">No OpenConnect logs yet.</td></tr>
      <?php else: foreach($logs as $r): ?>
        <tr>
          <td><?=esc($r['event_time'])?></td>
          <td><?=esc($r['event_type'])?></td>
          <td><?=esc($r['username'])?></td>
          <td><?=esc($r['real_ip'])?></td>
          <td><?=esc($r['vpn_ip'])?></td>
        </tr>
      <?php endforeach; endif; ?>
    </table>
  </div>
</div>
<?php render_footer(); ?>
PHP

echo "[5/6] Restarting services..."
systemctl restart ocserv || true
systemctl restart apache2 || true

echo "[6/6] Done."
echo "OpenConnect page now uses log-based active sessions and counters."
echo "Refresh: http://YOUR-IP/ovpn-admin/openconnect.php"
