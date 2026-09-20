import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:codex_bridge/main.dart';
import 'package:codex_bridge/data/models.dart';
import 'package:codex_bridge/data/storage.dart';
import 'package:codex_bridge/data/workbench.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const url = String.fromEnvironment('BRIDGE_URL');
  const code = String.fromEnvironment('BRIDGE_PAIR_CODE');
  const pin = String.fromEnvironment('BRIDGE_PIN');
  const project = String.fromEnvironment('BRIDGE_PROJECT');

  testWidgets(
    'real Android HTTPS pairing, Codex execution, reconnect, files, and PTY',
    (tester) async {
      expect(
        url,
        isNotEmpty,
        reason:
            'Pass --dart-define-from-file with generated integration settings.',
      );
      final workbench = Workbench(DeviceStore())..initialized = true;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [workbenchProvider.overrideWith((ref) => workbench)],
          child: const BridgeApp(),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> until(bool Function() condition, {int seconds = 90}) async {
        final deadline = DateTime.now().add(Duration(seconds: seconds));
        while (!condition() && DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 200));
        }
        expect(
          condition(),
          isTrue,
          reason: workbench.error ?? workbench.status,
        );
      }

      await tester.ensureVisible(find.text('配对第一台主机'));
      await tester.tap(find.text('配对第一台主机'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField).first,
        jsonEncode({'url': url, 'code': code, 'fingerprint': pin}),
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byType(Checkbox));
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('信任并配对'));
      await tester.tap(find.text('信任并配对'));
      await until(() => workbench.online && workbench.models.isNotEmpty);
      final persisted = asJson(await DeviceStore().read('settings'));
      expect(asList(persisted['hosts']).single['id'], workbench.host!.id);
      expect(await DeviceStore().token(workbench.host!.id), isNotEmpty);
      await tester.pumpAndSettle();
      await workbench.addProject(project, 'Android 验证项目');
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField).first,
        'Do not delegate or use subagents. Create android-e2e.txt in this project containing exactly ANDROID_AGENT_OK and a newline. Run a shell command to verify its contents. Do not modify any other file. Reply briefly.',
      );
      await tester.tap(find.byTooltip('发送任务'));
      await until(
        () =>
            workbench.running != null ||
            workbench.items.any((entry) => entry['type'] == 'agentMessage'),
      );
      final selectedHost = workbench.host!;
      await workbench.flush();
      await workbench.transport!.close();
      workbench.status = 'offline';
      workbench.clearError();
      await tester.pump(const Duration(seconds: 5));
      await workbench.selectHost(selectedHost);
      await until(
        () =>
            workbench.online &&
            workbench.items.any((entry) => entry['type'] == 'agentMessage') &&
            workbench.running == null,
        seconds: 180,
      );
      final file = asJson(
        await workbench.rpc('files/read', {
          'projectId': workbench.projectId,
          'path': 'android-e2e.txt',
        }),
      );
      expect(file['content'].toString().trim(), 'ANDROID_AGENT_OK');
      final uploaded = await workbench.upload(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jG3sAAAAASUVORK5CYII=',
        ),
      );
      expect(uploaded['type'], 'localImage');
      expect(uploaded['path'].toString(), contains('.codex-bridge-uploads'));
      await workbench.rpc('files/save', {
        'projectId': workbench.projectId,
        'path': 'android-e2e.txt',
        'version': file['version'],
        'content': 'ANDROID_EDIT_OK\n',
      });
      await expectLater(
        workbench.rpc('files/save', {
          'projectId': workbench.projectId,
          'path': 'android-e2e.txt',
          'version': file['version'],
          'content': 'stale',
        }),
        throwsA(
          isA<RpcException>().having(
            (error) => error.code,
            'code',
            'FILE_CONFLICT',
          ),
        ),
      );
      final session = asJson(
        await workbench.rpc('terminal/open', {
          'projectId': workbench.projectId,
        }),
      );
      await tester.pump(const Duration(seconds: 2));
      await workbench.rpc('terminal/write', {
        'projectId': workbench.projectId,
        'id': session['id'],
        'deltaBase64': base64Encode(
          utf8.encode("Write-Output ('ANDROID_PTY_' + 'OK')\r"),
        ),
      });
      await tester.pump(const Duration(seconds: 2));
      final terminal = asJson(
        await workbench.rpc('terminal/read', {
          'projectId': workbench.projectId,
          'id': session['id'],
        }),
      );
      expect(terminal['output'].toString(), contains('ANDROID_PTY_OK'));
      await workbench.transport!.close();
      await workbench.selectHost(selectedHost);
      await until(() => workbench.online);
      await workbench.rpc('terminal/write', {
        'projectId': workbench.projectId,
        'id': session['id'],
        'deltaBase64': base64Encode(utf8.encode('Start-Sleep -Seconds 30\r')),
      });
      await tester.pump(const Duration(seconds: 1));
      await workbench.rpc('terminal/write', {
        'projectId': workbench.projectId,
        'id': session['id'],
        'deltaBase64': base64Encode([3]),
      });
      await tester.pump(const Duration(seconds: 1));
      await workbench.rpc('terminal/write', {
        'projectId': workbench.projectId,
        'id': session['id'],
        'deltaBase64': base64Encode(
          utf8.encode("Write-Output ('AFTER_INTERRUPT_' + 'OK')\r"),
        ),
      });
      await tester.pump(const Duration(seconds: 2));
      final reattached = asJson(
        await workbench.rpc('terminal/read', {
          'projectId': workbench.projectId,
          'id': session['id'],
        }),
      );
      expect(reattached['output'].toString(), contains('ANDROID_PTY_OK'));
      expect(reattached['output'].toString(), contains('AFTER_INTERRUPT_OK'));
      await workbench.rpc('terminal/resize', {
        'projectId': workbench.projectId,
        'id': session['id'],
        'cols': 80,
        'rows': 24,
      });
      await workbench.rpc('terminal/close', {
        'projectId': workbench.projectId,
        'id': session['id'],
      });
      await workbench.flush();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
    timeout: const Timeout(Duration(minutes: 7)),
  );
}
