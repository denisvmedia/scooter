#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
project=$PWD
work=$(mktemp -d)
cleanup() { pg_ctl -D "$work/data" -m immediate stop >/dev/null 2>&1 || true; rm -rf "$work"; }
trap cleanup EXIT
initdb -D "$work/data" -U postgres --auth=trust >/dev/null
port=56172
mkdir "$work/sock"
pg_ctl -D "$work/data" -o "-k $work/sock -c listen_addresses=127.0.0.1 -p $port" -l "$work/pg.log" start >/dev/null
url="postgres://postgres@127.0.0.1:$port"
old=${ATLAS_REFERENCE:?Set ATLAS_REFERENCE to the original Atlas binary}
fixed=${PTAH_PROOF_BIN:-atlas}
unset PTAH_DEV_SERVER_DISPOSABLE
for name in agent_host broker byoc scheduler webhooks; do
  createdb -h 127.0.0.1 -p "$port" -U postgres "old_$name"
  createdb -h 127.0.0.1 -p "$port" -U postgres "fresh_$name"
  oldurl="$url/old_$name?sslmode=disable"
  newurl="$url/fresh_$name?sslmode=disable"
  dir="file://$project/lib/sql/$name/migrations"
  "$old" migrate apply --dir "$dir" --url "$oldurl" >/dev/null
  psql "$oldurl" -Atc 'SELECT row_to_json(r) FROM atlas_schema_revisions.atlas_schema_revisions r ORDER BY version' > "$work/before"
  "$fixed" migrate apply --dir "$dir" --url "$oldurl" >/dev/null
  psql "$oldurl" -Atc 'SELECT row_to_json(r) FROM atlas_schema_revisions.atlas_schema_revisions r ORDER BY version' > "$work/after"
  cmp "$work/before" "$work/after"
  "$fixed" migrate apply --dir "$dir" --url "$newurl" >/dev/null
  "$fixed" schema diff --from "$oldurl" --to "$newurl" | tee "$work/diff"
  grep -q 'no changes to be made' "$work/diff"
  echo "PASS: $name fresh apply and Atlas handover with unchanged revision rows"
  baseline=$(find "lib/sql/$name/migrations" -name '*_baseline.sql' -print -quit)
  if [ -n "$baseline" ]; then
    createdb -h 127.0.0.1 -p "$port" -U postgres "adopt_$name"
    adopturl="$url/adopt_$name?sslmode=disable"
    psql "$adopturl" -v ON_ERROR_STOP=1 -f "$baseline" >/dev/null
    if "$fixed" migrate apply --dir "$dir" --url "$adopturl" > "$work/adopt" 2>&1; then
      echo "expected a nonempty unmanaged database to require baseline adoption" >&2
      exit 1
    fi
    grep -q 'not clean' "$work/adopt"
    version=$(basename "$baseline"); version=${version%%_*}
    "$fixed" migrate apply --dir "$dir" --url "$adopturl" --baseline "$version" >/dev/null
    "$fixed" schema diff --from "$adopturl" --to "$newurl" > "$work/adopt-diff"
    grep -q 'no changes to be made' "$work/adopt-diff"
    echo "PASS: $name unmanaged baseline adoption matches fresh database"
  fi
done
cp -R lib/sql/agent_host "$work/agent_host"
python3 - "$work/agent_host/schema.sql" <<'PY'
import sys
from pathlib import Path
p=Path(sys.argv[1]);s=p.read_text()
s=s.replace("pg_notify('conversations_changed',", "pg_notify('conversations_changed_probe',")
s=s.replace('OLD."owner"       IS DISTINCT FROM NEW."owner"', 'OLD."owner"       IS DISTINCT FROM NEW."owner" OR OLD."phase" IS DISTINCT FROM NEW."phase"')
p.write_text(s)
PY
createdb -h 127.0.0.1 -p "$port" -U postgres dev
PTAH_DEV_SERVER_DISPOSABLE=1 "$fixed" migrate diff notify_probe --dir "file://$work/agent_host/migrations" --to "file://$work/agent_host/schema.sql" --dev-url "$url/dev?sslmode=disable&search_path=public"
"$fixed" migrate apply --dir "file://$work/agent_host/migrations" --url "$url/old_agent_host?sslmode=disable"
psql "$url/old_agent_host?sslmode=disable" -v ON_ERROR_STOP=1 <<'SQL' > "$work/notifications"
LISTEN conversations_changed_probe;
INSERT INTO conversations (id, thread_id, title, created_at, last_activity_at) VALUES ('ptah-notify-proof', 'proof-thread', 'Proof', 0, 0);
UPDATE conversations SET phase = 'Assigned' WHERE id = 'ptah-notify-proof';
UPDATE conversations SET last_activity_at = 42 WHERE id = 'ptah-notify-proof';
DELETE FROM conversations WHERE id = 'ptah-notify-proof';
SQL
cat "$work/notifications"
test "$(grep -c 'Asynchronous notification' "$work/notifications")" -eq 3
PTAH_DEV_SERVER_DISPOSABLE=1 "$fixed" migrate diff no_change --dir "file://$work/agent_host/migrations" --to "file://$work/agent_host/schema.sql" --dev-url "$url/dev?sslmode=disable&search_path=public" | tee "$work/repeat"
grep -q 'no changes to be made' "$work/repeat"
echo 'PASS: generated trigger handles INSERT, changed phase, DELETE; activity-only update stays silent; next diff is empty'
