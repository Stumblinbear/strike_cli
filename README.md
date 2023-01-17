# Strike: A CLI task runner for Dart

[![pub package](https://img.shields.io/pub/v/strike_cli.svg)](https://pub.dartlang.org/packages/strike_cli)

## Getting Started

To start using `strike_cli`, run `pub global activate strike_cli`.

Tasks may be run by running `strike <task_name>`.

## Defining Tasks

To define a task, create a `strike.yaml` file in the root of your project. This file will be where you configure your tasks and how they are run. The most basic task you can define is simply an alias for a command. For example, if you wanted to define a task that runs `dart pub get`, you could do so like this:

```yaml
tasks:
  get:
    info: "fetch dependencies"

    name: "Fetching Dependencies"
    run: "dart pub get"
```

However this isn't so useful by itself. It becomes more useful when you wish to run multiple commands in sequence. Lets say you wanted to run `dart pub get` and then `dart test`:

```yaml
tasks:
  get_and_test:
    info: "run tests"

    name: "Running Tests"
    steps:
      - run: "dart pub get"
      - name: "Named step"
        run: "dart test"
```

You can also reference other tasks by using `task:<task_name>` instead of a command.

## Targets

Targets are a way to define a set of tasks that can be run in multiple packages. This helps when you have a large project with many packages. For example, if you wanted to run `dart pub get` all directories within `packages/`, you could do so by defining a target for all packages. Then you can define a task that runs `dart pub get` for all packages.

```yaml
targets:
  packages: packages/*

  # You can also define multiple patterns for a single target
  packages:
    - packages/*
    - third_party/*

tasks:
    get:
        info: "fetch dependencies"

        name: "Fetching Dependencies"
        run: "dart pub get"
        targets: target:packages
        # You also have the option of listing the targets directly
        # targets: packages/*
```

Your targets may also reference other targets.

```yaml
targets:
  packages: packages/*

  all:
    - target:packages
    - foobar/
```

You also have the option of filtering targets. Currently, only the `file_exists` filter is supported. This filter will only include targets that have a file that matches the given pattern.

```yaml
targets:
  packages: packages/*

  # Only include packages with a `build.yaml` file
  build_runner:
    for:
      - packages/*
    # Or use the shorthand syntax, referencing an existing target definition
    # for: target:packages

    filter:
      - type: file_exists
        glob: build.yaml
```

## Concurrency

Running commands sequentially for all of your targets can take a long time. To help with this, you can run commands concurrently. To do so, simply add `concurrency` to define how many commands to execute at once.

```yaml
tasks:
  get:
    info: "fetch dependencies"

    name: "Fetching Dependencies"
    run: "dart pub get"
    concurrency: 4
    targets: target:packages
```

## Arguments

Tasks can also accept arguments. The `args` section is a map of argument names to their default values. You can then access these arguments in your task definition using the `args` variable.

```yaml
tasks:
  integration:
    info: "run integration tests"

    args:
      - name: device
        info: "device to run tests on"
        type: string
        default: null

    run: "flutter test integration_test ${args['device'] ? '-d ${args['device']}' : ''}"
    target: target:app
```

### Conditional Steps

You can also conditionally run steps. This is useful when you want to run a step only if a certain condition is met.

```yaml
tasks:
  foo:
    info: "bla bla bla"

    condition: "platform != 'macos'"
    if:
      - run: "echo 'macos'"
    # Shorthands also work
    else: "echo 'not macos'"

  bar:
    info: "bla bla bla"

    steps:
      - if: "platform != 'macos'"
        name: "namenamename"
        run: "echo 'macos'"
      - "echo 'always runs'"
```

### Nested Steps

You can also nest steps within steps. This is occasionally useful.

```yaml
tasks:
  foo:
    info: "bla bla bla"

    steps:
      - run: "echo 'foo'"
      - steps:
          - run: "echo 'bar'"
          - run: "echo 'baz'"
      - run: "echo 'qux'"
```
