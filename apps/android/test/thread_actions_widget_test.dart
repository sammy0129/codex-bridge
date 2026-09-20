import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:codex_bridge/data/models.dart';
import 'package:codex_bridge/data/workbench.dart';
import 'package:codex_bridge/main.dart';
import 'package:codex_bridge/ui/command_composer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

Future<void> mount(
  WidgetTester tester,
  Workbench workbench, {
  Size size = const Size(390, 844),
  GlobalKey? screenshot,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    RepaintBoundary(
      key: screenshot,
      child: ProviderScope(
        overrides: [workbenchProvider.overrideWith((ref) => workbench)],
        child: const BridgeApp(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (size.width < 900) {
    await tester.tap(find.byTooltip('任务列表'));
    await tester.pumpAndSettle();
  }
}

Future<void> actions(WidgetTester tester, {String title = '检查文件保存冲突'}) async {
  await tester.longPress(find.text(title).first);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    final file = File('C:/Windows/Fonts/msyh.ttc');
    if (await file.exists()) {
      final bytes = await file.readAsBytes();
      for (final name in ['Roboto', 'Ahem']) {
        await (FontLoader(
          name,
        )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
      }
    }
    final icons = File(
      'D:/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    );
    if (await icons.exists()) {
      await (FontLoader('MaterialIcons')..addFont(
            Future.value(ByteData.sublistView(await icons.readAsBytes())),
          ))
          .load();
    }
  });

  for (final size in [
    const Size(320, 720),
    const Size(390, 844),
    const Size(1100, 800),
  ]) {
    testWidgets('long press opens actions without selecting at $size', (
      tester,
    ) async {
      final workbench = managedWorkbench();
      await mount(tester, workbench, size: size);
      await actions(tester);
      expect(find.text('归档会话'), findsOneWidget);
      expect(find.text('删除会话'), findsOneWidget);
      expect(workbench.threadId, 'task');
      expect((workbench.transport as FakeTransport).calls, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect((workbench.transport as FakeTransport).calls, isEmpty);
    });
  }

  testWidgets('short press still opens a task without showing actions', (
    tester,
  ) async {
    final workbench = managedWorkbench();
    await mount(tester, workbench);
    await tester.tap(find.text('检查文件保存冲突'));
    await tester.pumpAndSettle();
    expect(workbench.threadId, 'task-2');
    expect(find.text('删除会话'), findsNothing);
    expect(
      (workbench.transport as FakeTransport).calls,
      contains('thread/resume'),
    );
  });

  for (final current in [true, false]) {
    testWidgets(
      'archive from sidebar updates the correct task current=$current',
      (tester) async {
        final workbench = managedWorkbench();
        await mount(tester, workbench);
        await actions(tester, title: current ? '完善远程连接状态' : '检查文件保存冲突');
        await tester.tap(find.text('归档会话'));
        await tester.pumpAndSettle();
        expect(workbench.threadId, current ? isNull : 'task');
        expect(workbench.timelines['task'], isNotEmpty);
        expect(
          workbench.threads.any(
            (entry) => entry['id'] == (current ? 'task' : 'task-2'),
          ),
          isFalse,
        );
        expect((workbench.transport as FakeTransport).calls, [
          'thread/archive',
          'thread/list',
        ]);
      },
    );
  }

  testWidgets(
    'archived sidebar offers restore without opening or creating a task',
    (tester) async {
      final workbench = managedWorkbench();
      await workbench.archiveThread('task-2', false);
      workbench.archived = true;
      await workbench.loadThreads();
      (workbench.transport as FakeTransport).calls.clear();
      await mount(tester, workbench);
      await actions(tester);
      expect(find.text('恢复会话'), findsOneWidget);
      expect(find.text('归档会话'), findsNothing);
      await tester.tap(find.text('恢复会话'));
      await tester.pumpAndSettle();
      expect(workbench.threadId, 'task');
      expect(workbench.threads, isEmpty);
      expect((workbench.transport as FakeTransport).calls, [
        'thread/unarchive',
        'thread/list',
      ]);
    },
  );

  for (final confirm in [false, true]) {
    testWidgets('delete requires explicit confirmation confirm=$confirm', (
      tester,
    ) async {
      final workbench = managedWorkbench();
      await mount(tester, workbench);
      await actions(tester);
      await tester.tap(find.text('删除会话'));
      await tester.pumpAndSettle();
      expect(find.text('永久删除此会话及其历史记录？此操作无法撤销，不会删除项目文件。'), findsOneWidget);
      expect((workbench.transport as FakeTransport).calls, isEmpty);
      await tester.tap(find.text(confirm ? '永久删除' : '取消'));
      await tester.pumpAndSettle();
      expect(workbench.threadId, 'task');
      expect(
        workbench.threads.any((entry) => entry['id'] == 'task-2'),
        !confirm,
      );
      expect(
        (workbench.transport as FakeTransport).calls,
        confirm ? ['thread/delete', 'thread/list'] : isEmpty,
      );
    });
  }

  testWidgets('deleting current task clears chat selection and composer', (
    tester,
  ) async {
    final workbench = managedWorkbench();
    await mount(tester, workbench, size: const Size(1100, 800));
    await tester.enterText(
      find
          .descendant(
            of: find.byType(CommandComposer),
            matching: find.byType(TextField),
          )
          .first,
      '未发送的草稿',
    );
    await actions(tester, title: '完善远程连接状态');
    await tester.tap(find.text('删除会话'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('永久删除'));
    await tester.pumpAndSettle();
    expect(workbench.threadId, isNull);
    expect(find.text('今天想完成什么？'), findsOneWidget);
    expect(workbench.timelines.containsKey('task'), isFalse);
    expect(find.text('未发送的草稿'), findsNothing);
  });

  for (final dismiss in ['back', 'barrier']) {
    testWidgets('dismiss by $dismiss sends nothing', (tester) async {
      final workbench = managedWorkbench();
      await mount(tester, workbench);
      await actions(tester);
      if (dismiss == 'back') {
        await tester.binding.handlePopRoute();
      } else {
        await tester.tapAt(const Offset(380, 100));
      }
      await tester.pumpAndSettle();
      expect(find.text('删除会话'), findsNothing);
      expect((workbench.transport as FakeTransport).calls, isEmpty);
    });
  }

  for (final state in [
    'offline',
    'running',
    'starting',
    'unknown',
    'approval',
    'external',
    'old-bridge',
  ]) {
    testWidgets('menu explains and disables $state actions', (tester) async {
      final workbench = managedWorkbench();
      if (state == 'offline') workbench.status = 'offline';
      if (['running', 'starting', 'unknown'].contains(state)) {
        workbench.runtimeThreads.last['state'] = state;
      }
      if (state == 'approval') {
        workbench.approvals = [
          {
            'id': 'approval',
            'params': {'threadId': 'task-2'},
          },
        ];
      }
      if (state == 'external') workbench.runtimeThreads.removeLast();
      if (state == 'old-bridge') workbench.info['capabilities'] = ['threads'];
      await mount(tester, workbench);
      await actions(tester);
      final tile = tester.widget<ListTile>(
        find.widgetWithText(ListTile, '删除会话'),
      );
      expect(tile.enabled, isFalse);
      final reason = switch (state) {
        'offline' => '连接主机后才能操作',
        'running' || 'starting' => '请等待任务停止后再操作',
        'unknown' => '会话状态未知，请刷新并核实后重新打开',
        'approval' => '请先处理此会话的待审批请求',
        'external' => '不支持操作尚未由 Bridge 管理的会话',
        _ => '请升级主机 Bridge 后删除会话',
      };
      expect(find.text(reason), findsWidgets);
      expect(
        tester.widget<ListTile>(find.widgetWithText(ListTile, '归档会话')).enabled,
        state == 'old-bridge',
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect((workbench.transport as FakeTransport).calls, isEmpty);
    });
  }

  testWidgets('switching project while confirming disables deletion', (
    tester,
  ) async {
    final workbench = managedWorkbench();
    await mount(tester, workbench);
    await actions(tester);
    await tester.tap(find.text('删除会话'));
    await tester.pumpAndSettle();
    await workbench.selectProject('other');
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '永久删除'))
          .onPressed,
      isNull,
    );
    expect(find.text('主机或项目已切换，请重新操作'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(
      (workbench.transport as FakeTransport).calls,
      isNot(contains('thread/delete')),
    );
  });

  testWidgets(
    'pending and failed delete preserve the row and show a Chinese error',
    (tester) async {
      final workbench = managedWorkbench();
      final gate = Completer<Json>();
      (workbench.transport as FakeTransport).handler = (method, params) =>
          gate.future;
      await mount(tester, workbench);
      await actions(tester);
      await tester.tap(find.text('删除会话'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('永久删除'));
      await tester.pumpAndSettle();
      expect(workbench.threadActionBlocked('task-2'), '会话正在处理中');
      expect(workbench.threads, hasLength(2));
      gate.completeError(const RpcException('CODEX_ERROR', 'fixture'));
      await tester.pumpAndSettle();
      expect(workbench.threads, hasLength(2));
      expect(workbench.error, contains('会话操作失败'));
      expect((workbench.transport as FakeTransport).calls, ['thread/delete']);
    },
  );

  for (final dark in [false, true]) {
    testWidgets('long title layout and visual snapshot dark=$dark', (
      tester,
    ) async {
      final workbench = managedWorkbench()..theme = dark ? 'dark' : 'light';
      final title = '检查跨项目长标题会话的归档和永久删除确认边界' * 4;
      workbench.threads.last['name'] = title;
      final screenshot = GlobalKey();
      await mount(
        tester,
        workbench,
        size: const Size(390, 844),
        screenshot: screenshot,
      );
      await actions(tester, title: title);
      expect(tester.takeException(), isNull);
      final boundary =
          screenshot.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        final directory = Directory('../../.local/screenshots');
        await directory.create(recursive: true);
        await File(
          '${directory.path}/thread-actions-${dark ? 'dark' : 'light'}.png',
        ).writeAsBytes(png!.buffer.asUint8List());
      });
    });
  }
}
