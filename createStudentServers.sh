#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

CSV_FILE="students.csv"
BASE_CONTAINER_ID=130
NEXT_ID=200
RESOURCE_POOL="WSProg"
STORAGE="local-lvm"
DRY_RUN=false
DNS_TIMEOUT=900

[[ -f "$CSV_FILE" ]] || { echo "❌ CSV file '$CSV_FILE' not found"; exit 1; }

exec > >(tee -a deploy.log) 2>&1

# Parse command-line arguments
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
  echo "🧪 Dry-run mode: No changes will be made."
fi

# Load environment variables from .env file
if [[ -f .env ]]; then
  source .env
else
  echo "❌ .env file not found!"
  exit 1
fi

# Required variables
if [[ -z "${MIKROTIK_HOST:-}" || -z "${MIKROTIK_USER:-}" || -z "${MIKROTIK_PASS:-}" ]]; then
  echo "❌ Missing MikroTik credentials or host in .env file"
  exit 1
fi

# Check if the resource pool exists
if ! pvesh get /pools --output-format=json | jq -e ".[] | select(.poolid==\"$RESOURCE_POOL\")" >/dev/null; then
  echo "Creating resource pool '$RESOURCE_POOL'..."
  $DRY_RUN || pvesh create /pools --poolid "$RESOURCE_POOL"
else
  echo "Resource pool '$RESOURCE_POOL' already exists."
fi

while IFS=',' read -r CLASS LASTNAME FIRSTNAME <&3; do
  # Skip empty or header lines
  [[ -z "$CLASS" || "$CLASS" == "CLASS" ]] && continue

  # Strip Windows carriage returns
  CLASS="${CLASS//$'\r'/}"
  LASTNAME="${LASTNAME//$'\r'/}"
  FIRSTNAME="${FIRSTNAME//$'\r'/}"

  # Build a valid hostname
  RAW_HOSTNAME="${CLASS}-${FIRSTNAME// /_}-${LASTNAME// /_}"
  RAW_HOSTNAME=$(echo "$RAW_HOSTNAME" | tr '[:upper:]' '[:lower:]')
  HOSTNAME=$(echo "$RAW_HOSTNAME" | iconv -f utf8 -t ascii//translit | sed 's/[^a-z0-9-]//g')

  # Clone the template for each student VM
  if $DRY_RUN; then
    echo "📦 Preparing container $NEXT_ID: $CLASS, $FIRSTNAME $LASTNAME → $HOSTNAME"
    echo "  🔸 Would clone $BASE_CONTAINER_ID to $NEXT_ID with hostname $HOSTNAME"
  else
    pct clone "$BASE_CONTAINER_ID" "$NEXT_ID" --hostname "$HOSTNAME" --pool "$RESOURCE_POOL" >/dev/null 2>&1
    pct start "$NEXT_ID" >/dev/null 2>&1
    # used to sleep here before doing the loop below
  fi

  # Get the IP and MAC information of each student VM
  if ! $DRY_RUN; then
    for i in {1..12}; do
      if pct exec "$NEXT_ID" ip addr show eth0 | grep -q 'inet '; then break; fi
      echo "sleeping some more"
      sleep 5
    done
    IP=$(pct exec "$NEXT_ID" ip addr show eth0 | awk '/inet / {print $2}' | cut -d/ -f1)
    MAC=$(pct exec "$NEXT_ID" cat /sys/class/net/eth0/address)
    LAST_OCTET=$(echo "$IP" | awk -F. '{print $4}')
    SSH_PORT=$((62000 + LAST_OCTET))
  else
    IP="10.80.X.X"
    MAC="XX:XX:XX:XX:XX:XX"
    SSH_PORT="62XXX"
  fi

  # Make DHCP leases static and configure port forwarding on mikroTik Router
  if [[ -z "$IP" || -z "$MAC" ]]; then
    echo "⚠️  Failed to get IP/MAC for container $NEXT_ID ($HOSTNAME)"
    echo "  $HOSTNAME → IP: $IP, MAC: $MAC, SSH port: $SSH_PORT"
  else
    
    
    if $DRY_RUN; then
      echo "  🔸 Would assign DHCP static lease on MikroTik"
      echo "  🔸 Would add port forward for SSH on MikroTik $SSH_PORT -> 22"
    else
      echo "  ✅ $HOSTNAME → IP: $IP, MAC: $MAC, SSH port: $SSH_PORT"
      sshpass -p "$MIKROTIK_PASS" ssh -o StrictHostKeyChecking=no "$MIKROTIK_USER@$MIKROTIK_HOST" \
        "/ip dhcp-server lease add address=$IP mac-address=$MAC server=$MIKROTIK_DHCP_SERVER comment=\"Created by script $HOSTNAME\" disabled=no"

      sshpass -p "$MIKROTIK_PASS" ssh -o StrictHostKeyChecking=no "$MIKROTIK_USER@$MIKROTIK_HOST" \
        "/ip firewall nat add chain=dstnat dst-port=$SSH_PORT protocol=tcp action=dst-nat to-addresses=$IP to-ports=22 comment=\"SSH $HOSTNAME\""
      sleep 2
      pct exec "$NEXT_ID" reboot >/dev/null 2>&1
    fi

    # Create subdomains and DNS records for each student
    if $DRY_RUN; then
      echo "  🔸 Would add subdomain and DNS-records for $HOSTNAME.$DOMAIN_SUFFIX"
    else
      source ./venv/bin/activate
      python3 registerSubdomain.py $HOSTNAME
    fi
  fi
  # Add server blocks on nginx
    NGINX_CONF_PATH="/etc/nginx/sites-available/$HOSTNAME"
    NGINX_ENABLED_PATH="/etc/nginx/sites-enabled/$HOSTNAME"
    SERVER_NAME="$HOSTNAME.$DOMAIN_SUFFIX"

    if $DRY_RUN; then
      echo "  🔸 Would create nginx server block for $SERVER_NAME on $NGINX_HOST"
    else
      sshpass -p "$NGINX_PASS" ssh -o StrictHostKeyChecking=no "$NGINX_USER@$NGINX_HOST" "sudo tee $NGINX_CONF_PATH >/dev/null" <<EOF
server {
    server_name $SERVER_NAME;

    location / {
        proxy_pass http://$IP:$STUDENT_SERVE_PORT/;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF

      sshpass -p "$NGINX_PASS" ssh -o StrictHostKeyChecking=no "$NGINX_USER@$NGINX_HOST" "sudo ln -sf $NGINX_CONF_PATH $NGINX_ENABLED_PATH"
      # Reload nginx
      sshpass -p "$NGINX_PASS" ssh -o StrictHostKeyChecking=no "$NGINX_USER@$NGINX_HOST" "sudo systemctl reload nginx"

    fi
  ((NEXT_ID++))
done 3< "$CSV_FILE"

# Get certificates for the new subdomains
while IFS=',' read -r CLASS LASTNAME FIRSTNAME <&3; do
  # Strip Windows carriage returns
  CLASS="${CLASS//$'\r'/}"
  LASTNAME="${LASTNAME//$'\r'/}"
  FIRSTNAME="${FIRSTNAME//$'\r'/}"

  # Build a valid hostname
  RAW_HOSTNAME="${CLASS}-${FIRSTNAME// /_}-${LASTNAME// /_}"
  RAW_HOSTNAME=$(echo "$RAW_HOSTNAME" | tr '[:upper:]' '[:lower:]')
  HOSTNAME=$(echo "$RAW_HOSTNAME" | iconv -f utf8 -t ascii//translit | sed 's/[^a-z0-9-]//g')
  SERVER_NAME="$HOSTNAME.$DOMAIN_SUFFIX"



  # Request certificate
  if $DRY_RUN; then
    echo "  🔸 Would request Let's Encrypt certificate for $SERVER_NAME"
  else
    # Wait for DNS to resolve
    for i in $(seq 1 $((DNS_TIMEOUT / 5))); do
      if host "$SERVER_NAME" >/dev/null 2>&1; then
        echo "  🌐 DNS for $SERVER_NAME is ready"
        break
      fi
      echo "  🌐 Waiting until DNS for $SERVER_NAME resolves"
      sleep 2
    done
    sshpass -p "$NGINX_PASS" ssh -o StrictHostKeyChecking=no "$NGINX_USER@$NGINX_HOST" \
    "sudo certbot --nginx --non-interactive --agree-tos --email $ADMIN_EMAIL --expand --redirect --no-eff-email --domain $SERVER_NAME"
  fi
done 3< "$CSV_FILE"