import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:coverage/coverage.dart';
import 'package:dds/dds_launcher.dart';
import 'package:dds/vm_service_extensions.dart';
import 'package:glob/glob.dart';
import 'package:patrol_cli/src/base/logger.dart';
import 'package:patrol_cli/src/devices.dart';
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

Future<Map<String, HitMap>> _collectCoverage(
  VmService client,
  Uri vmUri,
  String packageName,
  String mainIsolateId,
  Logger logger,
) async {
  final vm = await client.getVM();
  for (final isolate in vm.isolates!) {
    try {
      await client.pause(isolate.id!);
    } catch (err) {
      logger.err('$err');
    }
  }

  final coverage = await collect(
    vmUri,
    false,
    false,
    false,
    {packageName},
  );

  await client.resume(mainIsolateId);

  try {
    final socket = await WebSocket.connect(client.wsUri!);
    socket.add(
      jsonEncode(
        {
          'jsonrpc': '2.0',
          'id': 21,
          'method': 'ext.patrol.markTestCompleted',
          'params': {
            'isolateId': mainIsolateId,
            'command': 'markTestCompleted',
          },
        },
      ),
    );

    await socket.close();
  } catch (err) {
    logger.err('$err');
  }

  final map = await HitMap.parseJson(
    coverage['coverage'] as List<Map<String, dynamic>>,
  );

  return map;
}

Future<ProcessResult> _forwardAdbPort(String host, String guest) async {
  return Process.run('adb', ['forward', 'tcp:$host', 'tcp:$guest']);
}

Uri _createWebSocketUri(Uri uri) {
  final pathSegments = uri.pathSegments.where((c) => c.isNotEmpty).toList()
    ..add('ws');
  return uri.replace(scheme: 'ws', pathSegments: pathSegments);
}

Future<void> _saveCoverage(String report) async {
  final coverageDirectory = Directory('coverage');

  if (!coverageDirectory.existsSync()) {
    await coverageDirectory.create();
  }
  await File(
    coverageDirectory.uri.resolve('patrol_lcov.info').toString(),
  ).writeAsString(report);
}

Future<void> runCodeCoverage({
  required String flutterPackageName,
  required Directory flutterPackageDirectory,
  required TargetPlatform platform,
  required Logger logger,
  required Set<Glob> ignoreGlobs,
}) async {
  final homeDirectory =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];

  final logsProcess = await Process.start(
    'flutter',
    ['logs'],
    workingDirectory: homeDirectory,
  );
  final vmRegex = RegExp('listening on (http.+)');

  final hitMap = <String, HitMap>{};
  int? totalTestCount;
  var count = 0;

  logsProcess.stdout.transform(utf8.decoder).listen(
    (line) async {
      final vmLink = vmRegex.firstMatch(line)?.group(1);

      if (vmLink == null) {
        return;
      }

      final port = RegExp(':([0-9]+)/').firstMatch(vmLink)!.group(1)!;
      final auth = RegExp(':$port/(.+)').firstMatch(vmLink)!.group(1);

      final String? hostPort;

      switch (platform) {
        case TargetPlatform.android:
          await _forwardAdbPort('61011', port);

          // It is necessary to grab the port from adb forward --list because
          // if debugger was attached, the port might be different from the one
          // we set
          final forwardList = await Process.run('adb', ['forward', '--list']);
          final output = forwardList.stdout as String;
          hostPort =
              RegExp('tcp:([0-9]+) tcp:$port').firstMatch(output)?.group(1);
        case TargetPlatform.iOS || TargetPlatform.macOS:
          hostPort = port;
        default:
          hostPort = null;
      }

      if (hostPort == null) {
        logger.err('Failed to obtain Dart VM uri.');
        return;
      }

      final serviceUri = Uri.parse('http://127.0.0.1:$hostPort/$auth');
      final serviceClient = await vmServiceConnectUri(
        _createWebSocketUri(serviceUri).toString(),
      );
      await DartDevelopmentServiceLauncher.start(
        remoteVmServiceUri: serviceUri,
      );
      await serviceClient.requireUserPermissionToResume(onPauseExit: true);

      await serviceClient.streamListen('Extension');

      serviceClient.onExtensionEvent.listen(
        (event) async {
          if (event.extensionKind == 'testCount' && totalTestCount == null) {
            // This is the initial run that patrol makes to learn the structure of
            // the tests (workaround for https://github.com/dart-lang/test/issues/1998)
            totalTestCount = event.extensionData!.data['testCount'] as int;
          }

          if (event.extensionKind == 'waitForCoverageCollection') {
            hitMap.merge(
              await _collectCoverage(
                serviceClient,
                serviceUri,
                flutterPackageName,
                event.extensionData!.data['mainIsolateId'] as String,
                logger,
              ),
            );
            await serviceClient.dispose();

            logger.info('Collected ${++count} / $totalTestCount coverages');

            if (count == totalTestCount) {
              logsProcess.kill();

              logger.info('All coverage gathered, saving');
              final report = hitMap.formatLcov(
                await Resolver.create(
                  packagePath: flutterPackageDirectory.path,
                ),
                ignoreGlobs: ignoreGlobs,
              );

              await _saveCoverage(report);
            }
          }
        },
      );
    },
  );
}
