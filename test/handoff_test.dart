import 'package:herdr_flutter/src/handoff.dart';
import 'package:herdr_flutter/src/herdr_cli.dart';
import 'package:test/test.dart';

PaneInfo pane(
  String id, {
  String tab = 't1',
  String workspace = 'w1',
  String? agent,
  String? label,
}) =>
    PaneInfo.fromJson({
      'pane_id': id,
      'tab_id': tab,
      'workspace_id': workspace,
      'terminal_title': id,
      'label': label,
      'agent': agent,
    });

void main() {
  group('pickAgent', () {
    test('takes the sole agent in the sidebar tab', () {
      final panes = [
        pane('w1:p1', agent: 'claude'),
        pane('w1:p2', label: 'flutter'),
        pane('w1:p7', tab: 't2', agent: 'claude'),
      ];
      final picked = pickAgent(
        panes,
        tabId: 't1',
        workspaceId: 'w1',
        selfPaneId: 'w1:p2',
      );
      expect(picked?.paneId, 'w1:p1');
    });

    test('falls back to the sole agent in the workspace', () {
      final panes = [
        pane('w1:p2', label: 'flutter', tab: 't5'),
        pane('w1:p7', tab: 't2', agent: 'claude'),
      ];
      final picked = pickAgent(
        panes,
        tabId: 't5',
        workspaceId: 'w1',
        selfPaneId: 'w1:p2',
      );
      expect(picked?.paneId, 'w1:p7');
    });

    test('a tab agent beats the workspace fallback', () {
      final panes = [
        pane('w1:p1', agent: 'claude'),
        pane('w1:p7', tab: 't2', agent: 'claude'),
      ];
      final picked = pickAgent(
        panes,
        tabId: 't1',
        workspaceId: 'w1',
        selfPaneId: 'w1:p9',
      );
      expect(picked?.paneId, 'w1:p1');
    });

    test('refuses when several agents are candidates', () {
      final panes = [
        pane('w1:p1', tab: 't1', agent: 'claude'),
        pane('w1:p2', tab: 't1', agent: 'codex'),
      ];
      expect(
        pickAgent(panes, tabId: 't1', workspaceId: 'w1', selfPaneId: 'w1:p9'),
        isNull,
      );
    });

    test('refuses when there is no agent at all', () {
      expect(
        pickAgent(
          [pane('w1:p2', label: 'flutter')],
          tabId: 't1',
          workspaceId: 'w1',
          selfPaneId: 'w1:p2',
        ),
        isNull,
      );
    });

    test('never targets the sidebar own pane', () {
      final panes = [pane('w1:p2', agent: 'claude')];
      expect(
        pickAgent(panes, tabId: 't1', workspaceId: 'w1', selfPaneId: 'w1:p2'),
        isNull,
      );
    });

    test('ignores panes from another workspace', () {
      final panes = [pane('w2:p1', workspace: 'w2', tab: 't1', agent: 'claude')];
      expect(
        pickAgent(panes, tabId: 't1', workspaceId: 'w1', selfPaneId: 'w1:p9'),
        isNull,
      );
    });
  });
}
