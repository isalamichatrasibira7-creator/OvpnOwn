#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run as root"
  exit 1
fi

APP_DIR="/var/www/html/ovpn-admin"
DATA_DIR="$APP_DIR/data"
PHP_PAGE="$APP_DIR/openconnect.php"
OC_SOCKET="/run/ocserv-socket"
OC_HELPER="/usr/local/bin/oc-sessions.sh"
SUDOERS="/etc/sudoers.d/ovpn-occtl"
OC_LOG_DB="$DATA_DIR/oc_events.sqlite"

mkdir -p "$DATA_DIR"

cat >"$OC_HELPER" <<'EOH'
#!/usr/bin/env bash
set -euo pipefail
SOCK="/run/ocserv-socket"

if [[ ! -S "$SOCK" ]]; then
  echo '{"sessions":[],"active":0,"error":"socket not found"}'
  exit 0
fi

if occtl -n --json show users >/tmp/occtl.json 2>/dev/null; then
  cat /tmp/occtl.json
  rm -f /tmp/occtl.json
  exit 0
fi

if occtl -n -s "$SOCK" --json show users >/tmp/occtl.json 2>/dev/null; then
  cat /tmp/occtl.json
  rm -f /tmp/occtl.json
  exit 0
fi

OUT="$(occtl -n show users 2>/dev/null || occtl -n -s "$SOCK" show users 2>/dev/null || true)"
OUT="$OUT" python3 - <<'PY'
import json, os, re
text = os.environ.get("OUT","")
sessions = []
cur = None
for raw in text.splitlines():
    line = raw.strip()
    if not line:
        continue
    m = re.match(r'^id:\s*(.+)$', line, re.I)
    if m:
        if cur:
            sessions.append(cur)
        cur = {"id": m.group(1)}
        continue
    m = re.match(r'^([A-Za-z0-9 _/-]+):\s*(.*)$', line)
    if m and cur is not None:
        key = m.group(1).strip().lower().replace(' ', '_').replace('-', '_').replace('/', '_')
        cur[key] = m.group(2).strip()
if cur:
    sessions.append(cur)
print(json.dumps({"sessions": sessions, "active": len(sessions)}, ensure_ascii=False))
PY
EOH
chmod 755 "$OC_HELPER"
chown root:root "$OC_HELPER"

cat >"$SUDOERS" <<EOF2
www-data ALL=(root) NOPASSWD: $OC_HELPER
EOF2
chmod 440 "$SUDOERS"
visudo -cf "$SUDOERS" >/dev/null

sqlite3 "$OC_LOG_DB" <<'SQL'
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
chown www-data:www-data "$OC_LOG_DB"
chmod 664 "$OC_LOG_DB"

cat >/usr/local/bin/oc-event-log.sh <<'EOE'
#!/usr/bin/env bash
set -euo pipefail
DB="/var/www/html/ovpn-admin/data/oc_events.sqlite"
TYPE="${REASON:-connect}"
USER="${USERNAME:-${USER:-}}"
REAL_IP="${IP_REAL:-}"
VPN_IP="${IP_REMOTE:-}"
AGENT="${USER_AGENT:-${DEVICE_TYPE:-}}"
DUR="${STATS_DURATION:-0}"
BIN="${STATS_BYTES_IN:-0}"
BOUT="${STATS_BYTES_OUT:-0}"

sqlite3 "$DB" <<SQL
INSERT INTO oc_events(event_type,username,real_ip,vpn_ip,user_agent,duration,bytes_in,bytes_out)
VALUES('$TYPE','${USER//\'/''}','${REAL_IP//\'/''}','${VPN_IP//\'/''}','${AGENT//\'/''}',${DUR:-0},${BIN:-0},${BOUT:-0});
SQL
EOE
chmod 755 /usr/local/bin/oc-event-log.sh
chown root:root /usr/local/bin/oc-event-log.sh

if [[ -f /etc/ocserv/ocserv.conf ]]; then
  grep -q '^socket-file' /etc/ocserv/ocserv.conf || echo "socket-file = /run/ocserv-socket" >> /etc/ocserv/ocserv.conf
  grep -q '^connect-script' /etc/ocserv/ocserv.conf || echo "connect-script = /usr/local/bin/oc-event-log.sh" >> /etc/ocserv/ocserv.conf
  grep -q '^disconnect-script' /etc/ocserv/ocserv.conf || echo "disconnect-script = /usr/local/bin/oc-event-log.sh" >> /etc/ocserv/ocserv.conf
fi

cat >"$PHP_PAGE" <<'EOP'
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

function oc_sessions_payload(){
    $raw = shell_exec('sudo /usr/local/bin/oc-sessions.sh 2>/dev/null');
    $arr = json_decode((string)$raw, true);
    if (!is_array($arr)) return ['active'=>0,'sessions'=>[],'error'=>'invalid json'];
    if (isset($arr['sessions']) && is_array($arr['sessions'])) return $arr;
    if (array_keys($arr) === range(0, count($arr)-1)) return ['active'=>count($arr),'sessions'=>$arr];
    return ['active'=>0,'sessions'=>[],'error'=>'unexpected payload'];
}

function oc_logs($limit=100){
    $db = new SQLite3(__DIR__.'/data/oc_events.sqlite');
    $db->busyTimeout(3000);
    $res = $db->query('SELECT * FROM oc_events ORDER BY id DESC LIMIT '.(int)$limit);
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
        $cmd = 'sudo /usr/local/bin/oc-user-manage.sh add '.escapeshellarg($u).' '.escapeshellarg($p).' 2>&1';
        exec($cmd, $out, $code);
        if ($code === 0) {
            $msg = 'User added';
        } else {
            $err = trim(implode("\n",$out)) ?: 'Failed';
        }
    }
}

if (isset($_GET['delete']) && $_GET['delete'] !== '') {
    $u = trim($_GET['delete']);
    exec('sudo /usr/local/bin/oc-user-manage.sh delete '.escapeshellarg($u).' 2>&1', $out, $code);
    header('Location: openconnect.php');
    exit;
}

$users = oc_read_users();
$payload = oc_sessions_payload();
$sessions = $payload['sessions'] ?? [];
$active = (int)($payload['active'] ?? count($sessions));
$logs = oc_logs(50);

render_header('OpenConnect');
?>
<div class="grid">
  <div class="card"><div class="muted">OpenConnect max capacity</div><div class="kpi">100000</div></div>
  <div class="card"><div class="muted">OpenConnect active now</div><div class="kpi"><?=esc($active)?></div></div>
  <div class="card"><div class="muted">OpenConnect total users</div><div class="kpi"><?=esc(count($users))?></div></div>
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
      <tr><th>User</th><th>IP</th><th>VPN IP</th><th>Connected</th><th>Agent</th></tr>
      <?php if(!$sessions): ?>
        <tr><td colspan="5" class="empty">No active OpenConnect sessions.</td></tr>
      <?php else: foreach($sessions as $s):
        $user = $s['username'] ?? $s['user'] ?? $s['name'] ?? '-';
        $ip = $s['ip'] ?? $s['remote_ip'] ?? $s['ip_real'] ?? '-';
        $vpn = $s['device_ip'] ?? $s['vpn_ip'] ?? $s['ip_remote'] ?? '-';
        $conn = $s['conn_time'] ?? $s['connected_at'] ?? $s['since'] ?? '-';
        $agent = $s['user_agent'] ?? $s['device'] ?? $s['agent'] ?? '-';
      ?>
        <tr>
          <td><?=esc($user)?></td>
          <td><?=esc($ip)?></td>
          <td><?=esc($vpn)?></td>
          <td><?=esc($conn)?></td>
          <td class="small"><?=esc($agent)?></td>
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
      <tr><th>Time</th><th>Event</th><th>User</th><th>IP</th><th>VPN IP</th><th>Agent</th></tr>
      <?php if(!$logs): ?>
        <tr><td colspan="6" class="empty">No OpenConnect logs yet.</td></tr>
      <?php else: foreach($logs as $r): ?>
        <tr>
          <td><?=esc($r['event_time'])?></td>
          <td><?=esc($r['event_type'])?></td>
          <td><?=esc($r['username'])?></td>
          <td><?=esc($r['real_ip'])?></td>
          <td><?=esc($r['vpn_ip'])?></td>
          <td class="small"><?=esc($r['user_agent'])?></td>
        </tr>
      <?php endforeach; endif; ?>
    </table>
  </div>
</div>
<?php render_footer(); ?>
EOP

systemctl restart ocserv || true
systemctl restart apache2 || true

echo "Patched OpenConnect sessions page."
echo "Now refresh: http://YOUR-IP/ovpn-admin/openconnect.php"
