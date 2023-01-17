import 'dart:async';
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

  factory Task.parse(dynamic input) {
    if (input is! Map<dynamic, dynamic>) {
      throw FormatException('Invalid task definition', input);
    }

    final info = input['info'];

    if (info is! String) {
      throw FormatException('Task `info` must be a string', input);
    }

    final params = <String, dynamic>{};

    if (input.containsKey('params')) {
      final inputParams = input['params'];

      if (inputParams is! Map<dynamic, dynamic>) {
        throw FormatException('Task `params` must be a map', input);
      }

      for (final entry in inputParams.entries) {
        final paramKey = entry.key;
        final paramValue = entry.value;

        if (paramKey is! String) {
          throw FormatException('Task parameter key must be a string', input);
        }

        params[paramKey] = paramValue;
      }
    }

    final args = <TaskArg>[];

    if (input.containsKey('args')) {
      final inputArgs = input['args'];

      if (inputArgs is! List<dynamic>) {
        throw FormatException('Task `args` must be a list', input);
      }

      for (final entry in inputArgs) {
        if (entry is! Map<dynamic, dynamic>) {
          throw FormatException('Task argument must be a map', entry);
        }

        final argName = entry['name'];

        if (argName is! String) {
          throw FormatException('Task argument `name` must be a string', entry);
        }

        final arg = TaskArg.parse(entry);

        if (args.any((entry) => entry.name == arg.name)) {
          throw FormatException('Task argument `name` must be unique', arg);
        }

        args.add(arg);
      }
    }

    return Task(
      info: info,
      args: args,
      params: params,
      step: Step.parse(input),
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

  factory TaskArg.parse(dynamic input) {
    if (input is! Map<dynamic, dynamic>) {
      throw FormatException('Invalid task argument definition', input);
    }

    final name = input['name'];
    final info = input['info'];
    final type = input['type'];
    final defaultVal = input['default'];

    if (name is! String) {
      throw FormatException('Argument`name` must be a string', input);
    }

    if (info is! String) {
      throw FormatException('Argument `info` must be a string', input);
    }

    if (type is! String) {
      throw FormatException('Argument `type` must be a string', input);
    }

    ArgType<dynamic>? argType;

    if (type == 'string') {
      List<String>? enumValues = null;

      if (input.containsKey('enum')) {
        final inputEnum = input['enum'];

        if (inputEnum is! List<dynamic>) {
          throw FormatException('Argument `enum` must be a list', input);
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
            'Boolean argument `default` must `true` or `false`', input);
      }

      argType = BooleanArg(
        defaultVal: defaultVal,
      );
    } else {
      throw FormatException('The given argument `type` is unknown', input);
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
    StepCondition? condition,
    String? name,
    int? concurrency,
    required String run,
    required Target? target,
    String? workingDirectory,
  }) = StepCommand;

  factory Step.steps({
    StepCondition? condition,
    String? name,
    int? concurrency,
    required List<Step> steps,
  }) = StepGroup;

  factory Step.task({required String task}) = StepTask;

  factory Step.conditional(
      {required StepCondition condition,
      required Step onPass,
      required Step onFail}) = StepConditional;

  factory Step.parse(dynamic input) {
    if (input is Map<dynamic, dynamic>) {
      final name = input['name'];

      if (name is! String?) {
        throw FormatException('Step `name` must be a string', input);
      }

      if (input.containsKey('run')) {
        return StepCommand.parse(input, name: name);
      } else if (input.containsKey('steps')) {
        return StepGroup.parse(input, name: name);
      } else if (input.containsKey('condition')) {
        return StepConditional.parse(input, name: name);
      }
    } else if (input is String) {
      if (input.startsWith('task:')) {
        return StepTask(task: input.split(':')[1]);
      }

      return StepCommand.parse(input);
    }

    throw FormatException('Invalid step definition', input);
  }

  Future<Execution> execute(CommandContext ctx);

  Future<bool> shouldRun(CommandContext ctx);

  dynamic toObject();
}

class StepCondition {
  StepCondition(this.code);

  String code;

  Future<bool> evaluate(CommandContext ctx) async {
    return eval<bool>(ctx, code);
  }

  String toObject() {
    return code;
  }

  @override
  String toString() {
    return 'StepCondition(code: $code)';
  }
}

class StepCommand extends Step {
  StepCommand({
    this.name,
    this.condition,
    required this.run,
    int? concurrency,
    this.target,
    this.workingDirectory,
  }) : concurrency = concurrency ?? 1;

  factory StepCommand.parse(dynamic input, {String? name}) {
    if (input is Map<dynamic, dynamic>) {
      final inputCondition = input['if'];

      if (inputCondition is! String?) {
        throw FormatException('Step `if` must be a string', input);
      }

      final condition =
          inputCondition != null ? StepCondition(inputCondition) : null;

      var run = input['run'];

      if (run == null) {
        throw FormatException('Step must contain a command to `run`', input);
      } else if (run is List<dynamic>) {
        run = run.join(' ');
      } else if (run is! String) {
        throw FormatException(
            'Step `run` must be a string or a list of strings', input);
      }

      final workingDirectory = input['workingDirectory'];

      if (workingDirectory is! String?) {
        throw FormatException(
            'Step `workingDirectory` must be a string', input);
      }

      final concurrency = input['concurrency'];

      if (concurrency is! int?) {
        throw FormatException('Step `concurrency` must be a number', input);
      }

      Target? target;

      if (input.containsKey('target')) {
        target = Target.parse(input['target']);
      }

      return StepCommand(
        condition: condition,
        name: name,
        run: run as String,
        concurrency: concurrency ?? 1,
        target: target,
        workingDirectory: workingDirectory,
      );
    } else if (input is String) {
      return StepCommand(
        name: name,
        run: input,
        concurrency: 1,
      );
    } else {
      throw FormatException('Invalid step definition', input);
    }
  }

  final String? name;
  final StepCondition? condition;
  final String run;
  final int concurrency;
  final Target? target;
  final String? workingDirectory;

  @override
  Future<bool> shouldRun(CommandContext ctx) {
    if (condition == null) {
      return Future.value(true);
    }

    return condition!.evaluate(ctx);
  }

  @override
  Future<Execution> execute(CommandContext ctx) async {
    final execs = <Execution>[];

    await for (final target
        in target?.resolve(ctx) ?? Stream.value(File(Directory.current.path))) {
      execs.add(
        Execution.cmd(
          ctx,
          command: run,
          target: target.path,
          workingDirectory: workingDirectory ?? target.path,
        ),
      );
    }

    if (name == null && execs.length == 1) {
      return execs.first;
    }

    return Execution.group(
      ctx,
      name: name,
      concurrency: concurrency,
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
    int? concurrency,
    required this.steps,
  }) : concurrency = concurrency ?? 1;

  factory StepGroup.parse(Map<dynamic, dynamic> input, {String? name}) {
    final inputCondition = input['if'];

    if (inputCondition is! String?) {
      throw FormatException('Step `if` must be a string', input);
    }

    final condition =
        inputCondition != null ? StepCondition(inputCondition) : null;

    final inputSteps = input['steps'];

    if (inputSteps == null) {
      throw ArgumentError.notNull('steps');
    }

    if (inputSteps is! List<dynamic>) {
      throw FormatException('Step `steps` must be a list', input);
    }

    final steps = <Step>[];

    for (final step in inputSteps) {
      steps.add(Step.parse(step));
    }

    final concurrency = input['concurrency'];

    if (concurrency is! int?) {
      throw FormatException('Step `concurrency` must be a number', input);
    }

    return StepGroup(
      condition: condition,
      name: name,
      concurrency: concurrency ?? 1,
      steps: steps,
    );
  }

  final String? name;
  final StepCondition? condition;
  final int concurrency;
  final List<Step> steps;

  @override
  Future<bool> shouldRun(CommandContext ctx) {
    if (condition == null) {
      return Future.value(true);
    }

    return condition!.evaluate(ctx);
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
      ctx,
      name: name,
      concurrency: concurrency,
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

  factory StepConditional.parse(Map<dynamic, dynamic> input, {String? name}) {
    final inputCondition = input['condition'];

    if (inputCondition == null) {
      throw FormatException('Step `condition` must be defined', input);
    }

    if (inputCondition is! String) {
      throw FormatException('Step `condition` must be a string', input);
    }

    final condition = StepCondition(inputCondition);

    var inputPass = input['if'];

    if (inputPass != null) {
      inputPass = Step.parse(inputPass);
    }

    var inputFail = input['else'];

    if (inputFail != null) {
      inputFail = Step.parse(inputFail);
    }

    if (inputPass == null && inputFail == null) {
      throw FormatException('Step `if` or `else` must be defined', input);
    }

    return StepConditional(
      name: name,
      condition: condition,
      onPass: inputPass as Step?,
      onFail: inputFail as Step?,
    );
  }

  final String? name;
  final StepCondition condition;
  final Step? onPass;
  final Step? onFail;

  @override
  Future<bool> shouldRun(CommandContext ctx) async {
    return await condition.evaluate(ctx) ? onPass != null : onFail != null;
  }

  @override
  Future<Execution> execute(CommandContext ctx) async {
    return Execution.group(
      ctx,
      name: name,
      exec: [
        if (await condition.evaluate(ctx))
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
