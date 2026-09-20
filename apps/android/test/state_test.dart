import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:codex_bridge/data/models.dart';
import 'package:codex_bridge/data/transport.dart';
import 'package:codex_bridge/data/workbench.dart';

import 'support.dart';

void main() {
  test('pairing rejects insecure addresses, URL credentials, paths, and malformed fingerprints', () {
    final code = 'a' * 43;
    expect(
      () => Pairing.fromJson({'url': 'http://host', 'code': code}),
      throwsA(isA<RpcException>()),
    );
    expect(
      () => Pairing.fromJson({'url': 'https://user:secret@host', 'code': code}),
      throwsA(isA<RpcException>()),
    );
    expect(
      () => Pairing.fromJson({'url': 'https://host/path', 'code': code}),
      throwsA(isA<RpcException>()),
    );
    expect(
      () => Pairing.fromJson({
        'url': 'https://host',
        'code': code,
        'fingerprint': '00',
      }),
      throwsA(isA<RpcException>()),
    );
    expect(
      Pairing.fromJson({
        'url': 'https://host:8787',
        'code': code,
        'fingerprint': 'ab' * 32,
      }).origin.port,
      8787,
    );
    expect(certificateMatches([1, 2, 3], '00' * 32), false);
  });
  test('duplicate events do not duplicate text; completion replaces streaming text', () async {
    final storage = MemoryStore();
    final workbench = Workbench(storage);
    workbench.host = sampleHost;
    workbench.receive({
      'type': 'hello',
      'epoch': 'epoch',
      'reset': true,
      'cursor': 0,
      'runtime': {},
    });
    final first = {
      'type': 'event',
      'seq': 1,
      'epoch': 'epoch',
      'method': 'item/agentMessage/delta',
      'params': {'threadId': 'task', 'itemId': 'message', 'delta': 'Hello'},
    };
    workbench.receive(first);
    workbench.receive(first);
    expect(workbench.timelines['task']!.single['text'], 'Hello');
    workbench.receive({
      'type': 'event',
      'seq': 2,
      'epoch': 'epoch',
      'method': 'item/completed',
      'params': {
        'threadId': 'task',
        'item': {
          'id': 'message',
          'type': 'agentMessage',
          'text': 'Hello world',
        },
      },
    });
    await workbench.flush();
    expect(storage.data['cache-host-a']!['cursor'], 2);
    expect(
      asList(asJson(storage.data['cache-host-a']!['timelines'])['task'])
          .single['text'],
      'Hello world',
    );
    workbench.dispose();
  });
  test(
    'approval lifecycle removes resolved entries and expires on upstream loss',
    () {
      final workbench = Workbench(MemoryStore());
      workbench.epoch = 'epoch';
      workbench.receive({
        'type': 'event',
        'seq': 1,
        'epoch': 'epoch',
        'method': 'bridge/approval',
        'params': {
          'id': 'epoch:7',
          'upstreamId': 7,
          'params': {'threadId': 'task'},
        },
      });
      expect(workbench.approvals.length, 1);
      workbench.receive({
        'type': 'event',
        'seq': 2,
        'epoch': 'epoch',
        'method': 'serverRequest/resolved',
        'params': {'threadId': 'task', 'requestId': 7},
      });
      expect(workbench.approvals, isEmpty);
      workbench.runtimeThreads = [
        {'id': 'task', 'state': 'running'},
      ];
      workbench.receive({
        'type': 'event',
        'seq': 3,
        'epoch': 'epoch',
        'method': 'bridge/upstreamLost',
        'params': {'message': 'lost'},
      });
      expect(workbench.runtimeThreads.single['state'], 'unknown');
      workbench.dispose();
    },
  );
  test('switching host does not allow old asynchronous results to overwrite new host state', () async {
    final storage = MemoryStore();
    storage.tokens['host-a'] = 'a';
    storage.tokens['host-b'] = 'b';
    final first = FakeTransport();
    final second = FakeTransport();
    final gate = Completer<dynamic>();
    first.handler = (method, params) async =>
        method == 'projects/list' ? gate.future : {};
    final workbench = Workbench(
      storage,
      factory: (host, token) => host.id == 'host-a' ? first : second,
    );
    await workbench.selectHost(sampleHost);
    final pending = workbench.refresh();
    const other = Host(
      id: 'host-b',
      name: 'Linux',
      url: 'https://host-b',
      deviceId: 'device-b',
    );
    await workbench.selectHost(other);
    gate.complete({
      'projects': [
        {'id': 'stale', 'path': 'C:/old'},
      ],
    });
    await pending;
    expect(workbench.host!.id, 'host-b');
    expect(workbench.projects, isEmpty);
    expect(first.closed, true);
    workbench.dispose();
  });
  test('offline transport does not queue or silently retry a write', () async {
    final socket = SocketBridge(sampleHost, 'not-a-real-token');
    await expectLater(
      socket.rpc('turn/start', {}),
      throwsA(
        isA<RpcException>().having((error) => error.code, 'code', 'OFFLINE'),
      ),
    );
    await socket.close();
  });
  test(
    'switching project during task creation never sends into the new project',
    () async {
      final workbench = Workbench(MemoryStore())..projectId = 'first';
      final transport = FakeTransport();
      final gate = Completer<dynamic>();
      transport.handler = (method, params) async => gate.future;
      workbench.transport = transport;
      final pending = workbench.send('do not misroute', []);
      final assertion = expectLater(
        pending,
        throwsA(
          isA<RpcException>().having(
            (error) => error.code,
            'code',
            'CONTEXT_CHANGED',
          ),
        ),
      );
      workbench.projectId = 'second';
      gate.complete({
        'thread': {'id': 'old-task'},
      });
      await assertion;
      expect(workbench.threadId, isNull);
      expect(transport.calls, ['thread/start']);
      workbench.dispose();
    },
  );
  test('switching task during resume does not redirect the message', () async {
    final workbench = Workbench(MemoryStore())
      ..projectId = 'project'
      ..threadId = 'first';
    final transport = FakeTransport();
    final gate = Completer<dynamic>();
    transport.handler = (method, params) async => gate.future;
    workbench.transport = transport;
    final pending = workbench.send('belongs to first', []);
    final assertion = expectLater(
      pending,
      throwsA(
        isA<RpcException>().having(
          (error) => error.code,
          'code',
          'CONTEXT_CHANGED',
        ),
      ),
    );
    workbench.threadId = 'second';
    gate.complete({});
    await assertion;
    expect(transport.calls, ['thread/resume']);
    workbench.dispose();
  });
}
