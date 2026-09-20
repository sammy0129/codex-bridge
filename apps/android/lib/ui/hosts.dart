import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../data/models.dart';
import '../data/workbench.dart';
import 'common.dart';

Future<bool> _waitForHostConnection(Workbench workbench, String? hostId) async {
  final result = Completer<bool>();
  void check() {
    if (result.isCompleted) return;
    if (workbench.host?.id != hostId || hostId == null) {
      result.complete(false);
    } else if (workbench.online) {
      result.complete(true);
    } else if (workbench.status != 'connecting') {
      result.completeError(
        RpcException('HOST_CONNECTION_FAILED', workbench.status),
      );
    }
  }

  workbench.addListener(check);
  check();
  try {
    return await result.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () => throw const RpcException(
        'HOST_CONNECTION_TIMEOUT',
        '连接主机超时，请检查主机状态后重试。',
      ),
    );
  } finally {
    workbench.removeListener(check);
  }
}

class HostsPane extends StatelessWidget {
  final Workbench workbench;
  final VoidCallback? onSelecting;
  final VoidCallback? onSelected;
  const HostsPane({
    super.key,
    required this.workbench,
    this.onSelecting,
    this.onSelected,
  });

  Future<void> select(BuildContext context, Host host) async {
    onSelecting?.call();
    await guard(workbench, () async {
      await workbench.selectHost(host);
      final connected = await _waitForHostConnection(workbench, host.id);
      if (connected && context.mounted) onSelected?.call();
    });
  }

  Future<void> pair(BuildContext context) async {
    onSelecting?.call();
    final paired = await showPairing(context, workbench);
    if (paired == true && context.mounted) onSelected?.call();
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      Row(
        children: [
          Expanded(
            child: Text(
              '你的开发主机',
              style: Theme.of(context).textTheme.headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          IconButton(
            tooltip: '配对新主机',
            onPressed: () => pair(context),
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Text(
        '连接自己的电脑或服务器。任务留在主机，工作台随身带走。',
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          height: 1.6,
        ),
      ),
      const SizedBox(height: 24),
      for (final host in workbench.hosts)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
              borderRadius: BorderRadius.circular(16),
            ),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 8,
              ),
              leading: Icon(
                host.info['platform'] == 'win32'
                    ? Icons.desktop_windows_outlined
                    : Icons.dns_outlined,
              ),
              title: Text(
                host.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(host.url, maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 6),
                  if (workbench.host?.id == host.id)
                    Row(
                      children: [
                        StateDot(online: workbench.online),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            '${workbench.online ? '已连接' : '离线'} · ${workbench.runtimeThreads.where((entry) => entry['state'] == 'running').length} 个运行任务 · ${workbench.approvals.length} 项待处理',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  if (workbench.host?.id != host.id)
                    const Text('未连接 · 点击切换', style: TextStyle(fontSize: 12)),
                ],
              ),
              onTap: () => select(context, host),
              trailing: PopupMenuButton<String>(
                onSelected: (action) async {
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: Text(
                        action == 'revoke' ? '撤销此设备的访问？' : '从手机移除主机？',
                      ),
                      content: Text(
                        action == 'revoke'
                            ? '需要主机在线。撤销后必须重新配对。'
                            : '仅清除手机上的凭证与缓存。主机端凭证不会自动撤销，可稍后使用 bridge revoke。',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('取消'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('确认'),
                        ),
                      ],
                    ),
                  );
                  if (confirmed == true) {
                    await guard(
                      workbench,
                      () => workbench.removeHost(
                        host,
                        revoke: action == 'revoke',
                      ),
                    );
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'revoke', child: Text('撤销设备访问')),
                  const PopupMenuItem(value: 'remove', child: Text('仅从手机移除')),
                ],
              ),
            ),
          ),
        ),
      if (workbench.hosts.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 48),
          child: EmptyState(
            icon: Icons.hub_outlined,
            title: '把开发环境连接过来',
            subtitle: '在主机启动 Bridge，生成配对码。\n扫描二维码，或手动粘贴配对信息。',
            action: FilledButton.icon(
              onPressed: () => pair(context),
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('配对第一台主机'),
            ),
          ),
        ),
      const SizedBox(height: 24),
      const Divider(),
      const SizedBox(height: 16),
      Row(
        children: [
          const Expanded(child: Text('外观')),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(
                value: 'light',
                icon: Icon(Icons.light_mode_outlined),
              ),
              ButtonSegment(
                value: 'system',
                icon: Icon(Icons.brightness_auto_outlined),
              ),
              ButtonSegment(
                value: 'dark',
                icon: Icon(Icons.dark_mode_outlined),
              ),
            ],
            selected: {workbench.theme},
            onSelectionChanged: (selection) =>
                workbench.setTheme(selection.first),
          ),
        ],
      ),
      const SizedBox(height: 24),
      const Text(
        'Codex Bridge · 0.1.1\n非官方个人客户端 · HTTPS / WSS\n无需把 Codex 登录凭证复制到手机',
        style: TextStyle(fontSize: 12, height: 1.8),
      ),
    ],
  );
}

Future<bool?> showPairing(BuildContext context, Workbench workbench) =>
    showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => PairingSheet(workbench: workbench),
    );

class PairingSheet extends StatefulWidget {
  final Workbench workbench;
  const PairingSheet({super.key, required this.workbench});
  @override
  State<PairingSheet> createState() => _PairingSheetState();
}

class _PairingSheetState extends State<PairingSheet> {
  final payload = TextEditingController();
  final url = TextEditingController();
  final code = TextEditingController();
  final pin = TextEditingController();
  final name = TextEditingController(text: 'Android');
  bool accepted = false;
  bool manual = false;
  bool busy = false;
  String? error;
  @override
  void dispose() {
    for (final controller in [payload, url, code, pin, name]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> pair() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final data = manual
          ? <String, dynamic>{
              'url': url.text.trim(),
              'code': code.text.trim(),
              'fingerprint': pin.text.trim().isEmpty ? null : pin.text.trim(),
            }
          : asJson(jsonDecode(payload.text));
      await widget.workbench.pair(
        Pairing.fromJson(data),
        name.text.trim().isEmpty ? 'Android' : name.text.trim(),
      );
      final connected = await _waitForHostConnection(
        widget.workbench,
        widget.workbench.host?.id,
      );
      if (connected && mounted) Navigator.pop(context, true);
    } catch (failure) {
      if (mounted) {
        setState(() {
          error = failure.toString();
          busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(
      24,
      24,
      24,
      24 + MediaQuery.viewInsetsOf(context).bottom,
    ),
    child: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '配对开发主机',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              IconButton(
                tooltip: '关闭',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: busy
                ? null
                : () async {
                    final scanned = await Navigator.push<String>(
                      context,
                      MaterialPageRoute(builder: (_) => const ScannerScreen()),
                    );
                    if (scanned != null && mounted) {
                      setState(() {
                        payload.text = scanned;
                        manual = false;
                      });
                    }
                  },
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('扫描主机上的二维码'),
          ),
          const SizedBox(height: 16),
          if (!manual)
            TextField(
              controller: payload,
              maxLines: 4,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: '粘贴完整配对 JSON',
                hintText: '{"url":"https://...","code":"..."}',
              ),
            ),
          if (manual) ...[
            TextField(
              controller: url,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'HTTPS 主机地址'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: code,
              autocorrect: false,
              decoration: const InputDecoration(labelText: '一次性配对码'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: pin,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'SHA-256 证书指纹（公网 CA 可留空）',
              ),
            ),
          ],
          TextButton(
            onPressed: () => setState(() => manual = !manual),
            child: Text(manual ? '改为粘贴 JSON' : '手动填写各项信息'),
          ),
          TextField(
            controller: name,
            decoration: const InputDecoration(labelText: '这台手机的名称'),
          ),
          const SizedBox(height: 12),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: accepted,
            onChanged: busy
                ? null
                : (value) => setState(() => accepted = value ?? false),
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text(
              '我信任此主机，并了解访问权限',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: const Text('配对后可读写文件、执行命令。默认完整访问，以主机运行账户权限为限。'),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: accepted && !busy ? pair : null,
              child: Text(busy ? '正在验证安全连接…' : '信任并配对'),
            ),
          ),
        ],
      ),
    ),
  );
}

class ScannerScreen extends StatefulWidget {
  const ScannerScreen({super.key});
  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen> {
  bool captured = false;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('扫描配对码')),
    body: MobileScanner(
      onDetect: (capture) {
        final value = capture.barcodes.firstOrNull?.rawValue;
        if (value != null && !captured) {
          captured = true;
          Navigator.pop(context, value);
        }
      },
    ),
  );
}
