#!/usr/bin/env bash
# Tear down the live smoke stack started by live-stack-up.sh.
export PATH="$PATH:$HOME/.foundry/bin"
RUN=/tmp/inverse-live
for p in api indexer anvil; do
  [ -f "$RUN/$p.pid" ] && kill "$(cat "$RUN/$p.pid")" 2>/dev/null && echo "stopped $p"
  rm -f "$RUN/$p.pid"
done
if [ -f "$RUN/pgdata.txt" ] && [ -f "$RUN/pgbin.txt" ]; then
  PGDATA="$(cat "$RUN/pgdata.txt")"; PGBIN="$(cat "$RUN/pgbin.txt")"
  LC_ALL=C "$PGBIN/pg_ctl" -D "$PGDATA" stop -m fast >/dev/null 2>&1 && echo "stopped postgres"
  rm -f "$RUN/pgdata.txt" "$RUN/pgbin.txt"
fi
echo "down."
