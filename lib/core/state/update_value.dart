class UpdateValue<T> {
  const UpdateValue.absent()
    : _isPresent = false,
      value = null;

  const UpdateValue.value(this.value) : _isPresent = true;

  final bool _isPresent;
  final T? value;

  bool get isPresent => _isPresent;
}
