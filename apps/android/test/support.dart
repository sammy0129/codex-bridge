import 'dart:async';
import 'dart:convert';

import 'package:codex_bridge/data/models.dart';
import 'package:codex_bridge/data/storage.dart';
import 'package:codex_bridge/data/transport.dart';
import 'package:codex_bridge/data/workbench.dart';

class MemoryStore implements LocalStore {
  final Map<String, Json> data = {};
  final Map<String, String> tokens = {};
  @override
  Future<Json> read(String key) async =>
      asJson(jsonDecode(jsonEncode(data[key] ?? {})));
  @override
  Future<void> write(String key, Json value) async {
    data[key] = asJson(jsonDecode(jsonEncode(value)));
  }

  @override
  Future<String?> token(String hostId) async => tokens[hostId];
  @override
  Future<void> saveToken(String hostId, String token) async {
    tokens[hostId] = token;
  }

  @override
  Future<void> remove(String hostId) async {
    tokens.remove(hostId);
    data.remove('cache-$hostId');
  }
}

class FakeTransport implements BridgeTransport {
  final incoming = StreamController<Json>.broadcast();
  final changes = StreamController<String>.broadcast();
  final List<String> calls = [];
  Future<dynamic> Function(String, Json)? handler;
  Future<void> Function()? onConnect;
  bool closed = false;
  @override
  Stream<Json> get messages => incoming.stream;
  @override
  Stream<String> get statuses => changes.stream;
  @override
  Future<void> connect({required int afterSeq, required String? epoch}) async {
    await onConnect?.call();
  }

  @override
  Future<dynamic> rpc(String method, Json params, {String? requestId}) async {
    calls.add(method);
    if (handler != null) return handler!(method, params);
    return switch (method) {
      'projects/list' => {
        'projects': [
          {
            'id': 'project',
            'name': 'bridge-app',
            'path': 'D:/Projects/bridge-app',
          },
        ],
      },
      'bridge/runtime' => {'threads': [], 'approvals': []},
      'model/list' => {'data': []},
      'thread/list' => {'data': []},
      'thread/read' => {
        'thread': {'id': params['threadId'], 'turns': []},
      },
      'files/list' => {
        'entries': [
          {'name': 'lib', 'isDirectory': true},
          {'name': 'pubspec.yaml', 'isFile': true},
        ],
      },
      'git/status' => {
        'isGit': true,
        'status': ' M lib/main.dart',
        'unstaged': '-old\n+new',
        'staged': '',
      },
      'terminal/list' => {'terminals': []},
      'collaborationMode/list' => {'data': []},
      _ => {},
    };
  }

  @override
  void updateCursor(int seq, String? epoch) {}
  @override
  void reconnect() {}
  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    await incoming.close();
    await changes.close();
  }
}

const sampleHost = Host(
  id: 'host-a',
  name: 'Studio · Windows',
  url: 'https://host-a.test:8787',
  deviceId: 'device-a',
);
Workbench fixtureWorkbench({bool empty = false}) {
  final workbench = Workbench(MemoryStore());
  workbench.initialized = true;
  if (empty) return workbench;
  workbench.host = sampleHost;
  workbench.hosts = [sampleHost];
  workbench.status = 'online';
  workbench.info = {
    'capabilities': ['threads', 'files', 'terminal', 'diff'],
    'ready': true,
    'homeDirectory': 'D:/Projects',
  };
  workbench.projects = [
    {'id': 'project', 'name': 'bridge-app', 'path': 'D:/Projects/bridge-app'},
  ];
  workbench.projectId = 'project';
  workbench.threadId = 'task';
  workbench.threads = [
    {'id': 'task', 'name': '完善远程连接状态'},
    {'id': 'task-2', 'name': '检查文件保存冲突'},
  ];
  workbench.models = [
    {
      'model': 'fixture-model',
      'displayName': '测试模型',
      'defaultReasoningEffort': 'medium',
      'supportedReasoningEfforts': [
        {'reasoningEffort': 'low'},
        {'reasoningEffort': 'medium'},
      ],
    },
  ];
  workbench.model = 'fixture-model';
  workbench.effort = 'medium';
  workbench.modes = [
    {'mode': 'default', 'name': 'Default'},
    {'mode': 'plan', 'name': 'Plan'},
  ];
  workbench.timelines = {
    'task': [
      {
        'id': 'user',
        'type': 'userMessage',
        'content': [
          {'type': 'text', 'text': '完善远程连接状态。断线后继续执行，重连时补齐记录。'},
        ],
      },
      {
        'id': 'command',
        'type': 'commandExecution',
        'command': 'flutter test',
        'status': 'completed',
        'exitCode': 0,
        'aggregatedOutput': 'All tests passed!',
      },
      {
        'id': 'assistant',
        'type': 'agentMessage',
        'text': '已完成连接恢复逻辑。\n\n- 手机离线后，主机继续执行任务。\n- 重连按事件序号补齐记录。\n- 待审批请求不会重复提交。\n\n可以在 **工作区** 查看改动，或继续补充要求。',
      },
    ],
  };
  workbench.transport = FakeTransport();
  return workbench;
}
