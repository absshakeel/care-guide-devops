#!/usr/bin/env bash
# cron-example.sh
# Install this cron job on the target host to run system_health.sh every 5 minutes.
#
# Add to /etc/cron.d/system_health:
#   */5 * * * * nobody /opt/careguide/scripts/system_health.sh >> /opt/careguide/health_log.txt 2>&1

# To verify the cron is installed:
#   crontab -l -u nobody
#
# Prefer the systemd timer (systemd/system-health.timer) over cron on
# systemd-based hosts — it provides better logging, retries, and accuracy.
echo "See systemd/system-health.timer for the preferred scheduling method."
echo "For cron-based scheduling, add the following to /etc/cron.d/system_health:"
echo "*/5 * * * * nobody /opt/careguide/scripts/system_health.sh >> /opt/careguide/health_log.txt 2>&1"

