import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_code_editor/flutter_code_editor.dart';
import 'package:highlight/languages/dart.dart';
import 'package:highlight/languages/javascript.dart';
import 'package:highlight/languages/json.dart';
import 'package:highlight/languages/python.dart';
import 'package:highlight/languages/yaml.dart';

import '../data/models.dart';
import '../data/workbench.dart';
import 'common.dart';
import 'terminal.dart';

class WorkspacePane extends StatelessWidget {
  final Workbench workbench;
  const WorkspacePane({super.key, required this.workbench});
  @override
  Widget build(BuildContext context) {
    if (workbench.projectId == null) {
      return const EmptyState(
        icon: Icons.folder_open,
        title: '选择远程项目',
        subtitle: '通过上方的文件夹按钮添加主机目录。',
      );
    }
    return DefaultTabController(
      length: 3,
      child: Column(
        children: [
          const TabBar(
            tabs: [
              Tab(text: '文件'),
              Tab(text: '改动'),
              Tab(text: '终端'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                FileBrowser(workbench: workbench),
                DiffPane(workbench: workbench),
                TerminalPane(workbench: workbench),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class FileBrowser extends StatefulWidget {
  final Workbench workbench;
  final bool pickFile;
  const FileBrowser({
    super.key,
    required this.workbench,
    this.pickFile = false,
  });
  @override
  State<FileBrowser> createState() => _FileBrowserState();
}

class _FileBrowserState extends State<FileBrowser> {
  String path = '';
  List<Json> entries = [];
  bool loading = true;
  String? error;
  int generation = 0;
  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  Future<void> load() async {
    final current = ++generation;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final result = asJson(
        await widget.workbench.rpc('files/list', {
          'projectId': widget.workbench.projectId,
          'path': path,
        }),
      );
      if (mounted && current == generation) {
        setState(() => entries = asList(result['entries']));
      }
    } catch (failure) {
      if (mounted && current == generation) {
        setState(() => error = failure.toString());
      }
    } finally {
      if (mounted && current == generation) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      ListTile(
        dense: true,
        leading: IconButton(
          tooltip: '上级目录',
          onPressed: path.isEmpty
              ? null
              : () {
                  path = path.contains('/')
                      ? path.substring(0, path.lastIndexOf('/'))
                      : '';
                  unawaited(load());
                },
          icon: const Icon(Icons.arrow_upward, size: 18),
        ),
        title: Text(
          path.isEmpty ? '/' : '/$path',
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
        trailing: IconButton(
          tooltip: '刷新文件',
          onPressed: load,
          icon: const Icon(Icons.refresh, size: 19),
        ),
      ),
      Expanded(
        child: loading
            ? const Center(child: CircularProgressIndicator())
            : error != null
            ? EmptyState(
                icon: Icons.error_outline,
                title: '无法读取目录',
                subtitle: error!,
                action: TextButton(onPressed: load, child: const Text('重试')),
              )
            : entries.isEmpty
            ? const Center(child: Text('空目录'))
            : ListView.builder(
                itemCount: entries.length,
                itemBuilder: (_, index) {
                  final entry = entries[index];
                  final directory = entry['isDirectory'] == true;
                  return ListTile(
                    dense: true,
                    leading: Icon(
                      directory
                          ? Icons.folder_outlined
                          : entry['isLink'] == true
                          ? Icons.link
                          : Icons.description_outlined,
                      size: 19,
                    ),
                    title: Text(
                      entry['name'] as String,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                    trailing: directory
                        ? const Icon(Icons.chevron_right, size: 16)
                        : null,
                    onTap: () async {
                      final next = path.isEmpty
                          ? entry['name'] as String
                          : '$path/${entry['name']}';
                      if (directory) {
                        path = next;
                        await load();
                      } else if (widget.pickFile) {
                        Navigator.pop(context, next);
                      } else {
                        await Navigator.push<void>(
                          context,
                          MaterialPageRoute(
                            builder: (_) => EditorScreen(
                              workbench: widget.workbench,
                              path: next,
                            ),
                          ),
                        );
                        if (mounted) await load();
                      }
                    },
                  );
                },
              ),
      ),
    ],
  );
}

class EditorScreen extends StatefulWidget {
  final Workbench workbench;
  final String path;
  const EditorScreen({super.key, required this.workbench, required this.path});
  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  CodeController? editor;
  String version = '';
  String original = '';
  bool bom = false;
  bool saving = false;
  String? error;
  late final String? hostId;
  late final String? projectId;
  @override
  void initState() {
    super.initState();
    hostId = widget.workbench.host?.id;
    projectId = widget.workbench.projectId;
    unawaited(load());
  }

  bool get validContext =>
      widget.workbench.host?.id == hostId &&
      widget.workbench.projectId == projectId;
  bool get dirty => editor != null && editor!.fullText != original;
  @override
  void dispose() {
    editor?.dispose();
    super.dispose();
  }

  Future<void> load() async {
    if (!validContext) return;
    try {
      final result = asJson(
        await widget.workbench.rpc('files/read', {
          'projectId': projectId,
          'path': widget.path,
        }),
      );
      if (!mounted || !validContext) return;
      final extension = widget.path.split('.').last;
      final language = switch (extension) {
        'dart' => dart,
        'js' || 'ts' || 'jsx' || 'tsx' => javascript,
        'json' => json,
        'py' => python,
        'yaml' || 'yml' => yaml,
        _ => null,
      };
      editor?.dispose();
      original = result['content'] as String;
      version = result['version'] as String;
      bom = result['bom'] == true;
      editor = CodeController(text: original, language: language);
      editor!.addListener(() {
        if (mounted) setState(() {});
      });
      setState(() => error = null);
    } catch (failure) {
      if (mounted) setState(() => error = failure.toString());
    }
  }

  Future<void> save() async {
    if (!validContext) return;
    setState(() => saving = true);
    final submitted = editor!.fullText;
    try {
      final result = asJson(
        await widget.workbench.rpc('files/save', {
          'projectId': projectId,
          'path': widget.path,
          'version': version,
          'content': submitted,
          'bom': bom,
        }),
      );
      if (mounted) {
        setState(() {
          version = result['version'] as String;
          original = submitted;
        });
      }
    } on RpcException catch (failure) {
      if (!mounted) return;
      if (failure.code == 'FILE_CONFLICT') {
        final reload = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('文件已在主机上变化'),
            content: const Text('未覆盖主机文件。可以保留当前编辑并复制内容，或放弃本地编辑后重新载入。'),
            actions: [
              TextButton(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: editor!.fullText));
                  Navigator.pop(context, false);
                },
                child: const Text('复制并保留'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('继续编辑'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('放弃编辑并重载'),
              ),
            ],
          ),
        );
        if (reload == true) await load();
      } else {
        setState(() => error = failure.toString());
      }
    } catch (failure) {
      if (mounted) setState(() => error = failure.toString());
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !dirty,
    onPopInvokedWithResult: (didPop, _) async {
      if (didPop) return;
      final leave = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('放弃未保存的修改？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('继续编辑'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('放弃'),
            ),
          ],
        ),
      );
      if (leave == true && context.mounted) {
        setState(() => original = editor?.fullText ?? '');
        Navigator.pop(context);
      }
    },
    child: Scaffold(
      appBar: AppBar(
        title: Text(
          '${dirty ? '• ' : ''}${widget.path}',
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
        ),
        actions: [
          IconButton(
            tooltip: '复制文件内容',
            onPressed: editor == null
                ? null
                : () =>
                      Clipboard.setData(ClipboardData(text: editor!.fullText)),
            icon: const Icon(Icons.copy, size: 18),
          ),
          TextButton(
            onPressed:
                dirty && !saving && validContext && widget.workbench.online
                ? save
                : null,
            child: Text(saving ? '保存中' : '保存'),
          ),
        ],
      ),
      body: Column(
        children: [
          if (error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (!validContext) const Text('主机或项目已切换，禁止保存。'),
          Expanded(
            child: editor == null
                ? error == null
                      ? const Center(child: CircularProgressIndicator())
                      : Center(
                          child: TextButton(
                            onPressed: load,
                            child: const Text('重试'),
                          ),
                        )
                : SingleChildScrollView(
                    child: CodeField(
                      controller: editor!,
                      textStyle: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 13,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                  ),
          ),
        ],
      ),
    ),
  );
}

class DiffPane extends StatefulWidget {
  final Workbench workbench;
  const DiffPane({super.key, required this.workbench});
  @override
  State<DiffPane> createState() => _DiffPaneState();
}

class _DiffPaneState extends State<DiffPane> {
  Json? data;
  String? error;
  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  Future<void> load() async {
    try {
      final result = asJson(
        await widget.workbench.rpc('git/status', {
          'projectId': widget.workbench.projectId,
        }),
      );
      if (mounted) {
        setState(() {
          data = result;
          error = null;
        });
      }
    } catch (failure) {
      if (mounted) setState(() => error = failure.toString());
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      ListTile(
        dense: true,
        title: const Text('Git 工作区', style: TextStyle(fontSize: 13)),
        trailing: IconButton(
          tooltip: '刷新改动',
          onPressed: load,
          icon: const Icon(Icons.refresh),
        ),
      ),
      Expanded(
        child: error != null
            ? EmptyState(
                icon: Icons.error_outline,
                title: '无法获取改动',
                subtitle: error!,
                action: TextButton(onPressed: load, child: const Text('重试')),
              )
            : data == null
            ? const Center(child: CircularProgressIndicator())
            : data!['isGit'] != true
            ? const EmptyState(
                icon: Icons.account_tree_outlined,
                title: '这是普通目录',
                subtitle: '文件编辑和 Codex 任务仍然可用。Git 改动仅适用于仓库。',
              )
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  SelectableText(
                    (data!['status'] as String).isEmpty
                        ? '工作区干净'
                        : data!['status'] as String,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                  for (final section in ['unstaged', 'staged']) ...[
                    const SizedBox(height: 20),
                    Text(
                      section == 'staged' ? '已暂存' : '未暂存',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    DiffText(text: data![section]?.toString() ?? ''),
                  ],
                ],
              ),
      ),
    ],
  );
}

class DiffText extends StatelessWidget {
  final String text;
  const DiffText({super.key, required this.text});
  @override
  Widget build(BuildContext context) => SelectableText.rich(
    TextSpan(
      children: (text.isEmpty ? '无改动' : text)
          .split('\n')
          .map(
            (line) => TextSpan(
              text: '$line\n',
              style: TextStyle(
                color: line.startsWith('+')
                    ? const Color(0xff399b68)
                    : line.startsWith('-')
                    ? const Color(0xffc96059)
                    : null,
              ),
            ),
          )
          .toList(),
    ),
    style: const TextStyle(fontFamily: 'monospace', fontSize: 11, height: 1.55),
  );
}
