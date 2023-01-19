import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:strike_cli/src/target.dart';
import 'package:strike_cli/src/context.dart';
import 'package:strike_cli/src/eval.dart';
import 'package:strike_cli/src/execute.dart';

class Task {
  const Task(
      {required this.info,
      required this.args,
      required this.params,
      required this.step});

  factory Task.parse(dynamic input, {required String taskName}) {
    if (input is! Map<dynamic, dynamic>) {
      throw FormatException('Invalid task definition', taskName);
    }

    final info = input['info'];

    if (info is! String) {
      throw FormatException(
        'Task `info` must be a string',
        'In task $taskName, info: ${jsonEncode(info)}',
      );
    }

    final params = <String, dynamic>{};

    if (input.containsKey('params')) {
      final inputParams = input['params'];

      if (inputParams is! Map<dynamic, dynamic>) {
        throw FormatException(
          'Task `params` must be an object',
          'In task $taskName, params: ${jsonEncode(params)}',
        );
      }

      for (final entry in inputParams.entries) {
        final paramKey = entry.key;
        final paramValue = entry.value;

        if (paramKey is! String) {
          throw FormatException(
            'Task parameter key must be a string',
            'In task $taskName, params: ${jsonEncode(paramKey)}',
          );
        }

        params[paramKey] = paramValue;
      }
    }

    final args = <TaskArg>[];

    if (input.containsKey('args')) {
      final inputArgs = input['args'];

      if (inputArgs is! List<dynamic>) {
        throw FormatException(
          'Task `args` must be a list',
          'In task $taskName, args: ${jsonEncode(inputArgs)}',
        );
      }

      for (final entry in inputArgs) {
        final arg = TaskArg.parse(entry, taskName: taskName);

        if (args.any((entry) => entry.name == arg.name)) {
          throw FormatException(
            'Task argument `name` must be unique',
            'In task $taskName, args: ${jsonEncode(arg.name)}',
          );
        }

        args.add(arg);
      }
    }

    return Task(
      info: info,
      args: args,
      params: params,
      step: Step.parse(input, taskName: taskName),
    );
  }

  final String info;
  final List<TaskArg> args;
  final Map<String, dynamic> params;
  final Step step;

  dynamic toObject() {
    return {
      'info': info,
      if (args.isNotEmpty) 'args': args.map((e) => e.toObject()).toList(),
      if (params.isNotEmpty) 'params': params,
      'step': step.toObject(),
    };
  }

  @override
  String toString() {
    return 'Task(info: $info, step: $step)';
  }
}

class TaskArg {
  const TaskArg({required this.name, required this.info, required this.type});

  factory TaskArg.parse(dynamic input, {required String taskName}) {
    if (input is! Map<dynamic, dynamic>) {
      throw FormatException(
        'Task argument definition invalid',
        'In task $taskName, args: ${jsonEncode(input)}',
      );
    }

    final name = input['name'];
    final info = input['info'];
    final type = input['type'];
    final defaultVal = input['default'];

    if (name is! String) {
      throw FormatException(
        'Task argument `name` must be a string',
        'In task $taskName, name: ${jsonEncode(name)}',
      );
    }

    if (info is! String) {
      throw FormatException(
        'Task argument `info` must be a string',
        'In task $taskName\'s argument $name, info: ${jsonEncode(info)}',
      );
    }

    if (type is! String) {
      throw FormatException(
        'Task argument `type` must be a string',
        'In task $taskName\'s argument $name, type: ${jsonEncode(type)}',
      );
    }

    ArgType<dynamic>? argType;

    if (type == 'string') {
      List<String>? enumValues = null;

      if (input.containsKey('enum')) {
        final inputEnum = input['enum'];

        if (inputEnum is! List<dynamic>) {
          throw FormatException(
            'Task argument `enum` must be a list',
            'In task $taskName\'s argument $name, enum: ${jsonEncode(inputEnum)}',
          );
        }

        enumValues = [];

        for (final value in inputEnum) {
          enumValues.add(value.toString());
        }
      }

      argType = StringArg(
        defaultVal:
            defaultVal != null ? defaultVal.toString() : defaultVal as String?,
        enumValues: enumValues,
      );
    } else if (type == 'bool') {
      if (defaultVal is! bool?) {
        throw FormatException(
          'Boolean argument `default` must `true` or `false`',
          'In task $taskName\'s argument $name, default: ${jsonEncode(defaultVal)}',
        );
      }

      argType = BooleanArg(
        defaultVal: defaultVal,
      );
    } else {
      throw FormatException(
        'The given argument `type` is unknown',
        'In task $taskName\'s argument $name, type: ${jsonEncode(type)}',
      );
    }

    return TaskArg(
      name: name,
      info: info,
      type: argType,
    );
  }

  final String name;
  final String info;
  final ArgType<dynamic> type;

  dynamic toObject() {
    return {
      'name': name,
      'info': info,
      'type': type.name,
      if (type.defaultVal != null) 'default': type.defaultVal,
    };
  }

  @override
  String toString() {
    return 'TaskArg(name: $name, info: $info, type: $type, defaultVal: ${type.defaultVal})';
  }
}

abstract class ArgType<T> {
  const ArgType({required this.defaultVal});

  final T? defaultVal;

  String get name;

  Iterable<String>? get allowedValues => null;
}

class StringArg extends ArgType<String?> {
  StringArg({required super.defaultVal, this.enumValues});

  List<String>? enumValues;

  @override
  String get name => 'string';

  Iterable<String>? get allowedValues => enumValues;
}

class BooleanArg extends ArgType<bool> {
  BooleanArg({required super.defaultVal});

  @override
  String get name => 'bool';
}

abstract class Step {
  const Step();

  factory Step.run({
    Computable<bool>? condition,
    Computable<String>? name,
    Computable<int>? concurrency,
    required Computable<String> run,
    required Target? target,
    String? workingDirectory,
  }) = StepCommand;

  factory Step.steps({
    Computable<bool>? condition,
    Computable<String>? name,
    Computable<int>? concurrency,
    required List<Step> steps,
  }) = StepGroup;

  factory Step.task({required String task}) = StepTask;

  factory Step.conditional(
      {required Computable<bool> condition,
      required Step onPass,
      required Step onFail}) = StepConditional;

  factory Step.parse(dynamic input, {required String taskName}) {
    if (input is Map<dynamic, dynamic>) {
      final name = input['name'];

      if (name is! String?) {
        throw FormatException(
          'Step `name` must be a string',
          'In task $taskName, name: ${jsonEncode(name)}',
        );
      }

      if (input.containsKey('run')) {
        return StepCommand.parse(input, taskName: taskName, name: name);
      } else if (input.containsKey('steps')) {
        return StepGroup.parse(input, taskName: taskName, name: name);
      } else if (input.containsKey('condition')) {
        return StepConditional.parse(input, taskName: taskName, name: name);
      }
    } else if (input is String) {
      if (input.startsWith('task:')) {
        return StepTask(task: input.split(':')[1]);
      }

      return StepCommand.parse(input, taskName: taskName);
    }

    throw FormatException(
      'Invalid step definition',
      'In task $taskName, ${jsonEncode(input)}',
    );
  }

  Future<Execution> execute(CommandContext ctx);

  Future<bool> shouldRun(CommandContext ctx);

  dynamic toObject();
}

class StepCommand extends Step {
  StepCommand({
    this.name,
    this.condition,
    required this.run,
    Computable<int>? concurrency,
    this.target,
    this.workingDirectory,
  }) : concurrency = concurrency ?? Computable.value(1);

  factory StepCommand.parse(
    dynamic input, {
    required String taskName,
    String? name,
  }) {
    if (input is Map<dynamic, dynamic>) {
      final inputCondition = input['if'];

      if ((inputCondition is! String?) && (inputCondition is! bool)) {
        throw FormatException(
          'Step `if` must be a string or a boolean',
          'In task $taskName${name != null ? '\'s step ${jsonEncode(name)}' : ''}, if: ${jsonEncode(inputCondition)}',
        );
      }

      final condition =
          inputCondition != null ? Computable<bool>.from(inputCondition) : null;

      var run = input['run'];

      if (run == null) {
        throw FormatException(
          'Step must contain a command to `run`',
          'In task $taskName${name != null ? '\'s step ${jsonEncode(name)}' : ''}, run: ${jsonEncode(run)}',
        );
      } else if (run is List<dynamic>) {
        run = run.join(' ');
      } else if (run is! String) {
        throw FormatException(
          'Step `run` must be a string or a list of strings',
          'In task $taskName${name != null ? '\'s step ${jsonEncode(name)}' : ''}, run: ${jsonEncode(run)}',
        );
      }

      final workingDirectory = input['workingDirectory'];

      if (workingDirectory is! String?) {
        throw FormatException(
          'Step `workingDirectory` must be a string',
          'In task $taskName${name != null ? '\'s step ${jsonEncode(name)}' : ''}, workingDirectory: ${jsonEncode(workingDirectory)}',
        );
      }

      final concurrency = input['concurrency'];

      if ((concurrency is! String?) && (concurrency is! int?)) {
        throw FormatException(
          'Step `concurrency` must be a string or number',
          'In task $taskName${name != null ? '\'s step ${jsonEncode(name)}' : ''}, concurrency: ${jsonEncode(concurrency)}',
        );
      }

      Target? target;

      if (input.containsKey('target')) {
        target = Target.parse(input['target']);
      }

      return StepCommand(
        condition: condition,
        name: name != null ? Computable<String>.from(name) : null,
        run: Computable<String>.from(run),
        concurrency: concurrency != null ? Computable.from(concurrency) : null,
        target: target,
        workingDirectory: workingDirectory,
      );
    } else if (input is String) {
      return StepCommand(
        name: name != null ? Computable<String>.from(name) : null,
        run: Computable<String>.from(input),
        concurrency: Computable.value(1),
      );
    } else {
      throw FormatException(
        'Invalid step definition',
        'In task $name, value must be an object or a string',
      );
    }
  }

  final Computable<String>? name;
  final Computable<bool>? condition;
  final Computable<String> run;
  final Computable<int> concurrency;
  final Target? target;
  final String? workingDirectory;

  @override
  Future<bool> shouldRun(CommandContext ctx) {
    if (condition == null) {
      return Future.value(true);
    }

    return condition!.get(ctx);
  }

  @override
  Future<Execution> execute(CommandContext ctx) async {
    final execs = <Execution>[];

    await for (final target
        in target?.resolve(ctx) ?? Stream.value(File(Directory.current.path))) {
      execs.add(
        Execution.cmd(
          command: await run.get(ctx, target: target.path),
          target: target.path,
          workingDirectory: workingDirectory ?? target.path,
        ),
      );
    }

    if (name == null && execs.length == 1) {
      return execs.first;
    }

    return Execution.group(
      name: await name?.get(ctx),
      concurrency: await concurrency.get(ctx),
      exec: execs,
    );
  }

  @override
  Map<dynamic, dynamic> toObject() {
    return {
      if (name != null) 'name': name,
      if (condition != null) 'if': condition!.toObject(),
      'run': run,
      'concurrency': concurrency,
      if (target != null) 'target': target!.toObject(),
      if (workingDirectory != null) 'workingDirectory': workingDirectory,
    };
  }
}

class StepGroup extends Step {
  StepGroup({
    this.name,
    this.condition,
    Computable<int>? concurrency,
    required this.steps,
  }) : concurrency = concurrency ?? Computable<int>.value(1);

  factory StepGroup.parse(
    Map<dynamic, dynamic> input, {
    required String taskName,
    String? name,
  }) {
    final inputCondition = input['if'];

    if ((inputCondition is! String?) && (inputCondition is! bool)) {
      throw FormatException(
        'Step `if` must be a string or a boolean',
        'In task $taskName${name != null ? '\'s step ${jsonEncode(name)}' : ''}, if: ${jsonEncode(inputCondition)}',
      );
    }

    final condition =
        inputCondition != null ? Computable<bool>.from(inputCondition) : null;

    final inputSteps = input['steps'];

    if (inputSteps == null) {
      throw ArgumentError.notNull('steps');
    }

    if (inputSteps is! List<dynamic>) {
      throw FormatException(
        'Step `steps` must be a list',
        'In task $taskName${name != null ? '\'s step ${jsonEncode(name)}' : ''}, steps: ${jsonEncode(inputSteps)}',
      );
    }

    final steps = <Step>[];

    for (final step in inputSteps) {
      steps.add(Step.parse(step, taskName: taskName));
    }

    final concurrency = input['concurrency'];

    if ((concurrency is! String?) && (concurrency is! int?)) {
      throw FormatException(
        'Step `concurrency` must be a string or number',
        'In task $taskName${name != null ? '\'s step ${jsonEncode(name)}' : ''}, concurrency: ${jsonEncode(concurrency)}',
      );
    }

    return StepGroup(
      name: name != null ? Computable.from(name) : null,
      condition: condition,
      concurrency: concurrency != null ? Computable.from(concurrency) : null,
      steps: steps,
    );
  }

  final Computable<String>? name;
  final Computable<bool>? condition;
  final Computable<int> concurrency;
  final List<Step> steps;

  @override
  Future<bool> shouldRun(CommandContext ctx) {
    if (condition == null) {
      return Future.value(true);
    }

    return condition!.get(ctx);
  }

  @override
  Future<Execution> execute(CommandContext ctx) async {
    final execs = <Execution>[];

    for (final step in steps) {
      if (!await step.shouldRun(ctx)) {
        continue;
      }

      execs.add(await step.execute(ctx));
    }

    return Execution.group(
      name: await name?.get(ctx),
      concurrency: await concurrency.get(ctx),
      exec: execs,
    );
  }

  @override
  Map<dynamic, dynamic> toObject() {
    return {
      if (name != null) 'name': name,
      if (condition != null) 'if': condition!.toObject(),
      'concurrency': concurrency,
      'steps': steps.map((e) => e.toObject()).toList(),
    };
  }
}

class StepTask extends Step {
  StepTask({required this.task}) : super();

  final String task;

  Future<bool> shouldRun(CommandContext ctx) async {
    return ctx.config.tasks.containsKey(task);
  }

  @override
  Future<Execution> execute(CommandContext ctx) async {
    return ctx.config.tasks[task]!.step.execute(ctx);
  }

  @override
  Map<dynamic, dynamic> toObject() {
    return {
      'task': task,
    };
  }
}

class StepConditional extends Step {
  StepConditional(
      {this.name,
      required this.condition,
      required this.onPass,
      required this.onFail})
      : super();

  factory StepConditional.parse(Map<dynamic, dynamic> input,
      {required String taskName, String? name}) {
    final inputCondition = input['condition'];

    if ((inputCondition is! String) && (inputCondition is! bool)) {
      throw FormatException(
        'Step `condition` must be a string or a boolean',
        'In task $taskName${name != null ? '\'s step ${jsonEncode(name)}' : ''}, condition: ${jsonEncode(inputCondition)}',
      );
    }

    var inputPass = input['if'];

    if (inputPass != null) {
      inputPass = Step.parse(inputPass, taskName: taskName);
    }

    var inputFail = input['else'];

    if (inputFail != null) {
      inputFail = Step.parse(inputFail, taskName: taskName);
    }

    if (inputPass == null && inputFail == null) {
      throw FormatException(
        'Step `if` or `else` must be defined',
        'In task $taskName${name != null ? '\'s step ${jsonEncode(name)}' : ''}, condition: ${jsonEncode(inputCondition)}',
      );
    }

    return StepConditional(
      name: name != null ? Computable.from(name) : null,
      condition: Computable.from(inputCondition),
      onPass: inputPass as Step?,
      onFail: inputFail as Step?,
    );
  }

  final Computable<String>? name;
  final Computable<bool> condition;
  final Step? onPass;
  final Step? onFail;

  @override
  Future<bool> shouldRun(CommandContext ctx) async {
    return await condition.get(ctx) ? onPass != null : onFail != null;
  }

  @override
  Future<Execution> execute(CommandContext ctx) async {
    return Execution.group(
      name: await name?.get(ctx),
      exec: [
        if (await condition.get(ctx))
          await onPass!.execute(ctx)
        else
          await onFail!.execute(ctx)
      ],
    );
  }

  @override
  Map<dynamic, dynamic> toObject() {
    return {
      if (name != null) 'name': name,
      'condition': condition.toObject(),
      'onPass': onPass?.toObject(),
      'onFail': onFail?.toObject(),
    };
  }
}
