#!/usr/bin/env bash
# Builds the herdr session that assets/demo.tape records, then leaves it running
# for vhs to attach to:
#
#   tab 1: an agent pane on the left, this plugin's sidebar on the right
#   tab 2: flutter run, which the sidebar discovers on its own
#
# The session is named, so it gets its own server and socket and cannot disturb
# the herdr you are working in. Stop it afterwards with:
#
#   herdr session stop hfdemo
#
# Needs: herdr with this plugin linked or installed, a Flutter app at $APP, and
# a macOS or Linux desktop target for it.
set -euo pipefail

SESSION=hfdemo
APP=${APP:-/tmp/spots_app}
DEVICE=${DEVICE:-macos}

[ -d "$APP" ] || {
  printf 'demo: no app at %s. Point APP at a Flutter project.\n' "$APP" >&2
  exit 1
}

herdr session stop "$SESSION" >/dev/null 2>&1 || true
sleep 1

# The client needs a sized pty: herdr cannot allocate a surface on a 0x0
# terminal, which is what a bare `script` gives it. herdr also refuses to nest,
# so the HERDR_* variables of the calling pane are cleared.
env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
  -u HERDR_SOCKET_PATH \
  script -q /tmp/$SESSION-client.log \
  sh -c "stty rows 40 cols 150; exec herdr --session $SESSION" >/dev/null 2>&1 &
sleep 6

SOCK="$HOME/.config/herdr/sessions/$SESSION/herdr.sock"
[ -S "$SOCK" ] || { printf 'demo: session %s did not start\n' "$SESSION" >&2; exit 1; }
export HERDR_SOCKET_PATH="$SOCK"

pane_id() {
  python3 -c '
import json,sys
def find(node):
    if isinstance(node, dict):
        if isinstance(node.get("pane_id"), str):
            return node["pane_id"]
        for value in node.values():
            found = find(value)
            if found:
                return found
    if isinstance(node, list):
        for value in node:
            found = find(value)
            if found:
                return found
    return None
print(find(json.load(sys.stdin)) or "")'
}

# The agent side. A real coding agent would be slow and never say the same thing
# twice, so the recording uses a script that prints one exchange and then waits
# for input, which is all the handoff needs: a pane that herdr counts as an
# agent and that shows what lands in it.
cat > /tmp/$SESSION-agent.sh <<'AGENT'
#!/usr/bin/env bash
printf '\033[1;35m✻ Claude Code\033[0m  \033[2m~/spots_app\033[0m\n\n'
printf '\033[2m> the spot card throws when a spot has no coordinates,\033[0m\n'
printf '\033[2m  can you make it degrade instead?\033[0m\n\n'
printf '\033[32m●\033[0m I need to see the actual error first. Reproduce it and\n'
printf '  send it over.\n\n'
printf '\033[2m─────────────────────────────────────────────\033[0m\n'
while IFS= read -r line; do printf '%s' "$line"; done
AGENT
chmod +x /tmp/$SESSION-agent.sh

AGENT_PANE=$(herdr pane list | python3 -c '
import json,sys
print(json.load(sys.stdin)["result"]["panes"][0]["pane_id"])')
herdr pane run "$AGENT_PANE" cd "$APP" '&&' clear '&&' bash /tmp/$SESSION-agent.sh >/dev/null
sleep 2
herdr pane report-agent "$AGENT_PANE" --source demo --agent claude --state idle >/dev/null

WORKSPACE=$(herdr pane list | python3 -c '
import json,sys
print(json.load(sys.stdin)["result"]["panes"][0]["workspace_id"])')

# The app, in a tab of its own, started the way anyone would start it. The
# sidebar is given nothing: it reads this pane like any other.
RUN_PANE=$(herdr tab create --workspace "$WORKSPACE" --cwd "$APP" | pane_id)
herdr pane run "$RUN_PANE" flutter run -d "$DEVICE" >/dev/null
printf 'demo: waiting for the app to announce its VM Service\n'
for _ in $(seq 1 30); do
  sleep 10
  if herdr pane read "$RUN_PANE" --source recent --lines 300 --format text |
    grep -q 'Dart VM Service'; then
    break
  fi
done

herdr plugin action invoke open --plugin ablause.herdr-flutter >/dev/null
sleep 5
# The keys in the tape are for the sidebar, so it holds the focus at attach.
herdr pane focus --pane "$AGENT_PANE" --direction right >/dev/null
printf 'demo: session %s is ready, record it with: vhs assets/demo.tape\n' "$SESSION"
