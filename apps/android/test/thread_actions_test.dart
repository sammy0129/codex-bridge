import 'dart:async';

import 'package:codex_bridge/data/models.dart';
import 'package:codex_bridge/data/workbench.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void deleted(Workbench workbench, String id) {
  workbench.epoch = 'epoch';
  workbench.receive({
    'type': 'event',
    'epoch': 'epoch',
    'seq': workbench.cursor + 1,
    'method': 'thread/deleted',
    'params': {'threadId': id},
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final current in [true, false]) {
    test('delete cleans only its target, current=$current', () async {
      final workbench = managedWorkbench();
      addTearDown(workbench.dispose);
      final target = current ? 'task' : 'task-2';
      workbench.timelines['task-2'] = [
        {'id': 'other', 'type': 'agentMessage', 'text': 'other'},
      ];
      workbench.imageDrafts.bind('host-a', 'project', 'task');
      final draft = workbench.imageDrafts.id;
      await workbench.deleteThread(target);
      expect(workbench.threads.any((entry) => entry['id'] == target), isFalse);
      expect(workbench.timelines.containsKey(target), isFalse);
      expect(
        workbench.runtimeThreads.any((entry) => entry['id'] == target),
        isFalse,
      );
      expect(workbench.threadId, current ? isNull : 'task');
      expect(workbench.imageDrafts.id == draft, !current);
      expect(
        workbench.timelines.containsKey(current ? 'task-2' : 'task'),
        isTrue,
      );
      await workbench.flush();
      final saved = (workbench.storage as MemoryStore).data['cache-host-a']!;
      expect(saved['deletedThreads'], contains(target));
      expect(asJson(saved['timelines']).containsKey(target), isFalse);
    });
  }

  test(
    'archive preserves history, restore does not open or create a thread',
    () async {
      final workbench = managedWorkbench();
      addTearDown(workbench.dispose);
      await workbench.archiveThread('task', false);
      expect(workbench.threadId, isNull);
      expect(workbench.timelines['task'], isNotEmpty);
      workbench.archived = true;
      await workbench.loadThreads();
      expect(workbench.threads.single['id'], 'task');
      await workbench.archiveThread('task', true);
      expect(workbench.threads, isEmpty);
      expect(workbench.threadId, isNull);
      expect(
        (workbench.transport as FakeTransport).calls,
        isNot(contains('thread/start')),
      );
      expect(
        (workbench.transport as FakeTransport).calls,
        isNot(contains('thread/resume')),
      );
    },
  );

  for (final state in [
    'offline',
    'running',
    'starting',
    'unknown',
    'approval',
    'external',
    'other-project',
    'old-bridge',
  ]) {
    test('blocked $state action sends no mutation', () async {
      final workbench = managedWorkbench();
      addTearDown(workbench.dispose);
      if (state == 'offline') workbench.status = 'offline';
      if (['running', 'starting', 'unknown'].contains(state)) {
        workbench.runtimeThreads.first['state'] = state;
      }
      if (state == 'approval') {
        workbench.approvals = [
          {
            'id': 'pending',
            'params': {'threadId': 'task'},
          },
        ];
      }
      if (state == 'external') workbench.runtimeThreads = [];
      if (state == 'other-project') {
        workbench.runtimeThreads.first['project'] = 'other';
      }
      if (state == 'old-bridge') workbench.info['capabilities'] = ['threads'];
      expect(workbench.threadActionBlocked('task', delete: true), isNotNull);
      await expectLater(
        workbench.deleteThread('task'),
        throwsA(isA<RpcException>()),
      );
      expect((workbench.transport as FakeTransport).calls, isEmpty);
      if (state == 'old-bridge') {
        expect(workbench.threadActionBlocked('task'), isNull);
        await workbench.archiveThread('task', false);
      }
    });
  }

  test(
    'pending delete rejects duplicate actions and opening the same task',
    () async {
      final workbench = managedWorkbench();
      addTearDown(workbench.dispose);
      final transport = workbench.transport as FakeTransport;
      final gate = Completer<Json>();
      transport.handler = (method, params) async =>
          method == 'thread/delete' ? gate.future : {'data': []};
      final pending = workbench.deleteThread('task');
      await expectLater(
        workbench.deleteThread('task'),
        throwsA(isA<RpcException>()),
      );
      await expectLater(
        workbench.archiveThread('task', false),
        throwsA(isA<RpcException>()),
      );
      await expectLater(
        workbench.openThread('task'),
        throwsA(isA<RpcException>()),
      );
      expect(transport.calls, ['thread/delete']);
      gate.complete({});
      await pending;
    },
  );

  for (final code in ['CODEX_ERROR', 'OUTCOME_UNKNOWN', 'UPSTREAM_LOST']) {
    test(
      'failure $code preserves data and does not automatically retry',
      () async {
        final workbench = managedWorkbench();
        addTearDown(workbench.dispose);
        final transport = workbench.transport as FakeTransport;
        transport.handler = (method, params) async =>
            throw RpcException(code, 'fixture error');
        await expectLater(
          workbench.deleteThread('task'),
          throwsA(isA<RpcException>()),
        );
        expect(workbench.threadId, 'task');
        expect(workbench.timelines['task'], isNotEmpty);
        expect(workbench.threads.any((entry) => entry['id'] == 'task'), isTrue);
        expect(transport.calls, ['thread/delete']);
        expect(
          workbench.runtimeThreads.first['state'],
          code == 'CODEX_ERROR' ? 'idle' : 'unknown',
        );
      },
    );
  }

  test(
    'successful deletion is not reported as failed when refresh fails',
    () async {
      final workbench = managedWorkbench();
      addTearDown(workbench.dispose);
      (workbench.transport as FakeTransport).handler = (method, params) async {
        if (method == 'thread/list') {
          throw const RpcException('OFFLINE', 'fixture');
        }
        return {};
      };
      await workbench.deleteThread('task');
      expect(workbench.threadId, isNull);
      expect(workbench.error, '操作已完成，但刷新列表失败，请稍后刷新');
    },
  );

  test(
    'a stale menu context cannot mutate after switching projects and back',
    () async {
      final workbench = managedWorkbench();
      addTearDown(workbench.dispose);
      final scope = workbench.threadActionContext;
      await workbench.selectProject('other');
      await workbench.selectProject('project');
      await workbench.deleteThread('task', context: scope);
      await workbench.archiveThread('task', false, context: scope);
      expect(
        (workbench.transport as FakeTransport).calls.where(
          (method) => method != 'thread/list',
        ),
        isEmpty,
      );
    },
  );

  test(
    'deletion invalidates late list, read and open results and event replays',
    () async {
      final workbench = managedWorkbench();
      addTearDown(workbench.dispose);
      final list = Completer<Json>();
      final read = Completer<Json>();
      final open = Completer<Json>();
      (workbench.transport as FakeTransport).handler = (method, params) async =>
          switch (method) {
            'thread/list' => list.future,
            'thread/read' => read.future,
            'thread/resume' => open.future,
            _ => {},
          };
      final operations = [
        workbench.loadThreads(),
        workbench.readThread('task'),
        workbench.openThread('task'),
      ];
      deleted(workbench, 'task');
      deleted(workbench, 'task');
      list.complete({
        'data': [
          {'id': 'task'},
        ],
      });
      read.complete({
        'thread': {
          'id': 'task',
          'turns': [
            {
              'items': [
                {'id': 'stale', 'type': 'agentMessage', 'text': 'stale'},
              ],
            },
          ],
        },
      });
      open.complete({
        'thread': {'id': 'task', 'turns': []},
      });
      await Future.wait(operations);
      workbench.receive({
        'type': 'event',
        'epoch': 'epoch',
        'seq': workbench.cursor + 1,
        'method': 'item/agentMessage/delta',
        'params': {'threadId': 'task', 'itemId': 'stale', 'delta': 'stale'},
      });
      workbench.receive({
        'type': 'event',
        'epoch': 'epoch',
        'seq': workbench.cursor + 1,
        'method': 'bridge/approval',
        'params': {
          'id': 'stale',
          'params': {'threadId': 'task'},
        },
      });
      expect(workbench.threadId, isNull);
      expect(workbench.timelines.containsKey('task'), isFalse);
      expect(workbench.threads.any((entry) => entry['id'] == 'task'), isFalse);
      expect(workbench.approvals, isEmpty);
    },
  );

  test(
    'a deletion notification is authoritative even when its reply is lost',
    () async {
      final workbench = managedWorkbench();
      addTearDown(workbench.dispose);
      (workbench.transport as FakeTransport).handler = (method, params) async {
        deleted(workbench, 'task');
        throw const RpcException('OUTCOME_UNKNOWN', 'fixture');
      };
      await workbench.deleteThread('task');
      expect(workbench.threadId, isNull);
      expect(workbench.error, isNull);
    },
  );

  test('an in-flight delete affects only its original host, including cached history', () async {
    final workbench = managedWorkbench();
    addTearDown(workbench.dispose);
    final gate = Completer<Json>();
    (workbench.transport as FakeTransport).handler = (method, params) =>
        gate.future;
    final pending = workbench.deleteThread('task');
    const other = Host(
      id: 'host-b',
      name: 'other',
      url: 'https://other',
      deviceId: 'other',
    );
    await workbench.selectHost(other);
    workbench.projectId = 'project';
    workbench.threadId = 'task';
    workbench.threads = [
      {'id': 'task', 'name': 'other host task'},
    ];
    workbench.timelines['task'] = [
      {'id': 'other', 'text': 'other host history'},
    ];
    gate.complete({});
    await pending;
    for (var tick = 0; tick < 8; tick++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(workbench.host?.id, 'host-b');
    expect(workbench.threadId, 'task');
    expect(workbench.timelines['task']!.single['text'], 'other host history');
    expect(workbench.error, isNull);
    final cache = (workbench.storage as MemoryStore).data['cache-host-a']!;
    expect(asJson(cache['timelines']).containsKey('task'), isFalse);
    expect(cache['deletedThreads'], contains('task'));
  });

  test(
    'deleted tombstones survive host reopening and filter stale snapshots',
    () async {
      final workbench = managedWorkbench();
      deleted(workbench, 'task');
      await workbench.flush();
      final storage = workbench.storage as MemoryStore;
      workbench.dispose();
      final cache = storage.data['cache-host-a']!;
      cache['threads'] = [
        {'id': 'task'},
      ];
      cache['threadId'] = 'task';
      cache['timelines'] = {
        'task': [
          {'id': 'stale', 'type': 'agentMessage', 'text': 'stale'},
        ],
      };
      final restored = Workbench(storage);
      addTearDown(restored.dispose);
      await restored.selectHost(sampleHost);
      expect(restored.threads, isEmpty);
      expect(restored.timelines, isEmpty);
      expect(restored.threadId, isNull);
    },
  );
}
