## 0.7.7

- Return text with nothing to interpolate without evaluating it, and evaluate identical expressions once per run
- With `--no-progress`, start the next command as soon as any running one finishes, and print each command's result when it finishes
- Fix `--no-progress` printing only one more line once every command had finished, and dropping the rest
- Fix expressions failing when any argument or parameter contains a non-ASCII character
- Fix text with nothing to interpolate failing when it contains `_isolate`, `_convert` or `__var`
- After a command fails, wait for the commands still running before exiting, and on Ctrl+C kill each running command with every process it started, so none outlives strike
- Add `killAfterFailure`, the seconds a task gives its running commands after the first failure before killing them, which also applies to a task run through a `task:` step
- Report a command that cannot start as a failure and wait for the others, instead of crashing and leaving them running
- Keep commands from outliving strike when one prints text that is not UTF-8, on Ctrl+C in progress mode with stdin redirected, and on SIGTERM or SIGHUP outside Windows, which now act as Ctrl+C
- On Windows, end every command with strike when its console closes, it is ended or it crashes, and leave running any process a command started to outlive it unless the run was stopped or a command was killed
- On Linux and macOS, send SIGTERM to a killed command's processes and SIGKILL to those still running 5 seconds later, and leave ignored a signal strike started with ignored, so `nohup strike` keeps working
- List the commands strike killed by name in the failure report, below the output of those that failed
- Require Dart 3.4 or later

## 0.7.6

- Fix `args['rest'].map(quote)` failing when no positional arguments are given

## 0.7.5

- Add `quote`, which embeds a value in a command as exactly one argument
- Keep whitespace inside quotes as written
- Join quoted text with the text around it, and read backslashes as Windows does: literal unless they precede a quote

## 0.7.4

- Make positional arguments available to commands as `args['rest']`

## 0.7.3

- Fix escaping of spaces in commands

## 0.7.2

- Support computed environment variables

## 0.7.1

- Support computed targets

## 0.7.0

- Update SDK constraints
- Propagate `workingDirectory` to nested definitions
- Use ▪ for pending and skipped commands
- Remove initial check for runnable commands so that the "No commands to run" format is consistent in all cases
- Improve errors when a step configuration is invalid

## 0.6.0

- Lock down access to imports during evaluation
- Make a base64 encoder available to commands

## 0.5.2

- Use relative paths for targets

## 0.5.1

- Turns out windows needs to be run in a shell for many commands
- Fix accidental revert of quoted args

## 0.5.0

- Run windows commands outside of shell
- Add `succeed` configuration, to allow a task to succeed even if it fails

## 0.4.2

- Fix quotes being omitted during command parsing

## 0.4.1

- Fail fast when using --no-progress

## 0.4.0

- Add env variables to steps
- Split single quotes in commands

## 0.3.3

- Fix naieve command argument splitting

## 0.3.2

- Add `executables` entry to `pubspec.yaml`
- Fix an infinite loop if no `strike.yaml` is found
- Print a better error when no `strike.yaml` is found

## 0.3.1

- Reduce path package version requirement

## 0.3.0

- Config searching for workspaces
- Run all commands in the workspace root
- Filter targets by the current directory by default

## 0.2.1

- Fix parsing of evaluated booleans

## 0.2.0

- Add task filtering option
- Fix inability to target the current directory

## 0.1.1

- Fix target path not accessible in commands

## 0.0.2

- Better errors when misconfigured
- Support evaluation in more locations

## 0.0.1

- Initial release
