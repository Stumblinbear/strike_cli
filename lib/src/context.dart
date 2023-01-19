import 'package:glob/glob.dart';
import 'package:strike_cli/src/config.dart';
import 'package:strike_cli/src/task.dart';

class CommandContext {
  const CommandContext({
    required this.config,
    required this.task,
    required this.args,
    required this.targetFilter,
  });

  final StrikeConfig config;
  final Task task;

  final Map<String, dynamic> args;

  final Glob? targetFilter;

  bool shouldRunFor(String targetPath) =>
      targetFilter == null || targetFilter!.matches(targetPath);
}
