// ignore_for_file: avoid_dynamic_calls

import 'dart:convert';
import 'dart:io';

import 'package:strike_cli/src/target.dart';
import 'package:strike_cli/src/task.dart';
import 'package:yaml/yaml.dart';

Future<StrikeConfig> loadConfig() async {
  final file = new File('strike.yaml');

  final yamlString = await file.readAsString();

  return StrikeConfig.parse(loadYaml(yamlString));
}

class StrikeConfig {
  const StrikeConfig({required this.targets, required this.tasks});

  factory StrikeConfig.parse(dynamic input) {
    if (input is! Map<dynamic, dynamic>) {
      throw FormatException('Invalid strike.yaml file');
    }

    final targets = <String, Target>{};
    final tasks = <String, Task>{};

    if (input.containsKey('targets')) {
      final inputTargets = input['targets'];

      if (inputTargets is! Map<dynamic, dynamic>) {
        throw FormatException(
          'Config `targets` must be a map',
          jsonEncode(inputTargets),
        );
      }

      for (final entry in inputTargets.entries) {
        final targetName = entry.key;

        if (targetName is! String) {
          throw FormatException(
            'Target name is invalid: must be a string',
            jsonEncode(targetName),
          );
        }

        targets[targetName] = Target.parse(entry.value);
      }
    }

    if (input.containsKey('tasks')) {
      final inputTasks = input['tasks'];

      if (inputTasks is! Map<dynamic, dynamic>) {
        throw FormatException(
          'Config `tasks` must be a map',
          jsonEncode(inputTasks),
        );
      }

      for (final entry in inputTasks.entries) {
        final taskName = entry.key;

        if (taskName is! String) {
          throw FormatException(
            'Task name is invalid: must be a string',
            jsonEncode(taskName),
          );
        }

        tasks[taskName] = Task.parse(entry.value, taskName: taskName);
      }
    }

    return StrikeConfig(targets: targets, tasks: tasks);
  }

  final Map<String, Target> targets;
  final Map<String, Task> tasks;

  dynamic toObject() {
    return {
      'targets': targets.map((key, value) => MapEntry(key, value.toObject())),
      'tasks': tasks.map((key, value) => MapEntry(key, value.toObject())),
    };
  }

  @override
  String toString() {
    return 'StrikeConfig(targets: $targets)';
  }
}
