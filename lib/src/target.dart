import 'dart:io';

import 'package:glob/glob.dart';
import 'package:glob/list_local_fs.dart';
import 'package:strike_cli/src/context.dart';
import 'package:path/path.dart' as path;

class Target {
  const Target({required this.resolvers});

  factory Target.parse(dynamic input) {
    return Target(
      resolvers: input is List<dynamic>
          ? input.map(TargetResolver.parse).toList()
          : [TargetResolver.parse(input)],
    );
  }

  final List<TargetResolver> resolvers;

  Stream<File> resolve(CommandContext ctx) async* {
    for (final targetResolver in resolvers) {
      await for (final file in targetResolver.resolve(ctx)) {
        yield file;
      }
    }
  }

  dynamic toObject() {
    if (resolvers.length == 0) {
      return null;
    }

    if (resolvers.length == 1) {
      return resolvers.first.toObject();
    }

    return resolvers.map((e) => e.toObject()).toList();
  }

  @override
  String toString() {
    return 'Target(entries: $resolvers)';
  }
}

class TargetResolver {
  const TargetResolver({required this.resolvers, required this.filters});

  factory TargetResolver.parse(dynamic input) {
    if (input is Map<dynamic, dynamic>) {
      if (!input.containsKey('for')) {
        throw FormatException('Missing `for` in target resolver', input);
      }

      final forValue = input['for'];
      final filterValue = input['filter'] ?? <dynamic>[];

      return TargetResolver(
        resolvers: (forValue is! List<dynamic> ? [forValue] : forValue)
            .map(PathResolver.parse)
            .toList(),
        filters: (filterValue is! List<dynamic> ? [filterValue] : filterValue)
            .map(TargetFilter.parse)
            .toList(),
      );
    } else if (input is List<dynamic>) {
      return TargetResolver(
          resolvers: input.map(PathResolver.parse).toList(), filters: []);
    } else {
      return TargetResolver(
          resolvers: [PathResolver.parse(input)], filters: []);
    }
  }

  final List<PathResolver> resolvers;
  final List<TargetFilter> filters;

  Stream<File> resolve(CommandContext ctx) async* {
    for (final pathResolver in resolvers) {
      nextPath:
      await for (final file in pathResolver.resolve(ctx)) {
        for (final filter in filters) {
          if (!await filter.match(file)) {
            continue nextPath;
          }
        }

        yield file;
      }
    }
  }

  dynamic toObject() {
    if (resolvers.length == 0 && filters.length == 0) {
      return null;
    }

    if (resolvers.length == 1 && filters.length == 0) {
      return resolvers.first.toObject();
    }

    if (filters.length == 0) {
      return resolvers.map((e) => e.toObject()).toList();
    }

    return {
      'for': resolvers.map((e) => e.toObject()).toList(),
      'filters': filters.map((e) => e.toObject()).toList(),
    };
  }

  @override
  String toString() {
    return 'TargetResolver(resolvers: $resolvers, filters: $filters)';
  }
}

abstract class PathResolver {
  factory PathResolver.glob({required String glob}) = GlobPathResolver;
  factory PathResolver.target({required String targetId}) = TargetPathResolver;

  factory PathResolver.parse(dynamic input) {
    if (input is String) {
      if (input.startsWith('target:')) {
        return PathResolver.target(targetId: input.substring(7));
      }

      return PathResolver.glob(glob: input);
    } else {
      throw FormatException('Type must be a string', input);
    }
  }

  Stream<File> resolve(CommandContext ctx);

  dynamic toObject();
}

class GlobPathResolver implements PathResolver {
  GlobPathResolver({required String glob}) : glob = Glob(glob);

  final Glob glob;

  @override
  Stream<File> resolve(CommandContext ctx) async* {
    if (glob.pattern == "." || glob.pattern == "./") {
      yield File(ctx.workspace.path);
    }

    await for (final entity in glob.list(root: ctx.workspace.path)) {
      yield File(path.join(ctx.workspace.path, entity.path));
    }
  }

  @override
  dynamic toObject() {
    return glob;
  }

  @override
  String toString() {
    return 'GlobPathResolver(glob: $glob)';
  }
}

class TargetPathResolver implements PathResolver {
  const TargetPathResolver({required this.targetId});

  final String targetId;

  @override
  Stream<File> resolve(CommandContext ctx) {
    final target = ctx.config.targets[targetId];

    if (target == null) {
      throw Exception('Target `$targetId` not found');
    }

    return target.resolve(ctx);
  }

  @override
  dynamic toObject() {
    return 'target:$targetId';
  }

  @override
  String toString() {
    return 'TargetPathResolver(target: $targetId)';
  }
}

abstract class TargetFilter {
  factory TargetFilter.parse(dynamic input) {
    if (input is Map<dynamic, dynamic>) {
      if (!input.containsKey('type')) {
        throw FormatException('Missing `type`', input);
      }

      final type = input['type'];

      if (type is! String) {
        throw FormatException('Value of `type` must be a string', input);
      }

      if (type == 'file_exists') {
        return FileExistsTargetFilter.parse(input);
      }
    }

    throw FormatException('Invalid filter definition', input);
  }

  Future<bool> match(File file);

  dynamic toObject();
}

class FileExistsTargetFilter implements TargetFilter {
  FileExistsTargetFilter({required String glob}) : glob = Glob(glob);

  factory FileExistsTargetFilter.parse(Map<dynamic, dynamic> input) {
    if (!input.containsKey('glob')) {
      throw FormatException('Missing `glob` in "file_exists" filter', input);
    }

    final glob = input['glob'];

    if (glob is! String) {
      throw FormatException('`glob` must be a string', input);
    }

    return FileExistsTargetFilter(glob: glob);
  }

  final Glob glob;

  @override
  Future<bool> match(File file) async {
    return !await glob.list(root: file.path).isEmpty;
  }

  @override
  dynamic toObject() {
    return {
      'type': 'file_exists',
      'glob': glob,
    };
  }

  @override
  String toString() {
    return 'FileExistsTargetFilter(glob: $glob)';
  }
}
