import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:uuid/uuid.dart';

import 'models.dart';
import 'storage.dart';
import 'transport.dart';
import 'chat_images.dart';
import 'image_drafts.dart';

final workbenchProvider = ChangeNotifierProvider<Workbench>((ref) {
  final workbench = Workbench(DeviceStore());
  unawaited(workbench.initialize());
  return workbench;
});

typedef TransportFactory = BridgeTransport Function(Host host, String token);

class Workbench extends ChangeNotifier {
  final LocalStore storage;
  final TransportFactory factory;
  final events = StreamController<Json>.broadcast();
  final imageLoader = ChatImageLoader();
  late final imageDrafts = ImageDraftController(storage, upload: upload);
  Workbench(this.storage, {TransportFactory? factory})
    : factory = factory ?? ((host, token) => SocketBridge(host, token));
  List<Host> hosts = [];
  Host? host;
  List<Json> projects = [];
  List<Json> threads = [];
  List<Json> models = [];
  List<Json> modes = [];
  List<Json> skills = [];
  List<Json> mcp = [];
  List<Json> approvals = [];
  List<Json> runtimeThreads = [];
  Map<String, List<Json>> timelines = {};
  Json info = {};
  String? projectId;
  String? threadId;
  String? model;
  String? effort;
  String mode = 'default';
  String permissionMode = 'danger-full-access';
  String theme = 'system';
  String status = 'offline';
  String? error;
  String? epoch;
  int cursor = 0;
  bool initialized = false;
  bool loading = false;
  bool archived = false;
  String query = '';
  String? nextCursor;
  BridgeTransport? transport;
  StreamSubscription<Json>? _messages;
  StreamSubscription<String>? _statuses;
  Timer? _saveTimer;
  int _generation = 0;
  bool _disposed = false;

  bool get online => status == 'online';
  Json? get project =>
      projects.where((value) => value['id'] == projectId).firstOrNull;
  Json? get currentThread =>
      threads.where((value) => value['id'] == threadId).firstOrNull;
  List<Json> get items => timelines[threadId] ?? [];
  Json? get running => runtimeThreads
      .where(
        (value) =>
            value['id'] == threadId &&
            ['running', 'starting'].contains(value['state']),
      )
      .firstOrNull;
  List<Json> get currentApprovals => approvals
      .where((value) => asJson(value['params'])['threadId'] == threadId)
      .toList();
  bool supports(String capability) =>
      (info['capabilities'] as List? ?? []).contains(capability);

  Future<void> initialize() async {
    try {
      final settings = await storage.read('settings');
      hosts = asList(settings['hosts']).map(Host.fromJson).toList();
      theme = settings['theme']?.toString() ?? 'system';
      initialized = true;
      notifyListeners();
      final selected =
          hosts
              .where((entry) => entry.id == settings['activeHost'])
              .firstOrNull ??
          hosts.firstOrNull;
      if (selected != null) await selectHost(selected);
    } catch (failure) {
      initialized = true;
      showError(failure);
    }
  }

  Future<void> settings() => storage.write('settings', {
    'hosts': hosts.map((entry) => entry.toJson()).toList(),
    'activeHost': host?.id,
    'theme': theme,
  });
  void setTheme(String value) {
    theme = value;
    notifyListeners();
    unawaited(settings());
  }

  Future<void> pair(Pairing pairing, String name) async {
    final result = await httpJson(
      pairing.origin,
      '/v1/pair',
      fingerprint: pairing.fingerprint,
      body: {
        'code': pairing.code,
        'deviceName': name,
        'acceptFullAccess': true,
      },
    );
    final id = const Uuid().v4();
    final info = asJson(result['info']);
    final paired = Host(
      id: id,
      name: info['hostName']?.toString() ?? name,
      url: pairing.origin.origin,
      fingerprint: pairing.fingerprint,
      deviceId: result['deviceId'] as String,
      info: info,
    );
    await storage.saveToken(id, result['token'] as String);
    hosts = [...hosts, paired];
    await settings();
    await selectHost(paired);
  }

  Future<void> selectHost(Host selected) async {
    final generation = ++_generation;
    imageLoader.cache.clear();
    imageDrafts.bind(null, null, null);
    await flush();
    await _messages?.cancel();
    await _statuses?.cancel();
    await transport?.close();
    if (generation != _generation) return;
    transport = null;
    host = selected;
    status = 'connecting';
    error = null;
    projects = [];
    threads = [];
    timelines = {};
    models = [];
    modes = [];
    skills = [];
    mcp = [];
    approvals = [];
    runtimeThreads = [];
    projectId = null;
    threadId = null;
    model = null;
    effort = null;
    mode = 'default';
    permissionMode = 'danger-full-access';
    epoch = null;
    cursor = 0;
    info = selected.info;
    archived = false;
    nextCursor = null;
    query = '';
    notifyListeners();
    final cache = await storage.read('cache-${selected.id}');
    if (generation != _generation) return;
    projects = asList(cache['projects']);
    threads = asList(cache['threads']);
    timelines = asJson(cache['timelines']).map(
      (key, value) => MapEntry(
        key,
        asList(value).map(_normalizeTimelineItem).whereType<Json>().toList(),
      ),
    );
    projectId = cache['projectId'] as String?;
    threadId = cache['threadId'] as String?;
    imageDrafts.bind(selected.id, projectId, threadId);
    epoch = cache['epoch'] as String?;
    cursor = cache['cursor'] as int? ?? 0;
    approvals = asList(cache['approvals']);
    runtimeThreads = asList(cache['runtimeThreads']);
    final token = await storage.token(selected.id);
    if (generation != _generation) return;
    if (token == null) {
      status = 'Pair again: missing device credential';
      notifyListeners();
      return;
    }
    final connection = factory(selected, token);
    transport = connection;
    _messages = connection.messages.listen((message) {
      if (generation == _generation) receive(message);
    });
    _statuses = connection.statuses.listen((value) {
      if (generation == _generation) {
        status = value;
        notifyListeners();
      }
    });
    await settings();
    await connection.connect(afterSeq: cursor, epoch: epoch);
    notifyListeners();
  }

  Future<void> removeHost(Host removed, {bool revoke = false}) async {
    imageLoader.cache.clear();
    if (revoke) {
      final token = await storage.token(removed.id);
      await httpJson(
        Uri.parse(removed.url),
        '/v1/devices/revoke',
        token: token,
        fingerprint: removed.fingerprint,
        body: {'deviceId': removed.deviceId},
      );
    }
    if (host?.id == removed.id) {
      imageDrafts.bind(null, null, null);
      ++_generation;
      _saveTimer?.cancel();
      await _messages?.cancel();
      await _statuses?.cancel();
      await transport?.close();
      transport = null;
      host = null;
      projects = [];
      threads = [];
      timelines = {};
      approvals = [];
      threadId = null;
      projectId = null;
      status = 'offline';
    }
    hosts = hosts.where((value) => value.id != removed.id).toList();
    await storage.remove(removed.id);
    await settings();
    notifyListeners();
  }

  void receive(Json message) {
    if (message['type'] == 'hello') {
      info = message;
      epoch = message['epoch'] as String?;
      final runtime = asJson(message['runtime']);
      approvals = asList(runtime['approvals']);
      runtimeThreads = asList(runtime['threads']);
      if (message['reset'] == true) {
        cursor = message['cursor'] as int? ?? 0;
      }
    } else if (message['type'] == 'synced') {
      cursor = message['cursor'] as int;
      epoch = message['epoch'] as String;
      transport?.updateCursor(cursor, epoch);
      events.add({
        'method': 'bridge/synced',
        'params': <String, dynamic>{},
        'seq': cursor,
      });
      unawaited(refresh().catchError(showError));
    } else if (message['type'] == 'event') {
      final sequence = message['seq'] as int;
      if (message['epoch'] != epoch || sequence <= cursor) return;
      cursor = sequence;
      transport?.updateCursor(cursor, epoch);
      reduceEvent(message);
      events.add(message);
    }
    notifyListeners();
    _scheduleSave();
  }

  String? _eventTurnId(Json params, String task) {
    final direct = params['turnId']?.toString();
    if (direct != null && direct.isNotEmpty) return direct;
    return runtimeThreads
        .where((value) => value['id'] == task)
        .firstOrNull?['turn']
        ?.toString();
  }

  Json? _normalizeTimelineItem(Json item) {
    if (item['type'] != 'reasoning') return item;
    final summary = item['summary'] is List
        ? (item['summary'] as List).whereType<String>().toList()
        : [if (item['content'] == null) item['text']?.toString() ?? ''];
    final text = summary.where((part) => part.isNotEmpty).join('\n\n');
    if (text.trim().isEmpty) return null;
    return {
      'id': item['id'],
      'type': 'reasoning',
      if (item['turnId'] != null) 'turnId': item['turnId'],
      'summary': summary,
      'text': text,
    };
  }

  List<Json> _timelineFromTurns(dynamic turns) => asList(turns)
      .expand((turn) {
        final turnId = turn['id']?.toString();
        return asList(turn['items']).map(
          (item) => {
            ...item,
            if (turnId != null && item['turnId'] == null) 'turnId': turnId,
          },
        );
      })
      .map(_normalizeTimelineItem)
      .whereType<Json>()
      .toList();

  void reduceEvent(Json event) {
    final method = event['method'];
    final params = asJson(event['params']);
    final task = params['threadId'] as String?;
    if (method == 'bridge/approval') {
      approvals.removeWhere((value) => value['id'] == params['id']);
      approvals.add(params);
    }
    if (method == 'bridge/approvalResolved') {
      approvals.removeWhere((value) => value['id'] == params['id']);
    }
    if (method == 'serverRequest/resolved') {
      approvals.removeWhere(
        (value) => value['upstreamId'] == params['requestId'],
      );
    }
    if (method == 'bridge/upstreamLost') {
      error = params['message']?.toString();
      for (final thread in runtimeThreads) {
        if (['running', 'starting'].contains(thread['state'])) {
          thread['state'] = 'unknown';
        }
      }
      approvals = [];
    }
    if (task == null) return;
    if (method == 'turn/started') {
      runtimeThreads.removeWhere((value) => value['id'] == task);
      runtimeThreads.add({
        'id': task,
        'state': 'running',
        'turn': asJson(params['turn'])['id'],
      });
    }
    if (method == 'turn/completed') {
      runtimeThreads.removeWhere((value) => value['id'] == task);
      approvals.removeWhere(
        (value) => asJson(value['params'])['threadId'] == task,
      );
      final failure = asJson(params['turn'])['error'];
      if (failure != null) error = asJson(failure)['message']?.toString();
    }
    final turnId = _eventTurnId(params, task);
    if (method == 'item/started' || method == 'item/completed') {
      final item = asJson(params['item']);
      if (item['id'] != null) {
        final normalized = _normalizeTimelineItem({
          ...item,
          if (turnId != null && item['turnId'] == null) 'turnId': turnId,
        });
        if (normalized != null) _putItem(task, normalized);
      }
    }
    if (method == 'item/reasoning/summaryTextDelta') {
      final id = params['itemId']?.toString();
      if (id == null) return;
      final timeline = timelines.putIfAbsent(task, () => []);
      final existing = timeline.where((item) => item['id'] == id).firstOrNull;
      final summary = (existing?['summary'] as List? ?? [])
          .cast<String>()
          .toList();
      final summaryIndex = params['summaryIndex'] as int? ?? 0;
      if (summaryIndex < 0) return;
      while (summary.length <= summaryIndex) {
        summary.add('');
      }
      summary[summaryIndex] += params['delta']?.toString() ?? '';
      _putItem(task, {
        ...?existing,
        'id': id,
        'type': 'reasoning',
        'turnId': ?turnId,
        'summary': summary,
        'text': summary.where((part) => part.isNotEmpty).join('\n\n'),
      });
    }
    if (method == 'item/agentMessage/delta' || method == 'item/plan/delta') {
      final id = params['itemId']?.toString();
      if (id == null) return;
      final timeline = timelines.putIfAbsent(task, () => []);
      final existing = timeline.where((item) => item['id'] == id).firstOrNull;
      _putItem(task, {
        ...?existing,
        'id': id,
        'type': method == 'item/plan/delta' ? 'plan' : 'agentMessage',
        ...?(turnId == null ? null : {'turnId': turnId}),
        'text': '${existing?['text'] ?? ''}${params['delta'] ?? ''}',
      });
    }
    if (method == 'item/commandExecution/outputDelta') {
      final timeline = timelines.putIfAbsent(task, () => []);
      final existing = timeline
          .where((item) => item['id'] == params['itemId'])
          .firstOrNull;
      final output =
          '${existing?['aggregatedOutput'] ?? ''}${params['delta'] ?? ''}';
      _putItem(task, {
        ...?existing,
        'id': params['itemId'],
        'type': 'commandExecution',
        ...?(turnId == null ? null : {'turnId': turnId}),
        'aggregatedOutput': output.length > 128000
            ? output.substring(output.length - 128000)
            : output,
      });
    }
    if (method == 'turn/diff/updated') {
      _putItem(task, {
        'id': 'diff-${params['turnId']}',
        'type': 'turnDiff',
        ...?(turnId == null ? null : {'turnId': turnId}),
        'text': params['diff'],
      });
    }
    if (method == 'turn/plan/updated') {
      final explanation = params['explanation']?.toString() ?? '';
      final steps = asList(params['plan'])
          .map((step) {
            final status = switch (step['status']) {
              'completed' => '已完成',
              'inProgress' => '进行中',
              _ => '待处理',
            };
            return '- ${step['step']}（$status）';
          })
          .join('\n');
      _putItem(task, {
        'id': 'turn-plan-$turnId',
        'type': 'plan',
        'turnId': ?turnId,
        'text': [
          explanation,
          steps,
        ].where((part) => part.isNotEmpty).join('\n\n'),
      });
    }
    if (method == 'error') {
      error = asJson(params['error'])['message']?.toString();
    }
  }

  void _putItem(String task, Json item) {
    final timeline = timelines.putIfAbsent(task, () => []);
    final index = timeline.indexWhere((value) => value['id'] == item['id']);
    if (index < 0) {
      timeline.add(item);
    } else {
      timeline[index] = {...timeline[index], ...item};
    }
    if (timeline.length > 1000) timeline.removeRange(0, timeline.length - 1000);
  }

  Future<dynamic> rpc(String method, [Json params = const {}]) {
    final connection = transport;
    if (connection == null) {
      throw const RpcException('OFFLINE', 'Select and connect a host first.');
    }
    return connection.rpc(method, params);
  }

  Future<void> refresh() async {
    final generation = _generation;
    final result = asJson(await rpc('projects/list'));
    if (generation != _generation) return;
    projects = asList(result['projects']);
    if (!projects.any((value) => value['id'] == projectId)) {
      projectId = projects.firstOrNull?['id'] as String?;
      threadId = null;
    }
    final runtime = asJson(await rpc('bridge/runtime'));
    if (generation != _generation) return;
    runtimeThreads = asList(runtime['threads']);
    approvals = asList(runtime['approvals']);
    if (info['ready'] == true) {
      final modelResult = asJson(await rpc('model/list', {'limit': 100}));
      if (generation != _generation) return;
      models = asList(modelResult['data']);
      model ??=
          (models.where((value) => value['isDefault'] == true).firstOrNull ??
                  models.firstOrNull)?['model']
              as String?;
      effort ??=
          models
                  .where((value) => value['model'] == model)
                  .firstOrNull?['defaultReasoningEffort']
              as String?;
      try {
        final result = asJson(await rpc('collaborationMode/list'));
        if (generation == _generation) modes = asList(result['data']);
      } on RpcException {
        modes = [];
      }
      await loadThreads();
      if (threadId != null) await readThread(threadId!);
    }
    notifyListeners();
    _scheduleSave();
  }

  Future<void> selectProject(String id) async {
    projectId = id;
    threadId = null;
    imageDrafts.bind(host?.id, id, null);
    threads = [];
    query = '';
    archived = false;
    notifyListeners();
    await loadThreads();
    _scheduleSave();
  }

  Future<void> addProject(String path, String name) async {
    final generation = _generation;
    final result = asJson(
      await rpc('projects/add', {'path': path, 'name': name}),
    );
    if (generation != _generation) return;
    projects = [
      ...projects.where((entry) => entry['id'] != result['id']),
      result,
    ];
    await selectProject(result['id'] as String);
  }

  Future<void> loadThreads({bool more = false}) async {
    if (projectId == null) return;
    final generation = _generation;
    final selected = projectId;
    final search = query;
    final archiveFilter = archived;
    final result = asJson(
      await rpc('thread/list', {
        'projectId': selected,
        'limit': 50,
        'archived': archived,
        if (query.isNotEmpty) 'searchTerm': query,
        if (more && nextCursor != null) 'cursor': nextCursor,
      }),
    );
    if (generation != _generation ||
        selected != projectId ||
        search != query ||
        archiveFilter != archived) {
      return;
    }
    final data = asList(result['data']);
    threads = more
        ? [
            ...threads,
            ...data.where(
              (value) => !threads.any((entry) => entry['id'] == value['id']),
            ),
          ]
        : data;
    nextCursor = result['nextCursor'] as String?;
    notifyListeners();
    _scheduleSave();
  }

  Future<void> readThread(String id) async {
    final generation = _generation;
    final result = asJson(
      await rpc('thread/read', {'threadId': id, 'includeTurns': true}),
    );
    if (generation != _generation) return;
    final thread = asJson(result['thread']);
    timelines[id] = _timelineFromTurns(thread['turns']);
    notifyListeners();
    _scheduleSave();
  }

  Future<void> openThread(
    String id, {
    bool confirmStopped = false,
    bool fork = false,
  }) async {
    final generation = _generation;
    final selected = projectId;
    final result = asJson(
      await rpc(fork ? 'thread/fork' : 'thread/resume', {
        'threadId': id,
        'projectId': projectId,
        'permissionMode': permissionMode,
        if (confirmStopped) 'confirmExternalStopped': true,
      }),
    );
    if (generation != _generation || selected != projectId) return;
    final thread = asJson(result['thread']);
    threadId = thread['id'] as String;
    imageDrafts.bind(host?.id, projectId, threadId);
    timelines[threadId!] = _timelineFromTurns(thread['turns']);
    await loadThreads();
    notifyListeners();
    _scheduleSave();
  }

  Future<void> newThread({bool preserveImageDraft = false}) async {
    if (projectId == null) {
      throw const RpcException('NO_PROJECT', 'Add or select a project first.');
    }
    final generation = _generation;
    final selected = projectId;
    final selectedThread = threadId;
    final result = asJson(
      await rpc('thread/start', {
        'projectId': projectId,
        'permissionMode': permissionMode,
        if (model != null) 'model': model,
      }),
    );
    if (generation != _generation ||
        selected != projectId ||
        selectedThread != threadId) {
      throw const RpcException(
        'CONTEXT_CHANGED',
        'Host or project changed while creating the task. No message was sent.',
      );
    }
    final thread = asJson(result['thread']);
    threadId = thread['id'] as String;
    if (preserveImageDraft) {
      imageDrafts.adoptThread(threadId!);
    } else {
      imageDrafts.bind(host?.id, projectId, threadId);
    }
    timelines[threadId!] = [];
    threads.insert(0, thread);
    notifyListeners();
    _scheduleSave();
  }

  Future<void> send(String message, List<Json> attachments) async {
    final input = <Json>[
      if (message.trim().isNotEmpty)
        {'type': 'text', 'text': message, 'text_elements': <dynamic>[]},
      ...attachments,
    ];
    await sendInput(input);
  }

  Future<void> sendInput(List<Json> input) async {
    final normalized = <Json>[];
    for (final item in input) {
      if (item['type'] == 'text') {
        final text = item['text']?.toString() ?? '';
        if (text.isEmpty) continue;
        if (normalized.isNotEmpty && normalized.last['type'] == 'text') {
          normalized[normalized.length - 1] = {
            'type': 'text',
            'text': '${normalized.last['text']}$text',
            'text_elements': <dynamic>[],
          };
        } else {
          normalized.add({
            'type': 'text',
            'text': text,
            'text_elements': <dynamic>[],
          });
        }
      } else {
        normalized.add(item);
      }
    }
    if (normalized.isEmpty ||
        !normalized.any(
          (item) =>
              item['type'] != 'text' ||
              (item['text']?.toString().trim().isNotEmpty ?? false),
        )) {
      return;
    }
    final generation = _generation;
    final selected = projectId;
    if (threadId == null) await newThread(preserveImageDraft: true);
    if (generation != _generation || selected != projectId) {
      throw const RpcException('CONTEXT_CHANGED', '任务已切换，未发送消息');
    }
    final task = threadId;
    final active = running;
    if (active == null) {
      if (runtimeThreads.any(
        (entry) => entry['id'] == threadId && entry['state'] == 'unknown',
      )) {
        throw const RpcException(
          'OUTCOME_UNKNOWN',
          'Previous task outcome is unknown. Inspect history and explicitly reopen or fork the task first.',
        );
      }
      await rpc('thread/resume', {
        'threadId': threadId,
        'projectId': projectId,
        'permissionMode': permissionMode,
      });
      if (generation != _generation ||
          selected != projectId ||
          task != threadId) {
        throw const RpcException(
          'CONTEXT_CHANGED',
          'Active host, project, or task changed. No message was sent.',
        );
      }
    }
    final params = <String, dynamic>{
      'threadId': threadId,
      'projectId': projectId,
      'input': normalized,
      'clientUserMessageId': const Uuid().v4(),
    };
    if (active != null) {
      params['expectedTurnId'] = active['turn'];
      await rpc('turn/steer', params);
    } else {
      params['permissionMode'] = permissionMode;
      if (model != null) params['model'] = model;
      if (effort != null) params['effort'] = effort;
      if (model != null && modes.any((value) => value['mode'] == mode)) {
        params['collaborationMode'] = {
          'mode': mode,
          'settings': {
            'model': model,
            'reasoning_effort': effort,
            'developer_instructions': null,
          },
        };
      }
      await rpc('turn/start', params);
    }
  }

  Future<void> stop() async {
    final active = running;
    if (active != null) {
      await rpc('turn/interrupt', {
        'threadId': threadId,
        'turnId': active['turn'],
      });
    }
  }

  Future<void> respond(String id, Json result) async {
    await rpc('approval/respond', {'id': id, 'result': result});
    approvals.removeWhere((value) => value['id'] == id);
    notifyListeners();
    _scheduleSave();
  }

  Future<void> renameThread(String name) async {
    await rpc('thread/name/set', {'threadId': threadId, 'name': name});
    await loadThreads();
  }

  Future<void> archiveThread(String id, bool restore) async {
    await rpc(restore ? 'thread/unarchive' : 'thread/archive', {
      'threadId': id,
      'projectId': projectId,
    });
    if (threadId == id && !restore) threadId = null;
    await loadThreads();
  }

  Future<void> loadTools() async {
    final generation = _generation;
    final selected = projectId;
    final skillResult = asJson(
      await rpc('skills/list', {'projectId': projectId}),
    );
    if (generation != _generation || selected != projectId) return;
    skills = asList(skillResult['data'])
        .expand((entry) => asList(entry['skills']))
        .where((entry) => entry['enabled'] != false)
        .toList();
    final mcpResult = asJson(
      await rpc('mcpServerStatus/list', {
        'limit': 100,
        if (threadId != null) 'threadId': threadId,
      }),
    );
    if (generation != _generation || selected != projectId) return;
    mcp = asList(mcpResult['data']);
    notifyListeners();
  }

  Future<List<Json>> searchProjectFiles(
    String query, {
    int maxDirectories = 120,
    int maxResults = 50,
  }) async {
    final generation = _generation;
    final selected = projectId;
    if (selected == null) return [];
    final needle = query.trim().toLowerCase();
    final queue = <String>[''];
    final results = <Json>[];
    const ignoredDirectories = {
      '.git',
      '.dart_tool',
      'build',
      'node_modules',
      '.gradle',
    };
    var visited = 0;
    while (queue.isNotEmpty &&
        visited < maxDirectories &&
        results.length < maxResults) {
      final path = queue.removeAt(0);
      visited++;
      final response = asJson(
        await rpc('files/list', {'projectId': selected, 'path': path}),
      );
      if (generation != _generation || selected != projectId) return [];
      for (final entry in asList(response['entries'])) {
        final name = entry['name']?.toString() ?? '';
        if (name.isEmpty) continue;
        final relativePath = path.isEmpty ? name : '$path/$name';
        final directory = entry['isDirectory'] == true;
        if (directory) {
          if (!ignoredDirectories.contains(name) && entry['isLink'] != true) {
            queue.add(relativePath);
          }
          continue;
        }
        final haystack = relativePath.toLowerCase();
        if (needle.isEmpty || haystack.contains(needle)) {
          results.add({'name': name, 'path': relativePath});
          if (results.length >= maxResults) break;
        }
      }
    }
    return results;
  }

  Future<Json> upload(List<int> bytes) async {
    validateImageBytes(bytes, upload: true);
    final selected = host!;
    final selectedProject = projectId;
    final selectedThread = threadId;
    final generation = _generation;
    final token = await storage.token(selected.id);
    if (generation != _generation ||
        projectId != selectedProject ||
        threadId != selectedThread) {
      throw const RpcException('CONTEXT_CHANGED', '任务已切换，未上传图片');
    }
    if (token == null) throw const RpcException('UNAUTHORIZED', '请重新配对');
    Json result;
    try {
      result = await httpJson(
        Uri.parse(selected.url),
        '/v1/uploads',
        fingerprint: selected.fingerprint,
        token: token,
        body: {
          'requestId': const Uuid().v4(),
          'projectId': selectedProject,
          'dataBase64': base64Encode(bytes),
        },
      );
    } on RpcException {
      rethrow;
    } catch (_) {
      throw const RpcException('OUTCOME_UNKNOWN', '上传结果未知，请检查主机后再操作');
    }
    if (generation != _generation ||
        host?.id != selected.id ||
        projectId != selectedProject ||
        threadId != selectedThread) {
      throw const RpcException(
        'CONTEXT_CHANGED',
        'Host or project changed during upload.',
      );
    }
    return {'type': 'localImage', 'path': result['path']};
  }

  Future<Uint8List> loadMessageImage(
    String task,
    String itemId,
    int contentIndex,
    Json content,
  ) async {
    final selected = host;
    final selectedProject = projectId;
    final generation = _generation;
    if (selected == null || selectedProject == null) {
      throw const RpcException('OFFLINE', '未连接主机');
    }
    final bytes = await imageLoader.load(
      host: selected,
      projectId: selectedProject,
      threadId: task,
      itemId: itemId,
      contentIndex: contentIndex,
      content: content,
      supportsRead: supports('imageRead'),
      token: () => storage.token(selected.id),
    );
    if (_disposed ||
        generation != _generation ||
        host?.id != selected.id ||
        projectId != selectedProject ||
        threadId != task) {
      throw const RpcException('CONTEXT_CHANGED', '当前任务已切换');
    }
    return bytes;
  }

  void showError(Object failure) {
    error = failure.toString();
    if (!_disposed) notifyListeners();
  }

  void clearError() {
    error = null;
    notifyListeners();
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(
      const Duration(milliseconds: 200),
      () => unawaited(flush()),
    );
  }

  Future<void> flush() async {
    _saveTimer?.cancel();
    final selected = host;
    if (selected == null) return;
    try {
      await storage.write('cache-${selected.id}', {
        'projects': projects,
        'threads': threads,
        'timelines': timelines,
        'projectId': projectId,
        'threadId': threadId,
        'epoch': epoch,
        'cursor': cursor,
        'approvals': approvals,
        'runtimeThreads': runtimeThreads,
      });
    } catch (failure) {
      if (!_disposed) {
        error = 'Local cache could not be saved: $failure';
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    imageLoader.cache.clear();
    imageDrafts.dispose();
    _saveTimer?.cancel();
    unawaited(_messages?.cancel());
    unawaited(_statuses?.cancel());
    unawaited(transport?.close());
    unawaited(events.close());
    super.dispose();
  }
}
