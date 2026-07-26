# Demo recording for herdr-flutter, showing the sidebar where it belongs: in a
# herdr session, beside the agent that is working on the app.
#
# The session is built before recording by assets/demo-session.sh, which starts
# an isolated herdr session named hfdemo holding
#
#   tab 1: an agent pane on the left, this plugin's sidebar on the right
#   tab 2: flutter run, which the sidebar discovers on its own
#
# Then: bash assets/demo-session.sh && vhs assets/demo.tape
#
# The environment is cleared of HERDR_* first, since herdr refuses to nest and
# the recorder may itself be running inside a herdr pane.

Output assets/demo.gif

Set Shell "bash"
Set FontSize 13
Set Width 1280
Set Height 680
Set Theme "Catppuccin Mocha"
Set Padding 12
Set TypingSpeed 40ms

Hide
Type "clear && env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_SOCKET_PATH herdr session attach hfdemo" Enter
Sleep 4s
Show

# The sidebar has attached to the app running in the other tab, and its log is
# already filling: a logger name per line, and a colour per level.
Sleep 5s

# Hot restart over the protocol. The pane that owns the run is never touched,
# and the rebuild raises the error this app raises on purpose.
Type "R"
Sleep 6s

# The error, with the line of source that raised it.
Type "2"
Sleep 3s

# The console rendering of it, in full.
Enter
Sleep 5s

# Hand it to the agent: the report is written, a single line naming it lands in
# the agent's input, and the focus moves there. Nothing is submitted.
Type "s"
Sleep 5s
