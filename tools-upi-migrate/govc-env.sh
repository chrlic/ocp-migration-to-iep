#!/bin/bash
# Source this to set govc environment variables for the UPI migration lab.
# Kept separate so scripts can source just govc-env.sh without loading all lab vars.

source /root/tools-upi-migrate/lab-config.sh
# lab-config.sh ships empty VCENTER_* placeholders; the real credentials live in
# secrets-for-lab.sh (gitignored). Source it AFTER lab-config so it overrides them.
[ -f /root/secrets-for-lab.sh ] && source /root/secrets-for-lab.sh

export GOVC_URL="https://${VCENTER_HOST}:443"
export GOVC_USERNAME="${VCENTER_USER}"
export GOVC_PASSWORD="${VCENTER_PASS}"
export GOVC_INSECURE=1
export GOVC_DATASTORE="${VCENTER_DATASTORE}"
