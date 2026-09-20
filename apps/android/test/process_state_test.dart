import 'dart:convert';

import 'package:codex_bridge/data/models.dart';
import 'package:codex_bridge/data/workbench.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  late Workbench workbench;
  late MemoryStore storage;

  setUp(() {
    storage = MemoryStore();
    workbench = Workbench(storage)
      ..host = sampleHost
      ..epoch = 'epoch';
  });
  tearDown(() => workbench.dispose());

  void event(String method, Json params, {int? sequence}) {
    workbench.receive({
      'type': 'event',
      'epoch': 'epoch',
      'seq': sequence ?? workbench.cursor + 1,
      'method': method,
      'params': {'threadId': 'task', ...params},
    });
  }

  test(
    'summary deltas merge once and preserve summary paragraph boundaries',
    () async {
      final delta = {
        'turnId': 'turn-1',
        'itemId': 'reasoning',
        'summaryIndex': 0,
        'delta': '先检查',
      };
      event('item/reasoning/summaryTextDelta', delta, sequence: 1);
      event('item/reasoning/summaryTextDelta', delta, sequence: 1);
      event('item/reasoning/summaryTextDelta', {...delta, 'delta': '项目。'});
      event('item/reasoning/summaryTextDelta', {
        ...delta,
        'summaryIndex': 1,
        'delta': '再运行测试。',
      });
      expect(workbench.timelines['task']!.single, {
        'id': 'reasoning',
        'type': 'reasoning',
        'turnId': 'turn-1',
        'summary': ['先检查项目。', '再运行测试。'],
        'text': '先检查项目。\n\n再运行测试。',
      });
      event('item/reasoning/textDelta', {
        ...delta,
        'delta': 'RAW_REASONING_MUST_NOT_APPEAR',
      });
      expect(workbench.cursor, 4);
      await workbench.flush();
      expect(storage.data['cache-host-a']!['cursor'], 4);
      expect(jsonEncode(workbench.timelines), isNot(contains('RAW_REASONING')));
      expect(jsonEncode(storage.data), isNot(contains('RAW_REASONING')));
    },
  );

  test(
    'completed reasoning uses authoritative summary and drops raw content',
    () {
      event('item/started', {
        'turnId': 'turn-1',
        'item': {
          'id': 'reasoning',
          'type': 'reasoning',
          'summary': [],
          'content': ['RAW'],
        },
      });
      expect(workbench.timelines['task'] ?? [], isEmpty);
      event('item/reasoning/summaryTextDelta', {
        'turnId': 'turn-1',
        'itemId': 'reasoning',
        'delta': '部分摘要',
      });
      event('item/completed', {
        'turnId': 'turn-1',
        'item': {
          'id': 'reasoning',
          'type': 'reasoning',
          'summary': ['完整摘要'],
          'content': ['RAW'],
        },
      });
      final item = workbench.timelines['task']!.single;
      expect(item['text'], '完整摘要');
      expect(item['turnId'], 'turn-1');
      expect(item.containsKey('content'), isFalse);
    },
  );

  test('turn plan updates replace the same process activity', () {
    for (final status in ['inProgress', 'completed']) {
      event('turn/plan/updated', {
        'turnId': 'turn-1',
        'explanation': '验证改动',
        'plan': [
          {'step': '执行测试', 'status': status},
        ],
      });
    }
    expect(workbench.timelines['task']!.single['type'], 'plan');
    expect(workbench.timelines['task']!.single['turnId'], 'turn-1');
    expect(workbench.timelines['task']!.single['text'], '验证改动\n\n- 执行测试（已完成）');
  });

  test('all process events retain explicit or running turn identity', () {
    event('turn/started', {
      'turn': {'id': 'turn-1'},
    });
    event('item/reasoning/summaryTextDelta', {
      'itemId': 'reasoning',
      'delta': '摘要',
    });
    event('item/plan/delta', {'itemId': 'plan', 'delta': '计划'});
    event('item/commandExecution/outputDelta', {
      'itemId': 'command',
      'delta': 'output',
    });
    for (final type in ['fileChange', 'mcpToolCall', 'agentMessage']) {
      event('item/started', {
        'item': {'id': type, 'type': type},
      });
    }
    event('turn/diff/updated', {'turnId': 'turn-1', 'diff': '+change'});
    expect(workbench.timelines['task'], hasLength(7));
    expect(
      workbench.timelines['task']!.map((item) => item['turnId']),
      everyElement('turn-1'),
    );
    event('item/plan/delta', {
      'turnId': 'turn-2',
      'itemId': 'other-plan',
      'delta': '另一个计划',
    });
    expect(workbench.timelines['task']!.last['turnId'], 'turn-2');
    event('turn/completed', {
      'turn': {'id': 'turn-1'},
    });
    expect(workbench.runtimeThreads, isEmpty);
    event('item/completed', {
      'item': {
        'id': 'command',
        'type': 'commandExecution',
        'status': 'completed',
      },
    });
    expect(
      workbench.timelines['task']!.firstWhere(
        (item) => item['id'] == 'command',
      )['turnId'],
      'turn-1',
    );
  });

  for (final operation in ['read', 'resume']) {
    test(
      'history $operation fills turn ids and exposes summaries only',
      () async {
        workbench.transport = FakeTransport()
          ..handler = (method, params) async => {
            'thread': {
              'id': 'task',
              'turns': [
                for (final turnId in ['first', 'second'])
                  {
                    'id': turnId,
                    'items': [
                      {
                        'id': '$turnId-reasoning',
                        'type': 'reasoning',
                        'summary': ['摘要一', '摘要二'],
                        'content': ['RAW_SECRET'],
                      },
                      {
                        'id': '$turnId-empty',
                        'type': 'reasoning',
                        'summary': [],
                        'content': ['RAW_SECRET'],
                      },
                      {'id': '$turnId-plan', 'type': 'plan', 'text': '计划'},
                      {'id': '$turnId-command', 'type': 'commandExecution'},
                      {'id': '$turnId-files', 'type': 'fileChange'},
                      {'id': '$turnId-mcp', 'type': 'mcpToolCall'},
                      {
                        'id': '$turnId-reply',
                        'type': 'agentMessage',
                        'text': '最终回复',
                      },
                    ],
                  },
              ],
            },
          };
        if (operation == 'read') {
          await workbench.readThread('task');
        } else {
          await workbench.openThread('task');
        }
        final items = workbench.timelines['task']!;
        expect(items, hasLength(12));
        expect(
          items.take(6).map((item) => item['turnId']),
          everyElement('first'),
        );
        expect(
          items.skip(6).map((item) => item['turnId']),
          everyElement('second'),
        );
        expect(items.first['text'], '摘要一\n\n摘要二');
        expect(jsonEncode(items), isNot(contains('RAW_SECRET')));
      },
    );
  }

  test(
    'old cached reasoning is sanitized without inventing turn ids',
    () async {
      storage.data['cache-host-a'] = {
        'timelines': {
          'task': [
            {
              'id': 'summary',
              'type': 'reasoning',
              'summary': ['缓存摘要'],
              'content': ['RAW'],
            },
            {
              'id': 'raw',
              'type': 'reasoning',
              'content': ['RAW'],
            },
            {'id': 'command', 'type': 'commandExecution'},
          ],
        },
      };
      workbench.host = null;
      await workbench.selectHost(sampleHost);
      expect(workbench.timelines['task'], hasLength(2));
      expect(workbench.timelines['task']!.first['text'], '缓存摘要');
      expect(workbench.timelines['task']!.first['turnId'], isNull);
      expect(jsonEncode(workbench.timelines), isNot(contains('RAW')));
    },
  );
}
