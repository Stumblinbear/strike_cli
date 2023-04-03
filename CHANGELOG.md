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
