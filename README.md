# Strike: A CLI task runner for Dart

[![pub package](https://img.shields.io/pub/v/strike_cli.svg)](https://pub.dartlang.org/packages/strike_cli)

```
❯ strike setup
Setting up Git Hooks
|  ✓ git config --local core.hooksPath .githooks
Fetching Dependencies (5/5)
|  ✓ flutter pub get (in ./app)
|  ✓ flutter pub get (in ./packages/auth)
|  ✓ flutter pub get (in ./packages/checkout)
|  ✓ flutter pub get (in ./packages/core)
|  ✓ flutter pub get (in ./packages/storefront)
Generating Code (0/4)
| ⠈⢙ flutter pub run build_runner build --delete-conflicting-outputs (in ./packages\auth)
| ⠄⡙ flutter pub run build_runner build --delete-conflicting-outputs (in ./packages\checkout)
| ⡋⠁ flutter pub run build_runner build --delete-conflicting-outputs (in ./packages\core)
|  ▪ flutter pub run build_runner build --delete-conflicting-outputs (in ./packages\storefront)
Running Tests (0/3)
|  ▪ flutter test (in .\packages\auth)
|  ▪ flutter test (in .\packages\checkout)
|  ▪ flutter test (in .\packages\storefront)
```

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
        target: target:packages
        # You also have the option of listing the targets directly
        # target: packages/*
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
    target: target:packages
```

## Failures

When a command fails, strike starts no more commands, waits for the ones still running to finish, then reports every failure with its output. Commands strike killed are listed by name below them.

To stop waiting, set `killAfterFailure` on a task to the number of seconds the running commands get after the first failure. Any still running then are killed, along with every process they started. `0` kills them as soon as a command fails. Like `concurrency`, the value can be an expression.

```yaml
tasks:
  test:
    info: "run tests"

    run: "flutter test"
    concurrency: 4
    target: target:packages
    killAfterFailure: 10
```

A task's `killAfterFailure` covers its own commands wherever it runs, including when another task runs it with `task:`. The clock starts at the first failure among that task's commands. When both tasks set it, each kills its own commands: if `outer` sets `5` and runs `inner`, which sets `1`, a failure in `inner` kills `inner`'s running commands after 1 second and the rest of `outer`'s after 5.

Pressing Ctrl+C, with or without `--no-progress`, kills every running command, along with every process it started, then reports the failures as above. On Linux and macOS, SIGTERM and SIGHUP do the same, except that a signal strike started with ignored stays ignored, so `nohup strike` keeps running when the terminal closes. On both, a kill sends SIGTERM to every process in the tree, then SIGKILL to any still running 5 seconds later.

On Windows, closing strike's console, ending it from Task Manager, Ctrl+Break or a crash ends every running command and every process under it along with strike. A process a command starts to outlive it, such as a daemon, keeps running after strike exits, unless the run was stopped or a command was killed. Then it ends with strike too, along with any process a kill could not reach because its parent had already exited.

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

Positional arguments, and everything after `--`, are available as the list `args['rest']`, so `strike test test/foo_test.dart -- --plain-name "two words"` can forward them. `quote` wraps a value so it reaches the command as exactly one argument, whatever spaces, quotes or backslashes it holds. A task cannot declare an argument named `rest`.

```yaml
tasks:
  test:
    info: "run tests"

    run: "flutter test ${args['rest'].map(quote).join(' ')}"
    target: target:packages
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
