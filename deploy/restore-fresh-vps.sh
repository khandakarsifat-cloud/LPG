#!/bin/sh
# Restore only into empty volumes. Existing data is never overwritten.
set -eu
cd /opt/lpg
image=public.ecr.aws/supabase/postgres:17.6.1.140
for item in 'lpg_db_data:pgdata.tgz' 'lpg_db-config:db-config.tgz' 'lpg_storage_data:storage.tgz'; do
    volume=${item%%:*}
    archive=${item#*:}
    sudo docker volume create "$volume" >/dev/null
    sudo docker run --rm --user 0 --entrypoint sh \
        -v "$volume:/target" -v /opt/lpg/backups:/backup:ro "$image" \
        -c 'test -z "$(ls -A /target)" || { echo "Refusing to overwrite a nonempty volume"; exit 1; }; tar xzf "/backup/$1" -C /target' sh "$archive"
done
sudo docker compose up -d db
