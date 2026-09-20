import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:codex_bridge/main.dart';
import 'package:codex_bridge/data/workbench.dart';
import 'package:codex_bridge/data/models.dart';
import 'package:codex_bridge/ui/chat.dart';

import 'support.dart';

class PairingWorkbench extends Workbench {
  PairingWorkbench() : super(MemoryStore()) {
    initialized = true;
  }

  @override
  Future<void> pair(Pairing pairing, String name) async {
    host = sampleHost;
    hosts = [sampleHost];
    status = 'online';
    clearError();
  }
}

Workbench processWorkbench() {
  final workbench = fixtureWorkbench()..epoch = 'epoch';
  workbench.runtimeThreads = [
    {'id': 'task', 'state': 'running', 'turn': 'turn-1'},
  ];
  workbench.timelines['task'] = [
    {
      'id': 'reasoning',
      'type': 'reasoning',
      'turnId': 'turn-1',
      'text': '先检查项目，再验证改动。',
    },
    {
      'id': 'command',
      'type': 'commandExecution',
      'turnId': 'turn-1',
      'command': 'flutter test',
      'status': 'completed',
    },
    {
      'id': 'reply',
      'type': 'agentMessage',
      'turnId': 'turn-1',
      'text': '最终回复始终直接展示。',
    },
  ];
  return workbench;
}

void completeTurn(Workbench workbench) => workbench.receive({
  'type': 'event',
  'epoch': 'epoch',
  'seq': workbench.cursor + 1,
  'method': 'turn/completed',
  'params': {
    'threadId': 'task',
    'turn': {'id': 'turn-1'},
  },
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final file = File('C:/Windows/Fonts/msyh.ttc');
    if (await file.exists()) {
      final bytes = await file.readAsBytes();
      for (final name in ['Roboto', 'monospace', 'Ahem']) {
        final loader = FontLoader(name)
          ..addFont(Future.value(ByteData.sublistView(bytes)));
        await loader.load();
      }
      final material = File(
        'D:/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      );
      if (await material.exists()) {
        final loader = FontLoader('MaterialIcons')
          ..addFont(
            Future.value(ByteData.sublistView(await material.readAsBytes())),
          );
        await loader.load();
      }
    }
  });
  Future<void> mount(
    WidgetTester tester,
    Workbench workbench, {
    Size size = const Size(390, 844),
    GlobalKey? key,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: ProviderScope(
          overrides: [workbenchProvider.overrideWith((ref) => workbench)],
          child: const BridgeApp(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> screenshot(
    WidgetTester tester,
    GlobalKey key,
    String name,
  ) async {
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1.5);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final directory = Directory('../../.local/screenshots');
      await directory.create(recursive: true);
      await File('${directory.path}/$name.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets(
    'empty state offers pairing; full access consent gates connection',
    (tester) async {
      final key = GlobalKey();
      await mount(tester, fixtureWorkbench(empty: true), key: key);
      expect(find.text('把开发环境连接过来'), findsOneWidget);
      await screenshot(tester, key, 'onboarding');
      await tester.tap(find.text('配对第一台主机'));
      await tester.pumpAndSettle();
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '信任并配对'),
      );
      expect(button.onPressed, isNull);
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '信任并配对'))
            .onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('phone workbench renders real controls without overflow', (
    tester,
  ) async {
    final key = GlobalKey();
    await mount(tester, fixtureWorkbench(), key: key);
    expect(find.text('完整访问'), findsOneWidget);
    expect(find.byTooltip('发送任务'), findsOneWidget);
    expect(find.text('思考过程 · 1 项活动'), findsOneWidget);
    expect(find.text('flutter test'), findsNothing);
    expect(find.byType(NavigationBar), findsNothing);
    await screenshot(tester, key, 'chat-light');
    await tester.tap(find.byTooltip('打开工作区'));
    await tester.pumpAndSettle();
    expect(find.text('pubspec.yaml'), findsOneWidget);
    expect(find.byTooltip('返回'), findsOneWidget);
    await screenshot(tester, key, 'workspace');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byTooltip('发送任务'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('dark tablet displays split task navigation and readable chat', (
    tester,
  ) async {
    final workbench = fixtureWorkbench()..theme = 'dark';
    final key = GlobalKey();
    await mount(tester, workbench, size: const Size(1200, 800), key: key);
    expect(find.text('检查文件保存冲突'), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    await tester.tap(find.text('Studio · Windows'));
    await tester.pumpAndSettle();
    expect(find.text('你的开发主机'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('检查文件保存冲突'), findsOneWidget);
    await screenshot(tester, key, 'tablet-dark');
    expect(tester.takeException(), isNull);
  });
  testWidgets('small screen opens terminal controls without overflow', (
    tester,
  ) async {
    final workbench = fixtureWorkbench();
    await mount(tester, workbench, size: const Size(320, 700));
    await tester.tap(find.byTooltip('打开工作区'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('终端'));
    await tester.pumpAndSettle();
    expect(find.text('打开终端'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'running process expands, completion collapses, final reply stays visible',
    (tester) async {
      final workbench = processWorkbench();
      await mount(tester, workbench);
      expect(find.text('正在思考…'), findsOneWidget);
      expect(find.text('思考摘要'), findsOneWidget);
      expect(find.text('flutter test'), findsOneWidget);
      expect(find.text('最终回复始终直接展示。'), findsOneWidget);
      expect(find.byTooltip('停止当前任务'), findsOneWidget);
      completeTurn(workbench);
      await tester.pumpAndSettle();
      expect(find.text('正在思考…'), findsNothing);
      expect(find.text('思考过程 · 2 项活动'), findsOneWidget);
      expect(find.text('思考摘要'), findsNothing);
      expect(find.text('flutter test'), findsNothing);
      expect(find.text('最终回复始终直接展示。'), findsOneWidget);
      expect(find.byTooltip('停止当前任务'), findsNothing);
      await tester.tap(find.text('思考过程 · 2 项活动'));
      await tester.pumpAndSettle();
      expect(find.text('思考摘要'), findsOneWidget);
      await tester.tap(find.text('思考过程 · 2 项活动'));
      await tester.pumpAndSettle();
      expect(find.text('思考摘要'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'manual toggle survives deltas and ordinary refresh but completion collapses',
    (tester) async {
      final workbench = processWorkbench();
      await mount(tester, workbench);
      await tester.tap(find.text('正在思考…'));
      await tester.pumpAndSettle();
      workbench.receive({
        'type': 'event',
        'epoch': 'epoch',
        'seq': 1,
        'method': 'item/reasoning/summaryTextDelta',
        'params': {
          'threadId': 'task',
          'turnId': 'turn-1',
          'itemId': 'reasoning',
          'delta': '新增摘要',
        },
      });
      await tester.pumpAndSettle();
      expect(find.text('思考摘要'), findsNothing);
      await tester.tap(find.text('正在思考…'));
      await tester.pumpAndSettle();
      expect(find.text('新增摘要'), findsOneWidget);
      completeTurn(workbench);
      await tester.pumpAndSettle();
      expect(find.text('思考摘要'), findsNothing);
      await tester.tap(find.text('思考过程 · 2 项活动'));
      await tester.pumpAndSettle();
      workbench.clearError();
      await tester.pumpAndSettle();
      expect(find.text('思考摘要'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'turns group independently across replies and legacy items never merge',
    (tester) async {
      final workbench = processWorkbench()..runtimeThreads = [];
      workbench.timelines['task'] = [
        {
          'id': 'first-plan',
          'type': 'plan',
          'turnId': 'first',
          'text': '第一轮计划',
        },
        {
          'id': 'first-reply',
          'type': 'agentMessage',
          'turnId': 'first',
          'text': '第一轮回复',
        },
        {
          'id': 'first-command',
          'type': 'commandExecution',
          'turnId': 'first',
          'command': 'first command',
        },
        {
          'id': 'second-plan',
          'type': 'plan',
          'turnId': 'second',
          'text': '第二轮计划',
        },
        {
          'id': 'second-reply',
          'type': 'agentMessage',
          'turnId': 'second',
          'text': '第二轮回复',
        },
        {
          'id': 'old-command',
          'type': 'commandExecution',
          'command': 'old command',
        },
        {
          'id': 'old-mcp',
          'type': 'mcpToolCall',
          'server': 'server',
          'tool': 'tool',
        },
      ];
      await mount(tester, workbench, size: const Size(1200, 1000));
      expect(find.text('正在思考…'), findsNothing);
      expect(find.text('思考过程 · 2 项活动'), findsOneWidget);
      expect(find.text('思考过程 · 1 项活动'), findsNWidgets(3));
      expect(find.text('第一轮回复'), findsOneWidget);
      expect(find.text('第二轮回复'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('process-toggle:turn:first')));
      await tester.pumpAndSettle();
      expect(find.text('第一轮计划'), findsOneWidget);
      expect(find.text('first command'), findsOneWidget);
      expect(find.text('第二轮计划'), findsNothing);
      expect(find.text('old command'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('waiting turn and tool-only turn need no reasoning summary', (
    tester,
  ) async {
    final workbench = processWorkbench();
    workbench.timelines['task'] = [];
    await mount(tester, workbench);
    expect(find.text('正在思考…'), findsOneWidget);
    expect(find.text('思考摘要'), findsNothing);
    workbench.receive({
      'type': 'event',
      'epoch': 'epoch',
      'seq': 1,
      'method': 'item/started',
      'params': {
        'threadId': 'task',
        'turnId': 'turn-1',
        'item': {
          'id': 'command',
          'type': 'commandExecution',
          'command': 'tool only',
        },
      },
    });
    await tester.pumpAndSettle();
    expect(find.text('tool only'), findsOneWidget);
    expect(find.text('思考摘要'), findsNothing);
    completeTurn(workbench);
    await tester.pumpAndSettle();
    expect(find.text('思考过程 · 1 项活动'), findsOneWidget);
    expect(find.text('tool only'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('task drawer and dialogs close before leaving the current page', (
    tester,
  ) async {
    await mount(tester, fixtureWorkbench());
    await tester.tap(find.byTooltip('任务列表'));
    await tester.pumpAndSettle();
    expect(find.text('检查文件保存冲突'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('检查文件保存冲突'), findsNothing);
    expect(find.byType(ChatPane), findsOneWidget);
    await tester.tap(find.byTooltip('打开工作区'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('添加主机项目目录'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('pubspec.yaml'), findsOneWidget);
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(find.byType(ChatPane), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final succeeds in [true, false]) {
    testWidgets(
      'first host selection only navigates when connected: $succeeds',
      (tester) async {
        final storage = MemoryStore()..tokens['host-a'] = 'test-token';
        final transport = FakeTransport();
        transport.onConnect = () async {
          transport.changes.add(
            succeeds ? 'online' : 'offline: test connection failed',
          );
        };
        final workbench = Workbench(storage, factory: (_, _) => transport)
          ..initialized = true
          ..hosts = [sampleHost];
        await mount(tester, workbench);
        expect(find.byTooltip('返回'), findsNothing);
        await tester.tap(find.text(sampleHost.name));
        await tester.pumpAndSettle();
        if (succeeds) {
          expect(find.byType(ChatPane), findsOneWidget);
          expect(find.text('你的开发主机'), findsNothing);
        } else {
          expect(find.byType(ChatPane), findsNothing);
          expect(find.text('你的开发主机'), findsOneWidget);
          expect(find.textContaining('test connection failed'), findsOneWidget);
          expect(find.byTooltip('返回'), findsNothing);
          expect(find.byTooltip('配对新主机'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('missing credential stays in hosts and offers pairing', (
    tester,
  ) async {
    final workbench = Workbench(MemoryStore())
      ..initialized = true
      ..hosts = [sampleHost];
    await mount(tester, workbench);
    await tester.tap(find.text(sampleHost.name));
    await tester.pumpAndSettle();
    expect(find.byType(ChatPane), findsNothing);
    expect(find.textContaining('missing device credential'), findsOneWidget);
    expect(find.byTooltip('配对新主机'), findsOneWidget);
    expect(find.byTooltip('返回'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'successful first pairing enters chat without an empty-chat back link',
    (tester) async {
      await mount(tester, PairingWorkbench());
      expect(find.byTooltip('返回'), findsNothing);
      await tester.tap(find.text('配对第一台主机'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField).first,
        jsonEncode({'url': 'https://host.test', 'code': 'a' * 43}),
      );
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('信任并配对'));
      await tester.tap(find.text('信任并配对'));
      await tester.pumpAndSettle();
      expect(find.byType(ChatPane), findsOneWidget);
      expect(find.text('配对开发主机'), findsNothing);
      expect(find.byTooltip('返回'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('offline no-project workspace and approvals remain reachable', (
    tester,
  ) async {
    final workbench = fixtureWorkbench()
      ..projectId = null
      ..projects = []
      ..status = 'offline'
      ..approvals = [
        {
          'id': 'approval',
          'method': 'item/commandExecution/requestApproval',
          'params': {'threadId': 'task', 'command': 'test command'},
        },
      ];
    await mount(tester, workbench, size: const Size(320, 800));
    expect(find.byTooltip('待处理请求'), findsOneWidget);
    await tester.tap(find.byTooltip('打开工作区'));
    await tester.pumpAndSettle();
    expect(find.text('选择远程项目'), findsOneWidget);
    await tester.tap(find.byTooltip('待处理请求'));
    await tester.pumpAndSettle();
    expect(find.text('等待你处理'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('选择远程项目'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(ChatPane), findsOneWidget);
    expect(find.text('1 项请求等待处理'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'removing current host returns to pairing without a chat back link',
    (tester) async {
      final workbench = fixtureWorkbench();
      await mount(tester, workbench);
      await tester.tap(find.text(sampleHost.name));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('仅从手机移除'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(workbench.host, isNull);
      expect(find.byTooltip('返回'), findsNothing);
      expect(find.text('配对第一台主机'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final width in [320.0, 390.0, 1200.0]) {
    for (final theme in ['light', 'dark']) {
      testWidgets(
        'process layout at $width in $theme stays bounded and scrollable',
        (tester) async {
          final workbench = processWorkbench()..theme = theme;
          workbench.timelines['task']!.first['text'] = List.filled(
            40,
            '这是上游提供的思考摘要，用于检查滚动和窄屏布局。',
          ).join('\n\n');
          final key = GlobalKey();
          await mount(tester, workbench, size: Size(width, 900), key: key);
          expect(find.text('正在思考…'), findsOneWidget);
          final innerScroll = find
              .descendant(
                of: find.byType(ChatPane),
                matching: find.byType(SingleChildScrollView),
              )
              .first;
          expect(tester.getSize(innerScroll).height, lessThanOrEqualTo(360));
          expect(find.byTooltip('停止当前任务'), findsOneWidget);
          await tester.enterText(
            find.descendant(
              of: find.byType(ChatPane),
              matching: find.byType(TextField),
            ),
            '下一条指令',
          );
          workbench.clearError();
          await tester.pumpAndSettle();
          expect(find.text('下一条指令'), findsOneWidget);
          final outerList = find.descendant(
            of: find.byType(ChatPane),
            matching: find.byType(ListView),
          );
          final controller = tester.widget<ListView>(outerList).controller!;
          expect(
            controller.offset,
            closeTo(controller.position.maxScrollExtent, 1),
          );
          await screenshot(tester, key, 'process-${width.toInt()}-$theme');
          completeTurn(workbench);
          await tester.pumpAndSettle();
          expect(find.text('思考过程 · 2 项活动'), findsOneWidget);
          expect(find.text('最终回复始终直接展示。'), findsOneWidget);
          await screenshot(
            tester,
            key,
            'process-${width.toInt()}-$theme-collapsed',
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
