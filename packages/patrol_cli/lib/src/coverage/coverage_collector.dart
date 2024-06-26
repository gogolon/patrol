import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:coverage/coverage.dart';
import 'package:path/path.dart' as p;
import 'package:platform/platform.dart';
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

Future<ProcessResult> forwardPort(String host, String guest) async {
  print('Forwarding port $host to $guest');

  return Process.run('adb', ['forward', 'tcp:$host', 'tcp:$guest']);
}

Future<Map<String, HitMap>> collectCoverage(
  VmService client,
  Uri vmUri,
  String packageName,
) async {
  final vm = await client.getVM();

  for (final isolate in vm.isolates!) {
    try {
      await client.pause(isolate.id!);
    } catch (e) {
      print(e);
    }
  }

  // the isolates might not be paused yet (see docs of [serviceClient.pause])
  // but it most likely doesn't matter (isolates do not need to be paused
  // to collect coverage successfuly)

  final coverage = await collect(
    vmUri,
    false,
    false,
    false,
    {packageName},
  );

  print('Restrincting to $packageName');

  print("Collected!");

  // TODO: Check if it's possible that the isolates have not been paused yet
  // and they get paused after `resume` requests or is it a queue
  for (final isolate in vm.isolates!) {
    try {
      await client.resume(isolate.id!);
    } catch (e) {
      print(e);
    }
  }

  // TODO: only send to main isolate
  vm.isolates?.forEach((isolate) async {
    if (isolate.id case final id?) {
      try {
        final socket = await WebSocket.connect(client.wsUri!);
        socket.add(
          jsonEncode(
            {
              'jsonrpc': '2.0',
              'id': 21,
              'method': 'ext.patrol.markTestCompleted',
              'params': {'isolateId': id, 'command': 'markTestCompleted'},
            },
          ),
        );
        await socket.close();
      } catch (e) {
        print(e);
      }
    }
  });

  return HitMap.parseJson(coverage['coverage'] as List<Map<String, dynamic>>);
}

Future<void> runCodeCoverage({
  required int testCount,
  required Directory packageDirectory,
}) async {
  final logsProcess = await Process.start('flutter', ['logs']);
  final vmRegex = RegExp('listening on (http.+)');

  final hitmap = <String, HitMap>{};
  String? collectUri;
  var count = 0;

  StreamSubscription<String>? logsSubscription;

  logsSubscription = logsProcess.stdout.transform(utf8.decoder).listen(
    (line) async {
      // print(line);
      final vmLink = vmRegex.firstMatch(line)?.group(1);

      if (vmLink == null || ++count == 1) {
        // We skip first run of the app which patrol makes to >>prepare the list of tests?<<
        return;
      }

      final port = RegExp(':([0-9]+)/').firstMatch(vmLink)!.group(1)!;
      final auth = RegExp(':$port/(.+)').firstMatch(vmLink)!.group(1);

      await forwardPort('61011', port);

      final forwardList = await Process.run('adb', ['forward', '--list']);
      final output = forwardList.stdout as String;
      print('adb forward list: $output');

      // It might be necessary to grab the port from adb forward --list because
      // if debugger was attached, the port might be different from the one we set
      if (RegExp('tcp:([0-9]+) tcp:$port').firstMatch(output)
          case final match?) {
        final hostPort = match.group(1)!;

        print('Host port: $hostPort, auth $auth');

        collectUri = 'http://127.0.0.1:$hostPort/$auth';
        final uri = Uri.parse(collectUri!); // TODO: Do not use !
        final pathSegments =
            uri.pathSegments.where((c) => c.isNotEmpty).toList()..add('ws');
        final replaced = uri.replace(scheme: 'ws', pathSegments: pathSegments);
        final serviceClient = await vmServiceConnectUri(replaced.toString());

        await serviceClient.streamListen('Extension');

        serviceClient.onExtensionEvent.listen(
          (event) async {
            // TODO: Send isolate id through event.data to make it possible
            // to send the message back to this specific isolate only
            if (event.extensionKind == 'waitForCoverageCollection') {
              hitmap.merge(
                await collectCoverage(
                  serviceClient,
                  uri,
                  p.split(packageDirectory.path).last,
                ),
              );
              await serviceClient.dispose();

              if (count - 1 == testCount) {
                // await logsSubscription?.cancel();
                logsProcess.kill();

                print('All coverage gathered, saving');
                final formatted = hitmap.formatLcov(
                  await Resolver.create(packagePath: packageDirectory.path),
                );

                final coverageDirectory = Directory('coverage');

                if (!coverageDirectory.existsSync()) {
                  await coverageDirectory.create();
                }

                await File(
                  coverageDirectory.uri.resolve('patrol_lcov.info').toString(),
                ).writeAsString(formatted);
              }
            }
          },
        );
      } else {
        print('Port forwarding failed');
      }
    },
  );
}
