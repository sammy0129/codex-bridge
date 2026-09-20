import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../data/models.dart';
import '../data/workbench.dart';
import 'common.dart';

class TerminalPane extends StatefulWidget {
  final Workbench workbench;
  const TerminalPane({super.key, required this.workbench});
  @override
  State<TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends State<TerminalPane> {
  Terminal terminal = Terminal(maxLines: 5000);
  List<Json> sessions = [];
  String? id;
  String state = 'none';
  String? error;
  int baseline = 0;
  bool restoring = false;
  List<Json> buffered = [];
  StreamSubscription<Json>? subscription;
  late final String? hostId;
  late final String? projectId;
  bool get validContext =>
      widget.workbench.host?.id == hostId &&
      widget.workbench.projectId == projectId;
  @override
  void initState() {
    super.initState();
    hostId = widget.workbench.host?.id;
    projectId = widget.workbench.projectId;
    bindTerminal();
    subscription = widget.workbench.events.stream.listen(onEvent);
    unawaited(load());
  }

  void bindTerminal() {
    terminal.onOutput = (output) => unawaited(send(output));
    terminal.onResize = (width, height, _, _) {
      if (id != null &&
          state == 'running' &&
          validContext &&
          widget.workbench.online) {
        unawaited(
          guard(widget.workbench, () async {
            await widget.workbench.rpc('terminal/resize', {
              'projectId': projectId,
              'id': id,
              'cols': width.clamp(1, 1000),
              'rows': height.clamp(1, 1000),
            });
          }),
        );
      }
    };
  }

  Future<void> load() async {
    if (!validContext) return;
    try {
      final result = asJson(
        await widget.workbench.rpc('terminal/list', {'projectId': projectId}),
      );
      if (!mounted || !validContext) return;
      setState(() {
        sessions = asList(result['terminals']);
        error = null;
      });
      if (id != null || sessions.isNotEmpty) {
        await attach(id ?? sessions.first['id'] as String);
      }
    } catch (failure) {
      if (mounted) setState(() => error = failure.toString());
    }
  }

  Future<void> attach(String selected) async {
    id = selected;
    restoring = true;
    buffered = [];
    try {
      final result = asJson(
        await widget.workbench.rpc('terminal/read', {
          'projectId': projectId,
          'id': selected,
        }),
      );
      if (!mounted || !validContext || id != selected) return;
      baseline = result['cursor'] as int? ?? widget.workbench.cursor;
      terminal = Terminal(maxLines: 5000);
      bindTerminal();
      terminal.write(result['output']?.toString() ?? '');
      state = result['state'] as String;
      restoring = false;
      for (final event in buffered) {
        onEvent(event);
      }
      buffered = [];
      setState(() {});
    } finally {
      restoring = false;
    }
  }

  void onEvent(Json event) {
    if (!mounted || !validContext) return;
    if (event['method'] == 'bridge/synced') {
      unawaited(load());
      return;
    }
    if (event['method'] == 'bridge/upstreamLost') {
      setState(() => state = 'lost');
      return;
    }
    final params = asJson(event['params']);
    if (params['processId'] != id) return;
    if (restoring) {
      buffered.add(event);
      return;
    }
    if ((event['seq'] as int? ?? 0) <= baseline) return;
    if (event['method'] == 'command/exec/outputDelta') {
      terminal.write(
        params['textDelta']?.toString() ??
            utf8.decode(
              base64Decode(params['deltaBase64'] as String),
              allowMalformed: true,
            ),
      );
    }
    if (event['method'] == 'bridge/terminalExited') {
      setState(() {
        state = params['error'] == null ? 'exited' : 'failed';
        error = params['error']?.toString();
      });
    }
  }

  Future<void> send(String value) async {
    if (id == null || state != 'running' || !validContext) return;
    await guard(widget.workbench, () async {
      await widget.workbench.rpc('terminal/write', {
        'projectId': projectId,
        'id': id,
        'deltaBase64': base64Encode(utf8.encode(value)),
      });
    });
  }

  Future<void> open() async {
    await guard(widget.workbench, () async {
      final result = asJson(
        await widget.workbench.rpc('terminal/open', {
          'projectId': projectId,
          'permissionMode': widget.workbench.permissionMode,
        }),
      );
      if (!mounted || !validContext) return;
      sessions.insert(0, result);
      await attach(result['id'] as String);
    });
  }

  @override
  void dispose() {
    unawaited(subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Row(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: 12),
              child: DropdownButton<String>(
                isExpanded: true,
                value: sessions.any((entry) => entry['id'] == id) ? id : null,
                hint: const Text('选择终端', style: TextStyle(fontSize: 12)),
                items: sessions
                    .map(
                      (entry) => DropdownMenuItem(
                        value: entry['id'] as String,
                        child: Text(
                          '${entry['id'].toString().substring(0, 8)} · ${entry['state']}',
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11,
                          ),
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value != null) {
                    unawaited(guard(widget.workbench, () => attach(value)));
                  }
                },
              ),
            ),
          ),
          IconButton(
            tooltip: '重新附着终端',
            onPressed: widget.workbench.online ? load : null,
            icon: const Icon(Icons.refresh, size: 19),
          ),
          IconButton(
            tooltip: '新建终端',
            onPressed: widget.workbench.online ? open : null,
            icon: const Icon(Icons.add, size: 19),
          ),
          IconButton(
            tooltip: '结束终端进程',
            onPressed:
                id != null && state == 'running' && widget.workbench.online
                ? () => guard(widget.workbench, () async {
                    await widget.workbench.rpc('terminal/close', {
                      'projectId': projectId,
                      'id': id,
                    });
                  })
                : null,
            icon: const Icon(Icons.close, size: 19),
          ),
        ],
      ),
      if (error != null)
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text(
            error!,
            style: TextStyle(
              color: Theme.of(context).colorScheme.error,
              fontSize: 11,
            ),
          ),
        ),
      if (id != null && state != 'running')
        Text('终端已结束（$state），不会重放命令。', style: const TextStyle(fontSize: 11)),
      Expanded(
        child: id == null
            ? EmptyState(
                icon: Icons.terminal,
                title: '远程交互终端',
                subtitle: '直接操作当前主机的项目目录。退出页面不会结束进程。',
                action: FilledButton(
                  onPressed: widget.workbench.online ? open : null,
                  child: const Text('打开终端'),
                ),
              )
            : ColoredBox(
                color: const Color(0xff101412),
                child: TerminalView(
                  terminal,
                  readOnly: !widget.workbench.online || state != 'running',
                  padding: const EdgeInsets.all(10),
                  textStyle: const TerminalStyle(fontSize: 12),
                ),
              ),
      ),
      if (id != null)
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final entry in <String, String>{
                'Ctrl+C': '\x03',
                'Tab': '\t',
                'Esc': '\x1b',
                '↑': '\x1b[A',
                '↓': '\x1b[B',
                '←': '\x1b[D',
                '→': '\x1b[C',
                'Enter': '\r',
              }.entries)
                TextButton(
                  onPressed: widget.workbench.online && state == 'running'
                      ? () => send(entry.value)
                      : null,
                  child: Text(entry.key, style: const TextStyle(fontSize: 11)),
                ),
            ],
          ),
        ),
    ],
  );
}
