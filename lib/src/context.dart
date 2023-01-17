import 'package:strike_cli/src/config.dart';
import 'package:strike_cli/src/task.dart';

class CommandContext {
  const CommandContext({
    required this.config,
    required this.task,
    required this.args,
  });

  final StrikeConfig config;
  final Task task;

  final Map<String, dynamic> args;
}
