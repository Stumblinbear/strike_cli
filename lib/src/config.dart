// ignore_for_file: avoid_dynamic_calls

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
        throw FormatException('`targets` must be a map');
      }

      for (final entry in inputTargets.entries) {
        final key = entry.key;

        if (key is! String) {
          throw FormatException(
              '`targets.${entry.key}` is invalid: must be a string');
        }

        targets[key] = Target.parse(entry.value);
      }
    }

    if (input.containsKey('tasks')) {
      final inputTasks = input['tasks'];

      if (inputTasks is! Map<dynamic, dynamic>) {
        throw FormatException('`tasks` must be a map');
      }

      for (final entry in inputTasks.entries) {
        final key = entry.key;

        if (key is! String) {
          throw FormatException(
              '`tasks.${entry.key}` is invalid: must be a string');
        }

        tasks[key] = Task.parse(entry.value);
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
