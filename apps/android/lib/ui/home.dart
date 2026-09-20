import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../data/workbench.dart';
import 'chat.dart';
import 'common.dart';
import 'hosts.dart';
import 'workspace.dart';

enum _HomePage { tasks, workspace, hosts }

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});
  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with WidgetsBindingObserver {
  _HomePage page = _HomePage.tasks;
  bool requiresHostSelection = false;

  void openPage(_HomePage destination) {
    if (mounted) setState(() => page = destination);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final workbench = ref.read(workbenchProvider);
    if (state == AppLifecycleState.resumed) {
      workbench.transport?.reconnect();
    } else if (state == AppLifecycleState.paused) {
      unawaited(workbench.flush());
    }
  }

  @override
  Widget build(BuildContext context) {
    final workbench = ref.watch(workbenchProvider);
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final currentPage = workbench.host == null ? _HomePage.hosts : page;
    final canGoBack =
        workbench.host != null &&
        !requiresHostSelection &&
        currentPage != _HomePage.tasks;
    final body = currentPage == _HomePage.hosts
        ? HostsPane(
            workbench: workbench,
            onSelecting: () {
              requiresHostSelection =
                  requiresHostSelection || workbench.host == null;
              openPage(_HomePage.hosts);
            },
            onSelected: () {
              requiresHostSelection = false;
              openPage(_HomePage.tasks);
            },
          )
        : currentPage == _HomePage.workspace
        ? WorkspacePane(
            key: ValueKey('${workbench.host?.id}:${workbench.projectId}'),
            workbench: workbench,
          )
        : ChatPane(
            key: ValueKey('${workbench.host?.id}:${workbench.projectId}'),
            workbench: workbench,
          );
    return PopScope<void>(
      canPop: !canGoBack,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && canGoBack) openPage(_HomePage.tasks);
      },
      child: Scaffold(
        appBar: AppBar(
          leading: canGoBack
              ? IconButton(
                  tooltip: '返回',
                  onPressed: () => openPage(_HomePage.tasks),
                  icon: const Icon(Icons.arrow_back),
                )
              : currentPage == _HomePage.tasks && !wide
              ? Builder(
                  builder: (context) => IconButton(
                    tooltip: '任务列表',
                    onPressed: () => Scaffold.of(context).openDrawer(),
                    icon: const Icon(Icons.view_sidebar_outlined),
                  ),
                )
              : const Padding(
                  padding: EdgeInsets.all(14),
                  child: Icon(Icons.terminal, size: 26),
                ),
          title: Semantics(
            button: workbench.host != null,
            label: workbench.host != null ? '管理主机' : null,
            child: InkWell(
              onTap: workbench.host != null
                  ? () => openPage(_HomePage.hosts)
                  : null,
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                height: 48,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      switch (currentPage) {
                        _HomePage.tasks => 'Codex Bridge',
                        _HomePage.workspace => '工作区',
                        _HomePage.hosts => '主机管理',
                      },
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (workbench.host != null)
                      Row(
                        children: [
                          StateDot(online: workbench.online),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              workbench.host!.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                            ),
                          ),
                          const Icon(Icons.expand_more, size: 16),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            if (workbench.approvals.isNotEmpty)
              IconButton(
                tooltip: '待处理请求',
                onPressed: () => showApprovals(context, workbench),
                icon: Badge(
                  label: Text('${workbench.approvals.length}'),
                  child: const Icon(Icons.pending_actions),
                ),
              ),
            if (currentPage == _HomePage.tasks)
              IconButton(
                tooltip: '新建任务',
                onPressed: workbench.online && workbench.projectId != null
                    ? () => guard(workbench, workbench.newThread)
                    : null,
                icon: const Icon(Icons.edit_square),
              ),
            if (currentPage == _HomePage.tasks)
              PopupMenuButton<String>(
                onSelected: (value) async {
                  if (value == 'refresh') {
                    workbench.transport?.reconnect();
                    if (workbench.online) {
                      await guard(workbench, workbench.refresh);
                    }
                  }
                  if (value == 'rename' &&
                      workbench.threadId != null &&
                      context.mounted) {
                    final name = await askText(
                      context,
                      '重命名任务',
                      initial:
                          workbench.currentThread?['name']?.toString() ?? '',
                    );
                    if (name != null && name.isNotEmpty) {
                      await guard(
                        workbench,
                        () => workbench.renameThread(name),
                      );
                    }
                  }
                  if (value == 'archive' && workbench.threadId != null) {
                    await guard(
                      workbench,
                      () => workbench.archiveThread(workbench.threadId!, false),
                    );
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'refresh', child: Text('刷新连接')),
                  if (currentPage == _HomePage.tasks &&
                      workbench.threadId != null) ...[
                    const PopupMenuItem(value: 'rename', child: Text('重命名任务')),
                    const PopupMenuItem(value: 'archive', child: Text('归档任务')),
                  ],
                ],
              ),
          ],
        ),
        drawer: wide || currentPage != _HomePage.tasks
            ? null
            : Drawer(
                child: SafeArea(
                  child: TaskList(
                    workbench: workbench,
                    onOpened: () => Navigator.pop(context),
                  ),
                ),
              ),
        body: Column(
          children: [
            if (currentPage != _HomePage.hosts)
              ProjectBar(
                workbench: workbench,
                onOpenWorkspace: currentPage == _HomePage.tasks
                    ? () => openPage(_HomePage.workspace)
                    : null,
              ),
            if (workbench.host != null && !workbench.online)
              Container(
                width: double.infinity,
                color: Theme.of(context).colorScheme.surfaceContainer,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Text(
                  workbench.status == 'connecting'
                      ? '正在连接主机…'
                      : '离线 · 主机上的任务可能仍在执行，重连后同步。',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            if (workbench.error != null)
              MaterialBanner(
                content: Text(
                  workbench.error!,
                  maxLines: 5,
                  overflow: TextOverflow.ellipsis,
                ),
                leading: const Icon(Icons.error_outline),
                actions: [
                  TextButton(
                    onPressed: workbench.clearError,
                    child: const Text('关闭'),
                  ),
                ],
              ),
            Expanded(
              child: !workbench.initialized
                  ? const Center(child: CircularProgressIndicator())
                  : Row(
                      children: [
                        if (wide && currentPage == _HomePage.tasks) ...[
                          SizedBox(
                            width: 280,
                            child: TaskList(workbench: workbench),
                          ),
                          const VerticalDivider(width: 1),
                        ],
                        Expanded(child: body),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class ProjectBar extends StatelessWidget {
  final Workbench workbench;
  final VoidCallback? onOpenWorkspace;
  const ProjectBar({super.key, required this.workbench, this.onOpenWorkspace});
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      border: Border(
        bottom: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
      ),
    ),
    padding: const EdgeInsets.symmetric(horizontal: 12),
    child: Row(
      children: [
        const Icon(Icons.folder_open, size: 17),
        const SizedBox(width: 8),
        Expanded(
          child: PopupMenuButton<String>(
            enabled: workbench.online,
            tooltip: '切换项目',
            onSelected: (id) =>
                guard(workbench, () => workbench.selectProject(id)),
            itemBuilder: (_) => workbench.projects
                .map(
                  (entry) => PopupMenuItem(
                    value: entry['id'] as String,
                    child: Text(entry['name'] as String),
                  ),
                )
                .toList(),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 13),
              child: Text(
                workbench.project?['path']?.toString() ?? '选择或添加项目',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              ),
            ),
          ),
        ),
        if (onOpenWorkspace != null)
          IconButton(
            tooltip: '打开工作区',
            onPressed: onOpenWorkspace,
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            icon: const Icon(Icons.code, size: 20),
          ),
        IconButton(
          tooltip: '添加主机项目目录',
          onPressed: workbench.online
              ? () async {
                  final path = await askText(
                    context,
                    '添加项目',
                    initial: workbench.info['homeDirectory']?.toString() ?? '',
                    label: '主机上的绝对目录路径',
                  );
                  if (path != null && path.isNotEmpty) {
                    await guard(
                      workbench,
                      () => workbench.addProject(path, ''),
                    );
                  }
                }
              : null,
          icon: const Icon(Icons.create_new_folder_outlined, size: 19),
        ),
      ],
    ),
  );
}

class TaskList extends StatefulWidget {
  final Workbench workbench;
  final VoidCallback? onOpened;
  const TaskList({super.key, required this.workbench, this.onOpened});
  @override
  State<TaskList> createState() => _TaskListState();
}

class _TaskListState extends State<TaskList> {
  Timer? debounce;
  bool menuOpen = false;
  @override
  void dispose() {
    debounce?.cancel();
    super.dispose();
  }

  Future<void> open(Json task) async {
    final workbench = widget.workbench;
    final scope = workbench.threadActionContext;
    try {
      if (workbench.archived) {
        await workbench.archiveThread(
          task['id'] as String,
          true,
          context: scope,
        );
      }
      if (!mounted || scope != workbench.threadActionContext) return;
      await workbench.openThread(task['id'] as String);
      if (mounted && scope == workbench.threadActionContext) {
        widget.onOpened?.call();
      }
    } on RpcException catch (error) {
      if ([
        'CONFIRM_EXTERNAL_STOPPED',
        'THREAD_ACTIVE_ELSEWHERE',
        'EXTERNAL_THREAD',
      ].contains(error.code)) {
        if (!mounted) return;
        final action = await showDialog<String>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('来自其他执行端的会话'),
            content: const Text(
              '读取历史不能判断电脑端是否仍在执行。建议分叉为独立任务；只有确认其他客户端已停止时才能继续原会话。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              if (error.code != 'THREAD_ACTIVE_ELSEWHERE')
                TextButton(
                  onPressed: () => Navigator.pop(context, 'resume'),
                  child: const Text('已停止，继续原会话'),
                ),
              FilledButton(
                onPressed: () => Navigator.pop(context, 'fork'),
                child: const Text('分叉后继续'),
              ),
            ],
          ),
        );
        if (action != null) {
          await guard(workbench, () async {
            await workbench.openThread(
              task['id'] as String,
              confirmStopped: action == 'resume',
              fork: action == 'fork',
            );
            widget.onOpened?.call();
          });
        }
      } else {
        workbench.showError(error);
      }
    } catch (error) {
      workbench.showError(error);
    }
  }

  Future<void> showActions(Json task) async {
    if (menuOpen) return;
    menuOpen = true;
    final workbench = widget.workbench;
    final scope = workbench.threadActionContext;
    final id = task['id'] as String;
    final restore = workbench.archived;
    final title =
        task['name']?.toString() ?? task['preview']?.toString() ?? '新任务';
    String? blocked({bool delete = false}) =>
        scope != workbench.threadActionContext
        ? '主机或项目已切换，请重新操作'
        : workbench.threadActionBlocked(id, delete: delete);
    try {
      final action = await showModalBottomSheet<String>(
        context: context,
        useSafeArea: true,
        isScrollControlled: true,
        builder: (context) => AnimatedBuilder(
          animation: workbench,
          builder: (context, _) {
            final reason = blocked();
            final deleteReason = blocked(delete: true);
            final colors = Theme.of(context).colorScheme;
            return SafeArea(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
                      child: Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    ListTile(
                      leading: Icon(
                        restore
                            ? Icons.unarchive_outlined
                            : Icons.archive_outlined,
                      ),
                      title: Text(restore ? '恢复会话' : '归档会话'),
                      subtitle: reason == null ? null : Text(reason),
                      enabled: reason == null,
                      onTap: reason == null
                          ? () => Navigator.pop(context, 'archive')
                          : null,
                    ),
                    ListTile(
                      leading: const Icon(Icons.delete_outline),
                      title: const Text('删除会话'),
                      textColor: colors.error,
                      iconColor: colors.error,
                      subtitle: deleteReason == null
                          ? null
                          : Text(deleteReason),
                      enabled: deleteReason == null,
                      onTap: deleteReason == null
                          ? () => Navigator.pop(context, 'delete')
                          : null,
                    ),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('取消'),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      );
      if (!mounted ||
          action == null ||
          scope != workbench.threadActionContext) {
        return;
      }
      if (action == 'delete') {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AnimatedBuilder(
            animation: workbench,
            builder: (context, _) {
              final reason = blocked(delete: true);
              return AlertDialog(
                title: const Text('删除会话'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 12),
                    const Text('永久删除此会话及其历史记录？此操作无法撤销，不会删除项目文件。'),
                    if (reason != null) ...[
                      const SizedBox(height: 12),
                      Text(reason),
                    ],
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('取消'),
                  ),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.error,
                    ),
                    onPressed: reason == null
                        ? () => Navigator.pop(context, true)
                        : null,
                    child: const Text('永久删除'),
                  ),
                ],
              );
            },
          ),
        );
        if (!mounted ||
            confirmed != true ||
            scope != workbench.threadActionContext) {
          return;
        }
        await guard(
          workbench,
          () => workbench.deleteThread(id, context: scope),
        );
      } else {
        await guard(
          workbench,
          () => workbench.archiveThread(id, restore, context: scope),
        );
      }
    } finally {
      menuOpen = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final workbench = widget.workbench;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  '任务',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 18),
                ),
              ),
              IconButton(
                tooltip: workbench.archived ? '查看活动任务' : '查看已归档',
                onPressed: workbench.online
                    ? () => guard(workbench, () async {
                        workbench.archived = !workbench.archived;
                        await workbench.loadThreads();
                      })
                    : null,
                icon: Icon(
                  workbench.archived
                      ? Icons.inventory_2
                      : Icons.inventory_2_outlined,
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            decoration: const InputDecoration(
              hintText: '搜索任务',
              prefixIcon: Icon(Icons.search, size: 18),
            ),
            onChanged: (value) {
              debounce?.cancel();
              debounce = Timer(const Duration(milliseconds: 350), () {
                workbench.query = value;
                unawaited(guard(workbench, workbench.loadThreads));
              });
            },
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: workbench.threads.isEmpty
              ? const Center(
                  child: Text('还没有任务', style: TextStyle(color: Colors.grey)),
                )
              : ListView.builder(
                  itemCount:
                      workbench.threads.length +
                      (workbench.nextCursor != null ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (index == workbench.threads.length) {
                      return TextButton(
                        onPressed: () => guard(
                          workbench,
                          () => workbench.loadThreads(more: true),
                        ),
                        child: const Text('加载更多'),
                      );
                    }
                    final task = workbench.threads[index];
                    final isRunning = workbench.runtimeThreads.any(
                      (entry) =>
                          entry['id'] == task['id'] &&
                          entry['state'] == 'running',
                    );
                    return ListTile(
                      selected: task['id'] == workbench.threadId,
                      selectedTileColor: Theme.of(context)
                          .colorScheme
                          .surfaceContainer,
                      leading: Icon(
                        isRunning
                            ? Icons.pending_outlined
                            : Icons.chat_bubble_outline,
                        size: 18,
                      ),
                      title: Text(
                        task['name']?.toString() ??
                            task['preview']?.toString() ??
                            '新任务',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13),
                      ),
                      subtitle: isRunning
                          ? const Text('正在执行', style: TextStyle(fontSize: 11))
                          : null,
                      onTap: workbench.online ? () => open(task) : null,
                      onLongPress: () => showActions(task),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
