#!/bin/bash

# Ensure a resource pool name is provided
if [[ -z "$1" ]]; then
  echo "Usage: $0 <resource-pool-name>"
  exit 1
fi

RESOURCE_POOL="$1"

echo "Finding containers in resource pool '$RESOURCE_POOL'..."

# Get all container IDs in the pool
CTIDS=$(pvesh get /pools/"$RESOURCE_POOL" --output-format=json | jq -r '.members[] | select(.type=="lxc") | .vmid')

if [[ -z "$CTIDS" ]]; then
  echo "No containers found in pool '$RESOURCE_POOL'."
  exit 0
fi

echo "The following containers will be removed:"
echo "$CTIDS"

read -p "Are you sure you want to delete these containers? [y/N] " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
  echo "Aborted."
  exit 1
fi

for CTID in $CTIDS; do
  echo "Stopping container $CTID..."
  pct stop "$CTID" 2>/dev/null

  echo "Deleting container $CTID..."
  pct destroy "$CTID"
done

echo "✅ All containers in pool '$RESOURCE_POOL' have been removed."