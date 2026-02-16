#!/bin/bash

while true; do
    php -f /var/www/html/cron.php
    php /var/www/html/occ preview:pre-generate
    sleep 300
done
