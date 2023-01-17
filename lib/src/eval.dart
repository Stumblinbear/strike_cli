// ignore_for_file: deprecated_member_use

import 'dart:cli';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:strike_cli/src/context.dart';

String evalReplaceString(CommandContext ctx, String code, {String? target}) {
  return code.replaceAllMapped(
    RegExp(r'\$\{(.+?)\}'),
    (match) {
      final code = match.group(1)!;

      return eval<dynamic>(ctx, code, target: target).toString();
    },
  );
}

T eval<T>(CommandContext ctx, String code, {String? target}) {
  final port = ReceivePort();

  waitFor(
    Isolate.spawnUri(
      Uri.dataFromString(
        '''
    import 'dart:isolate';

    void main(_, SendPort port) {
      var params = ${jsonEncode(ctx.task.params)};
      var args = ${jsonEncode(ctx.args)};
      var target = ${target != null ? "'${target.replaceAll(r'\', '/')}'" : 'null'};
      var platform = "${Platform.operatingSystem}";

      port.send($code);
    }
    ''',
        mimeType: 'application/dart',
      ),
      [],
      port.sendPort,
    ),
  );

  return waitFor(port.first, timeout: Duration(seconds: 1)) as T;
}
