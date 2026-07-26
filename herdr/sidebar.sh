#!/usr/bin/env bash
# The herdr-flutter sidebar actions and event hook.
#
#   sidebar.sh toggle      open the sidebar, or close it if one is open
#   sidebar.sh open        open the sidebar, no-op if one is open
#   sidebar.sh close       close every herdr-flutter pane, no-op if none
#   sidebar.sh auto-open   worktree.created hook: open, gated by auto_open
#
# The workspace's sidebar is any pane labeled "flutter" in the live pane list, so
# there is no state file to go stale. Actions refuse loudly on stderr with exit 1
# and report success on stdout; both land in `herdr plugin log list`.
set -uo pipefail

# herdr runs plugin commands with a minimal PATH; ensure jq resolves.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

mode="${1:-toggle}"
H="${HERDR_BIN_PATH:-herdr}"
LABEL=flutter

if [ -n "${HERDR_FLUTTER_BIN:-}" ]; then
  BIN="$HERDR_FLUTTER_BIN"
elif [ -n "${HERDR_PLUGIN_ROOT:-}" ]; then
  BIN="$HERDR_PLUGIN_ROOT/bin/herdr-flutter"
else
  BIN="herdr-flutter"
fi

if [ ! -x "$BIN" ] && ! command -v "$BIN" >/dev/null 2>&1; then
  printf 'herdr-flutter: %s is missing. Run bash herdr/install.sh in the plugin root.\n' "$BIN" >&2
  exit 1
fi

# The binary owns config parsing and defaults, so every entry point shares one
# contract and bash never parses TOML.
config_json=$("$BIN" --resolve-plugin-config 2>&1)
if [ $? -ne 0 ]; then
  [ -n "$config_json" ] || config_json="herdr-flutter: configuration validation failed"
  printf '%s\n' "$config_json" >&2
  exit 1
fi
unreadable() {
  printf 'herdr-flutter: normalized configuration is unreadable\n' >&2
  exit 1
}
placement=$(printf '%s' "$config_json" | jq -er '.toggle_placement' 2>/dev/null) || unreadable
direction=$(printf '%s' "$config_json" | jq -er '.toggle_direction' 2>/dev/null) || unreadable
# Not `jq -e` here: it exits 1 on a false value, which is a legitimate setting.
auto_open=$(printf '%s' "$config_json" |
  jq -r 'if has("auto_open") then .auto_open else error("missing auto_open") end' 2>/dev/null) || unreadable

# The event policy gates the event alone; explicit actions ignore it.
if [ "$mode" = auto-open ]; then
  [ "$auto_open" = "true" ] || exit 0
  if [ "$placement" != "split" ] && [ "$placement" != "tab" ]; then
    exit 0
  fi
fi

refuse() {
  [ "$mode" = auto-open ] && exit 0
  printf 'herdr-flutter: %s\n' "$1" >&2
  exit 1
}

ws="${HERDR_WORKSPACE_ID:-}"
pane="${HERDR_PANE_ID:-}"
cwd=""
[ -n "${HERDR_PLUGIN_CONTEXT_JSON:-}" ] &&
  cwd=$(printf '%s' "$HERDR_PLUGIN_CONTEXT_JSON" | jq -r '.focused_pane_cwd // .workspace_cwd // empty' 2>/dev/null)

# The event fires without a focused pane; target the fresh workspace instead.
if [ "$mode" = auto-open ] && [ -n "${HERDR_PLUGIN_EVENT_JSON:-}" ]; then
  ev="$HERDR_PLUGIN_EVENT_JSON"
  ws=$(printf '%s' "$ev" | jq -r '.data.workspace.workspace_id // .data.worktree.open_workspace_id // empty' 2>/dev/null)
  cwd=$(printf '%s' "$ev" | jq -r '.data.workspace.worktree.checkout_path // .data.worktree.path // empty' 2>/dev/null)
  pane=""
fi

[ -n "$ws" ] || refuse "no workspace context (invoke from inside herdr)"

# One pane-list snapshot serves the whole run. A failed listing must not read as
# "no sidebar": that would stack a duplicate on toggle and false-succeed a close.
panes_json=$("$H" pane list --workspace "$ws" 2>/dev/null) && [ -n "$panes_json" ] ||
  refuse "herdr pane list failed for $ws"

existing=$(printf '%s' "$panes_json" | jq -r --arg label "$LABEL" \
  '.result.panes[] | select(.label == $label) | .pane_id' 2>/dev/null)

# Plain `pane close`, not `plugin pane close`: the plugin-pane registry does not
# survive a herdr restart and would strand a live sidebar.
close_all() {
  closed="" failed=""
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if "$H" pane close "$p" >/dev/null 2>&1; then closed="$closed $p"; else failed="$failed $p"; fi
  done <<EOF
$existing
EOF
  [ -z "$failed" ] || refuse "failed to close$failed in $ws"
  printf 'closed%s in %s\n' "$closed" "$ws"
}

case "$mode" in
close)
  [ -n "$existing" ] || { printf 'close: nothing open in %s\n' "$ws"; exit 0; }
  close_all
  exit 0
  ;;
toggle)
  if [ -n "$existing" ]; then
    close_all
    exit 0
  fi
  ;;
open | auto-open)
  if [ -n "$existing" ]; then
    [ "$mode" = open ] && printf 'open: already open (%s) in %s\n' \
      "$(printf '%s' "$existing" | tr '\n' ' ' | sed 's/ $//')" "$ws"
    exit 0
  fi
  ;;
*)
  refuse "unknown mode '$mode' (toggle | open | close | auto-open)"
  ;;
esac

# Opening from here on. Unlike a review sidebar this one needs no git repo: it
# attaches to a running app, wherever the pane happens to sit.
[ -n "$cwd" ] || refuse "no working directory in context"

# Focus follows the placement on a manual open; the event never takes it.
focus=--no-focus
[ "$mode" != auto-open ] && [ "$placement" != "split" ] && focus=--focus

case "$placement" in
split | zoomed)
  if [ -z "$pane" ]; then
    pane=$(printf '%s' "$panes_json" | jq -r '.result.panes[0].pane_id // empty' 2>/dev/null)
  fi
  [ -n "$pane" ] || refuse "no pane to attach to in $ws"
  set -- --placement "$placement" --target-pane "$pane"
  [ "$placement" = "split" ] && set -- "$@" --direction "$direction"
  ;;
tab)
  set -- --placement tab --workspace "$ws"
  ;;
overlay)
  set -- --placement overlay
  ;;
*)
  refuse "unreachable placement '$placement'"
  ;;
esac

new=$("$H" plugin pane open --plugin "${HERDR_PLUGIN_ID:-ablause.herdr-flutter}" \
  --entrypoint sidebar "$@" --cwd "$cwd" "$focus" 2>/dev/null |
  jq -r '.result.plugin_pane.pane.pane_id // empty' 2>/dev/null)
[ -n "$new" ] || refuse "herdr plugin pane open failed"
[ "$mode" = auto-open ] || printf 'opened %s (%s) in %s\n' "$new" "$placement" "$ws"
