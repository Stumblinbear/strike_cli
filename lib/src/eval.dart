import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:strike_cli/src/context.dart';

typedef EvalParser<T> = T Function(dynamic input);

class Computable<T> {
  const Computable.eval(String code, {EvalParser<T>? parser})
      : code = code,
        value = null,
        parser = parser;
  const Computable.value(T value, {EvalParser<T>? parser})
      : code = null,
        value = value,
        parser = parser;

  factory Computable.from(Object value, {EvalParser<T>? parser}) {
    if (value is String) {
      return Computable.eval(value, parser: parser);
    } else if (value is T) {
      return Computable.value(value as T, parser: parser);
    } else {
      throw ArgumentError.value(value, 'value', 'must be a String or $T');
    }
  }

  final String? code;
  final T? value;
  final EvalParser<T>? parser;

  Future<T> get(CommandContext ctx, {String? target}) async {
    if (value != null) return value!;

    if (code == null) throw StateError('Must have a value or code.');

    var result = await _eval(ctx, code!, target: target);

    if (parser != null) {
      return parser!(result);
    }

    if (result is T) return result;

    if (T == int) {
      if (result is String) {
        var parsed = int.tryParse(result);

        if (parsed != null) {
          return parsed as T;
        }
      }
    } else if (T == double) {
      if (result is String) {
        var parsed = double.tryParse(result);

        if (parsed != null) {
          return parsed as T;
        }
      }
    } else if (T == num) {
      if (result is String) {
        var parsed = num.tryParse(result);

        if (parsed != null) {
          return parsed as T;
        }
      }
    } else if (T == bool) {
      if (result is String) {
        var parsed = result == "true"
            ? true
            : result == "false"
                ? false
                : null;

        if (parsed != null) {
          return parsed as T;
        }
      }
    }

    throw FormatException(
      'Expected $T, but code evaluated to ${result} (${result.runtimeType})',
      code,
    );
  }

  String toObject() {
    return code ?? value.toString();
  }

  @override
  String toString() {
    return 'Computable(code: $code, value: $value, parser: $parser)';
  }
}

/// Source of `quote`, which a command calls to embed a value as exactly one
/// argument: `${args['rest'].map(quote).join(' ')}`. It writes the form
/// `ExecutionCommand._parseArguments` (execute.dart) reads, so a change to one
/// is a change to the other.
const _quoteSource = r'''
String quote(String argument) {
  final buffer = StringBuffer('"');
  var backslashes = 0;

  for (final c in argument.split('')) {
    if (c == '\\') {
      backslashes++;

      continue;
    }

    buffer.write('\\' * (c == '"' ? backslashes * 2 + 1 : backslashes));
    buffer.write(c);

    backslashes = 0;
  }

  buffer.write('\\' * (backslashes * 2));
  buffer.write('"');

  return buffer.toString();
}
''';

Future<dynamic> _eval(CommandContext ctx, String code, {String? target}) async {
  final port = ReceivePort();

  if (code.contains('_isolate') ||
      code.contains('_convert') ||
      code.contains('__var')) {
    throw ArgumentError.value(
        code, 'code', 'cannot contain `_isolate`, `_convert` or `__var`');
  }

  await Isolate.spawnUri(
    Uri.dataFromString(
      '''
    import 'dart:isolate' as _isolate;
    import 'dart:convert' as _convert;

    String base64(String input) => _convert.base64.encode(_convert.utf8.encode(input));

    ${_quoteSource}

    void main(_, _isolate.SendPort port) {
      var params = ${jsonEncode(ctx.task.params)};
      var args = <String, dynamic>${jsonEncode(ctx.args).replaceAll(r'$', r'\$')};
      var target = ${target != null ? "'${target.replaceAll(r'\', '/')}'" : 'null'};
      var platform = "${Platform.operatingSystem}";

      port.send(${jsonEncode(code.replaceAll(r'\$', r'__var'))});
    }
    ''',
      mimeType: 'application/dart',
    ),
    [],
    port.sendPort,
  );

  var result = await port.first;

  if (result is String) {
    result = result.replaceAll(r'__var', r'$');
  }

  return result;
}
