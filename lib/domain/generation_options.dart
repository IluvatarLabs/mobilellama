final class GenerationOptions {
  const GenerationOptions({
    this.temperature,
    this.seed,
    this.maxTokens,
    this.contextSize,
    this.repeatLastN,
    this.repeatPenalty,
    this.tailFreeSampling,
    this.topK,
    this.topP,
    this.minP,
    this.mirostat,
    this.mirostatEta,
    this.mirostatTau,
  });

  final double? temperature;
  final int? seed;
  final int? maxTokens;
  final int? contextSize;
  final int? repeatLastN;
  final double? repeatPenalty;
  final double? tailFreeSampling;
  final int? topK;
  final double? topP;
  final double? minP;
  final int? mirostat;
  final double? mirostatEta;
  final double? mirostatTau;

  bool get isEmpty =>
      temperature == null &&
      seed == null &&
      maxTokens == null &&
      contextSize == null &&
      repeatLastN == null &&
      repeatPenalty == null &&
      tailFreeSampling == null &&
      topK == null &&
      topP == null &&
      minP == null &&
      mirostat == null &&
      mirostatEta == null &&
      mirostatTau == null;

  void validate() {
    _checkNonNegativeFinite('temperature', temperature);
    _checkNonNegativeInt('seed', seed);
    if (maxTokens != null && maxTokens! < -2) {
      throw ArgumentError.value(
        maxTokens,
        'maxTokens',
        'must be at least -2',
      );
    }
    if (contextSize != null && contextSize! <= 0) {
      throw ArgumentError.value(contextSize, 'contextSize', 'must be positive');
    }
    if (repeatLastN != null && repeatLastN! < -1) {
      throw ArgumentError.value(
        repeatLastN,
        'repeatLastN',
        'must be at least -1',
      );
    }
    _checkNonNegativeFinite('repeatPenalty', repeatPenalty);
    _checkNonNegativeFinite('tailFreeSampling', tailFreeSampling);
    _checkNonNegativeInt('topK', topK);
    _checkProbability('topP', topP);
    _checkProbability('minP', minP);
    if (mirostat != null && (mirostat! < 0 || mirostat! > 2)) {
      throw ArgumentError.value(mirostat, 'mirostat', 'must be 0, 1, or 2');
    }
    _checkNonNegativeFinite('mirostatEta', mirostatEta);
    _checkNonNegativeFinite('mirostatTau', mirostatTau);
  }

  Map<String, Object> toOllamaJson() {
    validate();
    return <String, Object>{
      if (temperature != null) 'temperature': temperature!,
      if (seed != null) 'seed': seed!,
      if (maxTokens != null) 'num_predict': maxTokens!,
      if (contextSize != null) 'num_ctx': contextSize!,
      if (repeatLastN != null) 'repeat_last_n': repeatLastN!,
      if (repeatPenalty != null) 'repeat_penalty': repeatPenalty!,
      if (tailFreeSampling != null) 'tfs_z': tailFreeSampling!,
      if (topK != null) 'top_k': topK!,
      if (topP != null) 'top_p': topP!,
      if (minP != null) 'min_p': minP!,
      if (mirostat != null) 'mirostat': mirostat!,
      if (mirostatEta != null) 'mirostat_eta': mirostatEta!,
      if (mirostatTau != null) 'mirostat_tau': mirostatTau!,
    };
  }

  factory GenerationOptions.fromJson(Map<String, Object?> json) {
    final options = GenerationOptions(
      temperature: _readDouble(json, 'temperature'),
      seed: _readInt(json, 'seed'),
      maxTokens: _readInt(json, 'num_predict'),
      contextSize: _readInt(json, 'num_ctx'),
      repeatLastN: _readInt(json, 'repeat_last_n'),
      repeatPenalty: _readDouble(json, 'repeat_penalty'),
      tailFreeSampling: _readDouble(json, 'tfs_z'),
      topK: _readInt(json, 'top_k'),
      topP: _readDouble(json, 'top_p'),
      minP: _readDouble(json, 'min_p'),
      mirostat: _readInt(json, 'mirostat'),
      mirostatEta: _readDouble(json, 'mirostat_eta'),
      mirostatTau: _readDouble(json, 'mirostat_tau'),
    );
    options.validate();
    return options;
  }

  GenerationOptions copyWith({
    Object? temperature = _notProvided,
    Object? seed = _notProvided,
    Object? maxTokens = _notProvided,
    Object? contextSize = _notProvided,
    Object? repeatLastN = _notProvided,
    Object? repeatPenalty = _notProvided,
    Object? tailFreeSampling = _notProvided,
    Object? topK = _notProvided,
    Object? topP = _notProvided,
    Object? minP = _notProvided,
    Object? mirostat = _notProvided,
    Object? mirostatEta = _notProvided,
    Object? mirostatTau = _notProvided,
  }) {
    final options = GenerationOptions(
      temperature: identical(temperature, _notProvided)
          ? this.temperature
          : temperature as double?,
      seed: identical(seed, _notProvided) ? this.seed : seed as int?,
      maxTokens: identical(maxTokens, _notProvided)
          ? this.maxTokens
          : maxTokens as int?,
      contextSize: identical(contextSize, _notProvided)
          ? this.contextSize
          : contextSize as int?,
      repeatLastN: identical(repeatLastN, _notProvided)
          ? this.repeatLastN
          : repeatLastN as int?,
      repeatPenalty: identical(repeatPenalty, _notProvided)
          ? this.repeatPenalty
          : repeatPenalty as double?,
      tailFreeSampling: identical(tailFreeSampling, _notProvided)
          ? this.tailFreeSampling
          : tailFreeSampling as double?,
      topK: identical(topK, _notProvided) ? this.topK : topK as int?,
      topP: identical(topP, _notProvided) ? this.topP : topP as double?,
      minP: identical(minP, _notProvided) ? this.minP : minP as double?,
      mirostat: identical(mirostat, _notProvided)
          ? this.mirostat
          : mirostat as int?,
      mirostatEta: identical(mirostatEta, _notProvided)
          ? this.mirostatEta
          : mirostatEta as double?,
      mirostatTau: identical(mirostatTau, _notProvided)
          ? this.mirostatTau
          : mirostatTau as double?,
    );
    options.validate();
    return options;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GenerationOptions &&
          temperature == other.temperature &&
          seed == other.seed &&
          maxTokens == other.maxTokens &&
          contextSize == other.contextSize &&
          repeatLastN == other.repeatLastN &&
          repeatPenalty == other.repeatPenalty &&
          tailFreeSampling == other.tailFreeSampling &&
          topK == other.topK &&
          topP == other.topP &&
          minP == other.minP &&
          mirostat == other.mirostat &&
          mirostatEta == other.mirostatEta &&
          mirostatTau == other.mirostatTau;

  @override
  int get hashCode => Object.hash(
    temperature,
    seed,
    maxTokens,
    contextSize,
    repeatLastN,
    repeatPenalty,
    tailFreeSampling,
    topK,
    topP,
    minP,
    mirostat,
    mirostatEta,
    mirostatTau,
  );

  static int? _readInt(Map<String, Object?> json, String key) {
    final value = json[key];
    if (value == null) return null;
    if (value is int) return value;
    if (value is num && value.isFinite && value == value.roundToDouble()) {
      return value.toInt();
    }
    throw FormatException('$key must be an integer');
  }

  static double? _readDouble(Map<String, Object?> json, String key) {
    final value = json[key];
    if (value == null) return null;
    if (value is num && value.isFinite) return value.toDouble();
    throw FormatException('$key must be a finite number');
  }

  static void _checkNonNegativeInt(String name, int? value) {
    if (value != null && value < 0) {
      throw ArgumentError.value(value, name, 'must be nonnegative');
    }
  }

  static void _checkNonNegativeFinite(String name, double? value) {
    if (value != null && (!value.isFinite || value < 0)) {
      throw ArgumentError.value(
        value,
        name,
        'must be finite and nonnegative',
      );
    }
  }

  static void _checkProbability(String name, double? value) {
    if (value != null && (!value.isFinite || value < 0 || value > 1)) {
      throw ArgumentError.value(value, name, 'must be between 0 and 1');
    }
  }

  static const Object _notProvided = Object();
}
