// Minimal Either/Task utilities for home page compatibility.
// Avoids adding fpdart/dartz as a dependency.

sealed class Either<L, R> {
  const Either();

  T match<T>(T Function(L left) onLeft, T Function(R right) onRight);

  /// Alias for [match] — compatible with fpdart/dartz API.
  T fold<T>(T Function(L left) onLeft, T Function(R right) onRight) =>
      match(onLeft, onRight);

  R? get valueOrNull => switch (this) {
    Right(:final value) => value,
    Left() => null,
  };
}

class Left<L, R> extends Either<L, R> {
  const Left(this.value);
  final L value;
  @override
  T match<T>(T Function(L left) onLeft, T Function(R right) onRight) =>
      onLeft(value);
}

class Right<L, R> extends Either<L, R> {
  const Right(this.value);
  final R value;
  @override
  T match<T>(T Function(L left) onLeft, T Function(R right) onRight) =>
      onRight(value);
}

class Task<T> {
  Task(this._fn);
  final Future<T> Function() _fn;
  Future<T> run() => _fn();
}

class TaskEither<L, R> {
  TaskEither(this._fn);
  final Future<Either<L, R>> Function() _fn;

  Task<R> getOrElse(R Function(L err) fallback) {
    return Task<R>(() async {
      final result = await _fn();
      return result.match(fallback, (r) => r);
    });
  }

  Future<Either<L, R>> run() => _fn();

  static TaskEither<L, R> fromFuture<L, R>(
    Future<R> Function() fn,
    L Function(Object err) toLeft,
  ) {
    return TaskEither(() async {
      try {
        return Right(await fn());
      } catch (e) {
        return Left(toLeft(e));
      }
    });
  }
}
