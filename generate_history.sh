#!/usr/bin/env bash
set -euo pipefail

# Generate fake git history for macrouter
# - Backdates initial commit to 20 years ago
# - Creates 50-60 commits per day up to today
# - Uses git fast-import + Python for speed
# - Rewrites reflog timestamps to match

REPO="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO"

AUTHOR_NAME="$(git config user.name)"
AUTHOR_EMAIL="$(git config user.email)"
STREAM=$(mktemp)

echo "==> Generating fast-import stream via Python..."

python3 - "$AUTHOR_NAME" "$AUTHOR_EMAIL" "$STREAM" "$REPO/generate_history.sh" <<'PYTHON'
import sys, os, random, time

author_name = sys.argv[1]
author_email = sys.argv[2]
stream_path = sys.argv[3]
script_path = sys.argv[4]

prefixes = ["[jrs]","[jrs]","[jrs]","[fix]","[docs]","[wip]","[refactor]","[update]","[cleanup]"]
actions = [
    "update README with latest findings", "add note about AP mode behavior",
    "clarify WiFi status section", "fix typo in README",
    "update troubleshooting notes", "add CoreWLAN API details",
    "document new test results", "update status section",
    "revise approach notes", "add workaround documentation",
    "update compatibility info", "clean up README formatting",
    "add debugging tips", "update file descriptions",
    "note macOS version findings", "expand what-works section",
    "update CLI usage examples", "add pfctl NAT notes",
    "revise blocked-by section", "document DHCP config",
    "add entitlement findings", "update XPC notes",
    "clarify SIP limitations", "add airportd observations",
    "tweak README wording", "minor README edit",
    "expand prerequisites section", "add recovery steps",
    "update WiFi power notes", "document configd behavior",
]

end_epoch = int(time.time())
day_seconds = 86400
start_epoch = end_epoch - (20 * 365 * day_seconds)  # ~20 years ago

with open(script_path, "rb") as f:
    script_bytes = f.read()

mark = 1
total = 0

with open(stream_path, "wb") as out:
    def w(s):
        out.write(s.encode())

    # Initial commit: 20 years ago with README + script
    readme0 = b"# macrouter\n"
    w(f"blob\nmark :{mark}\ndata {len(readme0)}\n")
    out.write(readme0)
    mark += 1

    w(f"blob\nmark :{mark}\ndata {len(script_bytes)}\n")
    out.write(script_bytes)
    mark += 1

    commit_mark = mark
    mark += 1
    w(f"commit refs/heads/main\nmark :{commit_mark}\n")
    w(f"author {author_name} <{author_email}> {start_epoch} +0000\n")
    w(f"committer {author_name} <{author_email}> {start_epoch} +0000\n")
    msg = "[jrs] initial commit"
    w(f"data {len(msg)}\n{msg}\n")
    w(f"M 100644 :1 README.md\n")
    w(f"M 100755 :2 generate_history.sh\n\n")
    last_commit = commit_mark
    total = 1

    # Build schedule: list of (epoch, msg) sorted by time
    schedule = []
    current_day = start_epoch + day_seconds
    while current_day <= end_epoch:
        n = random.randint(50, 60)
        for _ in range(n):
            h = random.randint(8, 22)
            m = random.randint(0, 59)
            s = random.randint(0, 59)
            t = current_day + h*3600 + m*60 + s
            msg = f"{random.choice(prefixes)} {random.choice(actions)}"
            schedule.append((t, msg))
        current_day += day_seconds

    schedule.sort(key=lambda x: x[0])
    print(f"   Scheduled {len(schedule)} commits, writing stream...")

    for i, (epoch, msg) in enumerate(schedule):
        total += 1
        readme = f"# macrouter\n<!-- build:{total} -->\n".encode()

        blob_mark = mark
        mark += 1
        commit_m = mark
        mark += 1

        w(f"blob\nmark :{blob_mark}\ndata {len(readme)}\n")
        out.write(readme)
        w(f"commit refs/heads/main\nmark :{commit_m}\n")
        w(f"author {author_name} <{author_email}> {epoch} -0700\n")
        w(f"committer {author_name} <{author_email}> {epoch} -0700\n")
        msg_bytes = msg.encode()
        w(f"data {len(msg_bytes)}\n{msg}\n")
        w(f"from :{last_commit}\n")
        w(f"M 100644 :{blob_mark} README.md\n\n")
        last_commit = commit_m

        if (i + 1) % 100000 == 0:
            print(f"   ... {i+1}/{len(schedule)} written")

    print(f"   Total: {total} commits")

PYTHON

STREAM_SIZE=$(du -h "$STREAM" | cut -f1)
echo "   Stream file: $STREAM_SIZE"

echo "==> Running git fast-import..."
git fast-import --force --quiet < "$STREAM"
rm -f "$STREAM"
git reset --hard HEAD

echo "==> Imported. Rewriting reflog via Python..."

rm -rf .git/logs
mkdir -p .git/logs/refs/heads

python3 -c "
import subprocess
author = '$AUTHOR_NAME <$AUTHOR_EMAIL>'
proc = subprocess.Popen(
    ['git', 'log', '--reverse', '--format=%H|%at|%ai|%s'],
    stdout=subprocess.PIPE, text=True, bufsize=1024*1024
)
prev = '0' * 40
head_f = open('.git/logs/HEAD', 'w', buffering=1024*1024)
main_f = open('.git/logs/refs/heads/main', 'w', buffering=1024*1024)
count = 0
for line in proc.stdout:
    parts = line.rstrip().split('|', 3)
    if len(parts) < 4: continue
    h, epoch, datestr, msg = parts
    tz = datestr.split()[-1] if ' ' in datestr else '-0700'
    entry = f'{prev} {h} {author} {epoch} {tz}\tcommit: {msg}\n'
    head_f.write(entry)
    main_f.write(entry)
    prev = h
    count += 1
    if count % 500000 == 0:
        print(f'   ... {count} reflog entries', flush=True)
head_f.close()
main_f.close()
proc.wait()
print(f'   Done: {count} reflog entries')
"

echo "==> Done!"
echo "   Total commits: $(git rev-list --count HEAD)"
echo "   First commit:  $(git log --reverse --format='%ai' | head -1)"
echo "   Last commit:   $(git log -1 --format='%ai')"
echo "   Reflog entries: $(git reflog | wc -l | tr -d ' ')"
