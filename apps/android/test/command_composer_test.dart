import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:codex_bridge/data/models.dart';
import 'package:codex_bridge/data/workbench.dart';
import 'package:codex_bridge/ui/command_composer.dart';

import 'support.dart';

class ComposerWorkbench extends Workbench {
  ComposerWorkbench() : super(MemoryStore()) {
    initialized = true;
    host = sampleHost;
    status = 'online';
    projectId = 'project';
    skills = [
      {
        'name': 'release-check',
        'description': 'Check release readiness',
        'path': '/skills/release-check',
      },
    ];
  }

  @override
  Future<List<Json>> searchProjectFiles(
    String query, {
    int maxDirectories = 120,
    int maxResults = 50,
  }) async => [
    {'name': 'main.dart', 'path': 'lib/main.dart'},
  ];

  @override
  Future<void> loadTools() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('slash menu inserts a Codex command without executing it', (
    tester,
  ) async {
    final workbench = ComposerWorkbench();
    final key = GlobalKey<CommandComposerState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CommandComposer(
            key: key,
            workbench: workbench,
            enabled: true,
            sending: false,
            running: false,
            canSend: true,
            hint: 'Describe a task',
            onSend: () async {},
            onAttachment: (_) async {},
          ),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), '/rev');
    await tester.pump();
    expect(find.text('/review'), findsOneWidget);
    await tester.tap(find.text('/review'));
    await tester.pump();

    expect(key.currentState!.input, [
      {'type': 'text', 'text': '/review ', 'text_elements': <dynamic>[]},
    ]);
  });

  testWidgets('at menu creates a removable file Token', (tester) async {
    final workbench = ComposerWorkbench();
    final key = GlobalKey<CommandComposerState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CommandComposer(
            key: key,
            workbench: workbench,
            enabled: true,
            sending: false,
            running: false,
            canSend: true,
            hint: 'Describe a task',
            onSend: () async {},
            onAttachment: (_) async {},
          ),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), '@main');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('lib/main.dart'), findsOneWidget);
    await tester.tap(find.text('lib/main.dart'));
    await tester.pump();

    expect(find.byType(InputChip), findsOneWidget);
    expect(key.currentState!.input, [
      {'type': 'mention', 'name': 'main.dart', 'path': 'lib/main.dart'},
    ]);
    await tester.tap(find.byTooltip('移除引用'));
    await tester.pump();
    expect(find.byType(InputChip), findsNothing);
    expect(key.currentState!.input, isEmpty);
  });

  test('searchProjectFiles traverses project directories and ignores generated trees', () async {
    final workbench = ComposerWorkbench();
    final transport = FakeTransport();
    transport.handler = (method, params) async {
      if (method != 'files/list') return {};
      return switch (params['path']) {
        '' => {
          'entries': [
            {'name': 'lib', 'isDirectory': true},
            {'name': '.git', 'isDirectory': true},
            {'name': 'README.md', 'isFile': true},
          ],
        },
        'lib' => {
          'entries': [
            {'name': 'main.dart', 'isFile': true},
            {'name': 'build', 'isDirectory': true},
          ],
        },
        'lib/build' => {
          'entries': [
            {'name': 'generated.dart', 'isFile': true},
          ],
        },
        _ => {'entries': []},
      };
    };
    workbench.transport = transport;

    final files = await workbench.searchProjectFiles('dart');

    expect(files, [
      {'name': 'main.dart', 'path': 'lib/main.dart'},
    ]);
  });

  test('sendInput preserves structured order and uses turn/start', () async {
    final workbench = ComposerWorkbench();
    workbench.threadId = 'task';
    final transport = FakeTransport();
    Json? sent;
    transport.handler = (method, params) async {
      if (method == 'turn/start') sent = params;
      return {};
    };
    workbench.transport = transport;

    await workbench.sendInput([
      {'type': 'text', 'text': 'Review ', 'text_elements': <dynamic>[]},
      {'type': 'mention', 'name': 'main.dart', 'path': 'lib/main.dart'},
      {'type': 'text', 'text': ' carefully', 'text_elements': <dynamic>[]},
      {
        'type': 'skill',
        'name': 'release-check',
        'path': '/skills/release-check',
      },
    ]);

    expect(transport.calls, ['thread/resume', 'turn/start']);
    expect(sent?['input'], [
      {'type': 'text', 'text': 'Review ', 'text_elements': <dynamic>[]},
      {'type': 'mention', 'name': 'main.dart', 'path': 'lib/main.dart'},
      {'type': 'text', 'text': ' carefully', 'text_elements': <dynamic>[]},
      {
        'type': 'skill',
        'name': 'release-check',
        'path': '/skills/release-check',
      },
    ]);
  });
}
