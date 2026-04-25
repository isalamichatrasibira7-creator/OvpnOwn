#!/bin/bash
# FINAL FULL VPN SCRIPT (ALL-IN-ONE READY)

set -e

echo "Starting FULL VPN INSTALL..."

# DOMAIN
DOMAIN_FILE=/etc/vpn.env
if [ -f $DOMAIN_FILE ]; then
  source $DOMAIN_FILE
else
  DOMAIN_NAME="mustakimshop.online"
  echo "DOMAIN_NAME=$DOMAIN_NAME" > $DOMAIN_FILE
fi

OC_HOST="oc.$DOMAIN_NAME"
V2_HOST="v2.$DOMAIN_NAME"

apt update -y
apt install -y curl wget unzip apache2 php haproxy ocserv uuid-runtime dos2unix

# OPENCONNECT
cat > /etc/ocserv/ocserv.conf <<EOF
tcp-port = 4443
udp-port = 4443
auth = "plain[/etc/ocserv/ocpasswd]"
server-cert = /etc/ssl/certs/ssl-cert-snakeoil.pem
server-key = /etc/ssl/private/ssl-cert-snakeoil.key
occtl-socket-file = /run/occtl.socket
EOF

systemctl restart ocserv
systemctl enable ocserv

# XRAY
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

UUID=$(uuidgen)

mkdir -p /var/log/xray

cat > /usr/local/etc/xray/config.json <<EOF
{
 "log":{"access":"/var/log/xray/access.log","error":"/var/log/xray/error.log","loglevel":"info"},
 "inbounds":[{"port":8444,"listen":"127.0.0.1","protocol":"vless","settings":{"clients":[{"id":"$UUID"}],"decryption":"none"}}],
 "outbounds":[{"protocol":"freedom"}]
}
EOF

systemctl restart xray
systemctl enable xray

# HAPROXY
cat > /etc/haproxy/haproxy.cfg <<EOF
frontend vpn443
 bind *:443
 mode tcp
 tcp-request inspect-delay 5s
 tcp-request content accept if { req.ssl_hello_type 1 }

 use_backend oc if { req.ssl_sni -i $OC_HOST }
 use_backend v2 if { req.ssl_sni -i $V2_HOST }

backend oc
 server oc 127.0.0.1:4443

backend v2
 server v2 127.0.0.1:8444
EOF

systemctl restart haproxy
systemctl enable haproxy

# PANEL
mkdir -p /var/www/html/panel

cat > /var/www/html/panel/index.php <<'PHP'
<?php
$domain = trim(shell_exec("grep DOMAIN_NAME /etc/vpn.env | cut -d '=' -f2"));
echo "<h2>VPN PANEL</h2>";
echo "OpenConnect: https://oc.$domain:443<br>";
echo "Xray: v2.$domain:443<br>";
echo "<br><a href='settings.php'>Change Domain</a>";
?>
PHP

cat > /var/www/html/panel/settings.php <<'PHP'
<?php
if($_POST){
 file_put_contents("/etc/vpn.env","DOMAIN_NAME=".$_POST['domain']);
 shell_exec("systemctl restart ocserv haproxy xray apache2");
 echo "Updated!";
}
?>
<form method=post>
<input name=domain placeholder=newdomain.com>
<button>Save</button>
</form>
PHP

systemctl restart apache2

echo "INSTALL COMPLETE"
echo "OpenConnect: https://$OC_HOST:443"
echo "Xray: $V2_HOST:443"
echo "UUID: $UUID"
