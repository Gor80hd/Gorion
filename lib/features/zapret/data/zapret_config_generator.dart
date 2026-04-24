import 'dart:io';

import 'package:gorion_clean/features/zapret/model/zapret_models.dart';
import 'package:gorion_clean/features/zapret/model/zapret_settings.dart';
import 'package:path/path.dart' as p;

class ZapretConfigGenerator {
  const ZapretConfigGenerator();

  List<ZapretConfigOption> listAvailableProfiles(String installDirectory) {
    final normalizedRoot = installDirectory.trim();
    if (normalizedRoot.isEmpty) {
      return const [];
    }

    final root = Directory(normalizedRoot);
    if (!root.existsSync()) {
      return const [];
    }

    final profileOptions = <String, ZapretConfigOption>{};

    void collectProfiles(Directory directory) {
      if (!directory.existsSync()) {
        return;
      }

      for (final file
          in directory.listSync(followLinks: false).whereType<File>()) {
        final fileName = p.basename(file.path);
        if (!_isProfileConfig(fileName)) {
          continue;
        }

        final option = ZapretConfigOption(fileName: fileName, path: file.path);
        profileOptions[_profileLookupKey(fileName)] = option;
      }
    }

    collectProfiles(Directory(p.join(normalizedRoot, 'profiles')));
    collectProfiles(root);

    final profiles = profileOptions.values.toList()
      ..sort(
        (left, right) =>
            _naturalSortKey(left.label).compareTo(_naturalSortKey(right.label)),
      );

    return List.unmodifiable(profiles);
  }

  ZapretLaunchConfiguration build(ZapretSettings settings) {
    final installDirectory = settings.normalizedInstallDirectory;
    if (installDirectory.isEmpty) {
      throw const FormatException('Сначала укажите каталог установки zapret.');
    }

    ensureCompanionFiles(installDirectory);
    final profiles = listAvailableProfiles(installDirectory);
    if (profiles.isEmpty) {
      throw const FormatException(
        'В выбранном каталоге не найдены конфиги zapret (*.conf или legacy *.bat).',
      );
    }

    final selectedProfile = _resolveSelectedProfile(
      profiles,
      settings.effectiveConfigFileName,
    );
    final rawCommand = _readProfileCommand(selectedProfile.path);
    final usesLegacyBatchLayout =
        p.extension(selectedProfile.path).toLowerCase() == '.bat';
    final replacements = _buildVariableMap(
      installDirectory: installDirectory,
      gameFilterMode: settings.gameFilterMode,
      useLegacyBatchLayout: usesLegacyBatchLayout,
    );
    final expandedCommand = _expandVariables(rawCommand, replacements);
    final parsedCommand = _parseProfileCommand(
      expandedCommand: expandedCommand,
      installDirectory: installDirectory,
      profileName: selectedProfile.fileName,
      ipSetFilterMode: settings.ipSetFilterMode,
    );
    final requiredFiles = <String>{
      ..._collectRequiredFiles(
        rawCommand: rawCommand,
        replacements: replacements,
        parsedArguments: parsedCommand.arguments,
      ),
      parsedCommand.executablePath,
    }.toList()..sort();

    final preview = [
      'Конфиг: ${selectedProfile.label}',
      'Game Filter: ${settings.gameFilterMode.label}',
      'Каталог установки: $installDirectory',
      'Исполняемый файл: ${parsedCommand.executablePath}',
      '',
      ...parsedCommand.arguments,
    ].join('\n');

    return ZapretLaunchConfiguration(
      executablePath: parsedCommand.executablePath,
      workingDirectory: p.dirname(parsedCommand.executablePath),
      arguments: parsedCommand.arguments,
      requiredFiles: requiredFiles,
      preview: preview,
      summary: selectedProfile.label,
    );
  }

  void ensureCompanionFiles(String installDirectory) {
    final normalizedRoot = installDirectory.trim();
    if (normalizedRoot.isEmpty) {
      return;
    }

    for (final directory in <String>[
      p.join(normalizedRoot, 'lists'),
      p.join(normalizedRoot, 'files'),
    ]) {
      _ensureCompanionFile(
        p.join(directory, 'ipset-all.txt'),
        '0.0.0.0/0\n::/0\n',
      );
      _ensureCompanionFile(
        p.join(directory, 'ipset-exclude-user.txt'),
        '203.0.113.113/32\n',
      );
      _ensureCompanionFile(p.join(directory, 'list-general-user.txt'), '');
      _ensureCompanionFile(
        p.join(directory, 'list-exclude-user.txt'),
        'domain.example.abc\n',
      );
    }
  }

  String? resolveExecutablePath(String installDirectory) {
    const candidates = <String>[
      'binaries/windows-x86_64/winws2.exe',
      'binaries/windows-x86/winws2.exe',
      'nfq2/winws2.exe',
      'winws2.exe',
      'bin/winws.exe',
      'winws.exe',
    ];

    for (final candidate in candidates) {
      final fullPath = p.joinAll([installDirectory, ...candidate.split('/')]);
      if (File(fullPath).existsSync()) {
        return fullPath;
      }
    }

    return null;
  }

  String resolveSelectedConfigFileName(
    String installDirectory,
    String preferredFileName,
  ) {
    final profiles = listAvailableProfiles(installDirectory);
    if (profiles.isEmpty) {
      return preferredFileName.trim().isEmpty
          ? 'general.conf'
          : preferredFileName;
    }

    return _resolveSelectedProfile(profiles, preferredFileName).fileName;
  }

  ZapretConfigOption _resolveSelectedProfile(
    List<ZapretConfigOption> profiles,
    String preferredFileName,
  ) {
    final normalizedPreferred = _profileLookupKey(preferredFileName);
    for (final profile in profiles) {
      if (_profileLookupKey(profile.fileName) == normalizedPreferred) {
        return profile;
      }
    }

    return profiles.first;
  }

  bool _isProfileConfig(String fileName) {
    final normalized = fileName.trim().toLowerCase();
    return (normalized.endsWith('.conf') || normalized.endsWith('.bat')) &&
        !normalized.startsWith('service');
  }

  String _naturalSortKey(String value) {
    final lower = value.toLowerCase();
    return lower.replaceAllMapped(
      RegExp(r'\d+'),
      (match) => match.group(0)!.padLeft(8, '0'),
    );
  }

  String _profileLookupKey(String value) {
    return formatZapretConfigLabel(value).trim().toLowerCase();
  }

  String _readProfileCommand(String configPath) {
    final extension = p.extension(configPath).toLowerCase();
    return switch (extension) {
      '.bat' => _extractLaunchCommand(configPath),
      _ => _extractConfigCommand(configPath),
    };
  }

  String _extractConfigCommand(String configPath) {
    final lines = File(configPath).readAsLinesSync();
    final buffer = StringBuffer();

    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#') || line.startsWith(';')) {
        continue;
      }

      if (buffer.isNotEmpty) {
        buffer.write(' ');
      }
      buffer.write(line);
    }

    final command = buffer.toString().trim();
    if (command.isEmpty) {
      throw FormatException(
        'В конфиге ${p.basename(configPath)} не найдены параметры запуска winws.',
      );
    }

    return command;
  }

  String _extractLaunchCommand(String configPath) {
    final lines = File(configPath).readAsLinesSync();
    final startIndex = lines.indexWhere(
      (line) =>
          line.trimLeft().toLowerCase().startsWith('start ') &&
          line.toLowerCase().contains('winws.exe'),
    );

    if (startIndex < 0) {
      throw FormatException(
        'В конфиге ${p.basename(configPath)} не найдена команда запуска winws.exe.',
      );
    }

    final buffer = StringBuffer();
    for (var index = startIndex; index < lines.length; index += 1) {
      final line = lines[index].trim();
      if (line.isEmpty) {
        continue;
      }

      final hasContinuation = line.endsWith('^');
      final cleanedLine = hasContinuation
          ? line.substring(0, line.length - 1).trimRight()
          : line;
      if (buffer.isNotEmpty) {
        buffer.write(' ');
      }
      buffer.write(cleanedLine);

      if (!hasContinuation) {
        break;
      }
    }

    return buffer.toString();
  }

  Map<String, String> _buildVariableMap({
    required String installDirectory,
    required ZapretGameFilterMode gameFilterMode,
    required bool useLegacyBatchLayout,
  }) {
    final root = _withTrailingSeparator(installDirectory);
    final bin = _withTrailingSeparator(
      _resolveBinResourceDirectory(
        installDirectory,
        useLegacyBatchLayout: useLegacyBatchLayout,
      ),
    );
    final lists = _withTrailingSeparator(
      _resolveListResourceDirectory(
        installDirectory,
        useLegacyBatchLayout: useLegacyBatchLayout,
      ),
    );

    return <String, String>{
      '%~dp0': root,
      '%BIN%': bin,
      '%LISTS%': lists,
      '%GameFilter%': gameFilterMode.enabled ? '1024-65535' : '12',
      '%GameFilterTCP%': gameFilterMode.tcpValue,
      '%GameFilterUDP%': gameFilterMode.udpValue,
    };
  }

  String _expandVariables(String rawCommand, Map<String, String> replacements) {
    var expanded = rawCommand;
    for (final entry in replacements.entries) {
      expanded = expanded.replaceAll(entry.key, entry.value);
    }
    return expanded;
  }

  _ParsedLaunchCommand _parseLaunchCommand(String expandedCommand) {
    final primaryMatch = RegExp(
      r'^start\s+"[^"]*"\s+/min\s+"([^"]+)"\s+(.*)$',
      caseSensitive: false,
    ).firstMatch(expandedCommand);
    final fallbackMatch = RegExp(
      r'^start\s+"([^"]+)"\s+"([^"]+)"\s+(.*)$',
      caseSensitive: false,
    ).firstMatch(expandedCommand);

    final executablePath =
        primaryMatch?.group(1) ?? fallbackMatch?.group(2) ?? '';
    final argumentsSource =
        primaryMatch?.group(2) ?? fallbackMatch?.group(3) ?? '';

    if (executablePath.isEmpty || argumentsSource.isEmpty) {
      throw const FormatException(
        'Не удалось разобрать команду запуска winws.exe из выбранного конфига.',
      );
    }

    return _ParsedLaunchCommand(
      executablePath: executablePath,
      arguments: _tokenize(argumentsSource),
    );
  }

  _ParsedLaunchCommand _parseProfileCommand({
    required String expandedCommand,
    required String installDirectory,
    required String profileName,
    required ZapretIpSetFilterMode ipSetFilterMode,
  }) {
    final normalizedCommand = expandedCommand.trimLeft().toLowerCase();
    if (normalizedCommand.startsWith('start ')) {
      final parsedLaunch = _parseLaunchCommand(expandedCommand);
      final executablePath = resolveExecutablePath(installDirectory);
      if (executablePath == null || executablePath.trim().isEmpty) {
        throw FormatException(
          'В каталоге zapret не найден winws.exe/winws2.exe для конфига $profileName.',
        );
      }
      if (_shouldTranslateLegacyProfile(
        executablePath: executablePath,
        arguments: parsedLaunch.arguments,
      )) {
        return _ParsedLaunchCommand(
          executablePath: executablePath,
          arguments: _applyIpSetFilterMode(
            _translateLegacyArgumentsToWinws2(
              legacyArguments: parsedLaunch.arguments,
              installDirectory: installDirectory,
            ),
            mode: ipSetFilterMode,
          ),
        );
      }
      return _ParsedLaunchCommand(
        executablePath: executablePath,
        arguments: _applyIpSetFilterMode(
          parsedLaunch.arguments,
          mode: ipSetFilterMode,
        ),
      );
    }

    final executablePath = resolveExecutablePath(installDirectory);
    if (executablePath == null || executablePath.trim().isEmpty) {
      throw FormatException(
        'В каталоге zapret не найден winws.exe/winws2.exe для конфига $profileName.',
      );
    }

    final rawArguments = _tokenize(expandedCommand);
    if (rawArguments.isEmpty) {
      throw FormatException(
        'В конфиге $profileName не найдены параметры запуска winws.',
      );
    }

    final arguments =
        _shouldTranslateLegacyProfile(
          executablePath: executablePath,
          arguments: rawArguments,
        )
        ? _translateLegacyArgumentsToWinws2(
            legacyArguments: rawArguments,
            installDirectory: installDirectory,
          )
        : rawArguments;

    return _ParsedLaunchCommand(
      executablePath: executablePath,
      arguments: _applyIpSetFilterMode(arguments, mode: ipSetFilterMode),
    );
  }

  List<String> _applyIpSetFilterMode(
    List<String> arguments, {
    required ZapretIpSetFilterMode mode,
  }) {
    if (mode != ZapretIpSetFilterMode.none) {
      return arguments;
    }

    return List.unmodifiable([
      for (final argument in arguments)
        if (_isIpSetAllArgument(argument))
          '--ipset-ip=203.0.113.113/32'
        else
          argument,
    ]);
  }

  bool _isIpSetAllArgument(String argument) {
    final normalized = argument.trim().replaceAll('"', '').toLowerCase();
    if (!normalized.startsWith('--ipset=')) {
      return false;
    }

    return normalized.endsWith('ipset-all.txt');
  }

  List<String> _collectRequiredFiles({
    required String rawCommand,
    required Map<String, String> replacements,
    List<String> parsedArguments = const [],
  }) {
    final requiredFiles = <String>{};
    for (final match in RegExp(
      r'%(BIN|LISTS)%([^"\s]+)',
      caseSensitive: false,
    ).allMatches(rawCommand)) {
      final scope = match.group(1)?.toUpperCase();
      final relativePath = match.group(2);
      if (scope == null || relativePath == null || relativePath.isEmpty) {
        continue;
      }

      final baseDirectory = replacements['%$scope%'];
      if (baseDirectory == null || baseDirectory.isEmpty) {
        continue;
      }
      requiredFiles.add(
        p.joinAll([baseDirectory, ...relativePath.split(r'\')]),
      );
    }

    requiredFiles.addAll(_collectRequiredFilesFromArguments(parsedArguments));

    return requiredFiles.toList()..sort();
  }

  List<String> _collectRequiredFilesFromArguments(List<String> arguments) {
    final requiredFiles = <String>{};

    for (final argument in arguments) {
      final separatorIndex = argument.indexOf('=');
      if (separatorIndex <= 0 || separatorIndex >= argument.length - 1) {
        continue;
      }

      var value = argument.substring(separatorIndex + 1).trim();
      if (value.isEmpty || value.startsWith('0x')) {
        continue;
      }

      if (value.startsWith('@')) {
        value = value.substring(1);
      }

      if (value.contains('@')) {
        value = value.substring(value.indexOf('@') + 1);
      }

      final normalized = value.replaceAll('"', '');
      final looksLikePath =
          normalized.contains(r'\') ||
          normalized.contains('/') ||
          normalized.contains(':');
      if (!looksLikePath) {
        continue;
      }

      final extension = p.extension(normalized).toLowerCase();
      if (extension.isEmpty) {
        continue;
      }

      requiredFiles.add(p.normalize(normalized));
    }

    return requiredFiles.toList()..sort();
  }

  String _resolveBinResourceDirectory(
    String installDirectory, {
    required bool useLegacyBatchLayout,
  }) {
    if (useLegacyBatchLayout) {
      return p.join(installDirectory, 'bin');
    }

    final canonical = Directory(p.join(installDirectory, 'files', 'fake'));
    if (canonical.existsSync()) {
      return canonical.path;
    }

    return p.join(installDirectory, 'bin');
  }

  String _resolveListResourceDirectory(
    String installDirectory, {
    required bool useLegacyBatchLayout,
  }) {
    if (useLegacyBatchLayout) {
      return p.join(installDirectory, 'lists');
    }

    final canonical = Directory(p.join(installDirectory, 'files'));
    if (canonical.existsSync()) {
      return canonical.path;
    }

    return p.join(installDirectory, 'lists');
  }

  List<String> _tokenize(String input) {
    final tokens = <String>[];
    final current = StringBuffer();
    var inQuotes = false;

    for (var index = 0; index < input.length; index += 1) {
      final character = input[index];
      if (character == '"') {
        inQuotes = !inQuotes;
        continue;
      }

      final isWhitespace =
          character == ' ' ||
          character == '\t' ||
          character == '\r' ||
          character == '\n';
      if (!inQuotes && isWhitespace) {
        if (current.isNotEmpty) {
          tokens.add(current.toString());
          current.clear();
        }
        continue;
      }

      current.write(character);
    }

    if (current.isNotEmpty) {
      tokens.add(current.toString());
    }

    return List.unmodifiable(tokens);
  }

  bool _shouldTranslateLegacyProfile({
    required String executablePath,
    required List<String> arguments,
  }) {
    if (!_isWinws2Executable(executablePath)) {
      return false;
    }

    return arguments.any(
      (argument) =>
          argument.startsWith('--dpi-desync') ||
          argument.startsWith('--wf-tcp=') ||
          argument.startsWith('--wf-udp='),
    );
  }

  bool _isWinws2Executable(String executablePath) {
    return p.basename(executablePath).toLowerCase() == 'winws2.exe';
  }

  List<String> _translateLegacyArgumentsToWinws2({
    required List<String> legacyArguments,
    required String installDirectory,
  }) {
    final layout = _splitLegacyArguments(legacyArguments);
    final blobRegistry = _BlobRegistry(installDirectory: installDirectory);

    final translated = <String>[
      ..._translateWindivertGlobals(layout.global, layout.blocks),
      '--lua-init=@${p.join(installDirectory, 'lua', 'zapret-lib.lua')}',
      '--lua-init=@${p.join(installDirectory, 'lua', 'zapret-antidpi.lua')}',
    ];

    final translatedBlocks = <List<String>>[];
    for (final block in layout.blocks) {
      final translatedBlock = _translateLegacyBlock(
        block: block,
        blobRegistry: blobRegistry,
      );
      if (translatedBlock.isNotEmpty) {
        translatedBlocks.add(translatedBlock);
      }
    }

    translated.addAll(blobRegistry.arguments);
    for (var index = 0; index < translatedBlocks.length; index += 1) {
      if (index > 0) {
        translated.add('--new');
      }
      translated.addAll(translatedBlocks[index]);
    }

    return List.unmodifiable(translated);
  }

  _LegacyProfileLayout _splitLegacyArguments(List<String> arguments) {
    final globalTokens = <String>[];
    final blocks = <_LegacyOptionBag>[];
    final currentBlockTokens = <String>[];

    var index = 0;
    while (index < arguments.length && _isLegacyGlobalToken(arguments[index])) {
      globalTokens.add(arguments[index]);
      index += 1;
    }

    for (; index < arguments.length; index += 1) {
      final argument = arguments[index];
      if (argument == '--new' || argument.startsWith('--new=')) {
        if (currentBlockTokens.isNotEmpty) {
          blocks.add(_LegacyOptionBag(currentBlockTokens));
          currentBlockTokens.clear();
        }
        continue;
      }
      currentBlockTokens.add(argument);
    }

    if (currentBlockTokens.isNotEmpty) {
      blocks.add(_LegacyOptionBag(currentBlockTokens));
    }

    return _LegacyProfileLayout(
      global: _LegacyOptionBag(globalTokens),
      blocks: blocks,
    );
  }

  bool _isLegacyGlobalToken(String argument) {
    return argument.startsWith('--wf-');
  }

  List<String> _translateWindivertGlobals(
    _LegacyOptionBag global,
    List<_LegacyOptionBag> blocks,
  ) {
    final translated = <String>[];

    final tcpPorts = _normalizeCsvValues(global.firstValue('wf-tcp'));
    if (tcpPorts.isNotEmpty) {
      translated.add('--wf-tcp-out=${tcpPorts.join(',')}');
      if (blocks.any(
        (block) =>
            block.firstValue('filter-tcp') != null &&
            block.firstValue('dpi-desync-cutoff')?.startsWith('n') == true,
      )) {
        translated.add('--wf-tcp-empty=1');
      }
    }

    final udpPorts = _normalizeCsvValues(global.firstValue('wf-udp'));
    if (udpPorts.isNotEmpty) {
      translated.add('--wf-udp-out=${udpPorts.join(',')}');
    }

    return translated;
  }

  List<String> _translateLegacyBlock({
    required _LegacyOptionBag block,
    required _BlobRegistry blobRegistry,
  }) {
    final translated = <String>[];
    final strategies = _normalizeCsvValues(block.firstValue('dpi-desync'));
    if (strategies.isEmpty) {
      return const [];
    }

    final tcpPorts = _normalizeCsvValues(block.firstValue('filter-tcp'));
    final udpPorts = _normalizeCsvValues(block.firstValue('filter-udp'));
    final anyProtocol = block.firstValue('dpi-desync-any-protocol') == '1';
    final isTcp = tcpPorts.isNotEmpty;
    final isUdp = udpPorts.isNotEmpty;

    if (!isTcp && !isUdp) {
      return const [];
    }

    if (isTcp) {
      translated.add('--filter-tcp=${tcpPorts.join(',')}');
    }
    if (isUdp) {
      translated.add('--filter-udp=${udpPorts.join(',')}');
    }

    final translatedFilterL7 = _resolveTranslatedFilterL7(
      block: block,
      tcpPorts: tcpPorts,
      udpPorts: udpPorts,
      anyProtocol: anyProtocol,
    );
    if (translatedFilterL7 != null && translatedFilterL7.isNotEmpty) {
      translated.add('--filter-l7=$translatedFilterL7');
    }

    for (final key in const <String>[
      'hostlist',
      'hostlist-domains',
      'hostlist-exclude',
      'hostlist-exclude-domains',
      'ipset',
      'ipset-ip',
      'ipset-exclude',
      'ipset-exclude-ip',
    ]) {
      for (final value in block.values(key)) {
        translated.add('--$key=$value');
      }
    }

    final cutoff = block.firstValue('dpi-desync-cutoff');
    final outRange = _translateCutoffToOutRange(cutoff);
    if (outRange != null) {
      translated.add('--out-range=$outRange');
    }

    if (strategies.contains('fake')) {
      translated.addAll(
        _buildLegacyFakeCalls(
          block: block,
          blobRegistry: blobRegistry,
          isTcp: isTcp,
          isUdp: isUdp,
          tcpPorts: tcpPorts,
          anyProtocol: anyProtocol,
        ),
      );
    }

    final followUpStrategies = strategies.where(
      (strategy) => strategy != 'fake',
    );
    for (final strategy in followUpStrategies) {
      final translatedStrategy = _translateLegacyStrategy(
        legacyStrategy: strategy,
        block: block,
        isTcp: isTcp,
        isUdp: isUdp,
        tcpPorts: tcpPorts,
        anyProtocol: anyProtocol,
        blobRegistry: blobRegistry,
      );
      if (translatedStrategy == null) {
        continue;
      }

      translated.add('--payload=${translatedStrategy.payloadFilter}');
      translated.add('--lua-desync=${translatedStrategy.desync}');
    }

    return translated;
  }

  String? _resolveTranslatedFilterL7({
    required _LegacyOptionBag block,
    required List<String> tcpPorts,
    required List<String> udpPorts,
    required bool anyProtocol,
  }) {
    final legacyFilterL7 = block.firstValue('filter-l7');
    if (legacyFilterL7 != null && legacyFilterL7.isNotEmpty) {
      return legacyFilterL7;
    }

    if (anyProtocol) {
      return null;
    }

    if (udpPorts.isNotEmpty &&
        block.firstValue('dpi-desync-fake-quic') != null) {
      return 'quic';
    }

    if (tcpPorts.isEmpty) {
      return null;
    }

    final hasHttp = tcpPorts.contains('80');
    final hasTls = tcpPorts.any((port) => port != '80');
    if (hasHttp && hasTls) {
      return 'http,tls';
    }
    if (hasHttp) {
      return 'http';
    }
    if (hasTls) {
      return 'tls';
    }
    return null;
  }

  String? _translateCutoffToOutRange(String? legacyCutoff) {
    final normalized = legacyCutoff?.trim();
    if (normalized == null || normalized.isEmpty) {
      return null;
    }
    return '-$normalized';
  }

  List<String> _buildLegacyFakeCalls({
    required _LegacyOptionBag block,
    required _BlobRegistry blobRegistry,
    required bool isTcp,
    required bool isUdp,
    required List<String> tcpPorts,
    required bool anyProtocol,
  }) {
    final calls = <String>[];
    final commonArgs = _buildLegacyCommonDesyncArgs(block);

    void addFakeCall(
      String payloadFilter,
      String blobValue, {
      bool useTlsMod = false,
    }) {
      final desyncArgs = <String>[
        'fake',
        'blob=${blobRegistry.register(blobValue)}',
        ...commonArgs,
      ];

      final tlsMod = block.firstValue('dpi-desync-fake-tls-mod');
      if (useTlsMod && tlsMod != null && tlsMod.toLowerCase() != 'none') {
        desyncArgs.add('tls_mod=$tlsMod');
      }

      calls.add('--payload=$payloadFilter');
      calls.add('--lua-desync=${desyncArgs.join(':')}');
    }

    if (isUdp) {
      final fakeQuic = block.firstValue('dpi-desync-fake-quic');
      if (fakeQuic != null) {
        addFakeCall('quic_initial', fakeQuic);
        return calls;
      }

      final fakeUnknownUdp = block.firstValue('dpi-desync-fake-unknown-udp');
      if (fakeUnknownUdp != null) {
        addFakeCall('known,unknown', fakeUnknownUdp);
        return calls;
      }

      addFakeCall(
        'stun,discord_ip_discovery',
        '0x00000000000000000000000000000000',
      );
      return calls;
    }

    final fakeTlsValues = block.values('dpi-desync-fake-tls');
    final fakeHttpValues = block.values('dpi-desync-fake-http');

    final hasHttp = tcpPorts.contains('80');
    final hasTls = tcpPorts.any((port) => port != '80');

    if (hasTls) {
      for (final fakeTls in fakeTlsValues) {
        addFakeCall('tls_client_hello', fakeTls, useTlsMod: true);
      }
    }

    if (hasHttp) {
      for (final fakeHttp in fakeHttpValues) {
        addFakeCall('http_req', fakeHttp);
      }
    }

    if (anyProtocol) {
      addFakeCall(
        'unknown',
        p.join(blobRegistry.fakeDirectory.path, 'zero_256.bin'),
      );
    }

    return calls;
  }

  _TranslatedLegacyStrategy? _translateLegacyStrategy({
    required String legacyStrategy,
    required _LegacyOptionBag block,
    required bool isTcp,
    required bool isUdp,
    required List<String> tcpPorts,
    required bool anyProtocol,
    required _BlobRegistry blobRegistry,
  }) {
    final payloadFilter = _resolveFollowUpPayloadFilter(
      isTcp: isTcp,
      isUdp: isUdp,
      tcpPorts: tcpPorts,
      anyProtocol: anyProtocol,
      block: block,
    );
    if (payloadFilter == null) {
      return null;
    }

    final commonArgs = _buildLegacyCommonDesyncArgs(block);
    final desyncArgs = <String>[
      switch (legacyStrategy) {
        'split2' => 'multisplit',
        'multidisorder' => 'multidisorder_legacy',
        _ => legacyStrategy,
      },
      ...commonArgs,
    ];

    final splitPos = block.firstValue('dpi-desync-split-pos');
    if (splitPos != null &&
        splitPos.isNotEmpty &&
        legacyStrategy != 'fakedsplit') {
      desyncArgs.add('pos=$splitPos');
    }

    final splitSeqovl = block.firstValue('dpi-desync-split-seqovl');
    if (splitSeqovl != null && splitSeqovl.isNotEmpty) {
      desyncArgs.add('seqovl=$splitSeqovl');
    }

    final seqovlPattern = block.firstValue('dpi-desync-split-seqovl-pattern');
    if (seqovlPattern != null && seqovlPattern.isNotEmpty) {
      desyncArgs.add('seqovl_pattern=${blobRegistry.register(seqovlPattern)}');
    }

    final fakedsplitPattern = block.firstValue('dpi-desync-fakedsplit-pattern');
    if (fakedsplitPattern != null && fakedsplitPattern.isNotEmpty) {
      desyncArgs.add('pattern=${blobRegistry.register(fakedsplitPattern)}');
    }

    return _TranslatedLegacyStrategy(
      payloadFilter: payloadFilter,
      desync: desyncArgs.join(':'),
    );
  }

  String? _resolveFollowUpPayloadFilter({
    required bool isTcp,
    required bool isUdp,
    required List<String> tcpPorts,
    required bool anyProtocol,
    required _LegacyOptionBag block,
  }) {
    if (anyProtocol) {
      return 'known,unknown';
    }

    if (isUdp) {
      if (block.firstValue('dpi-desync-fake-quic') != null) {
        return 'quic_initial';
      }

      if (block.firstValue('filter-l7')?.contains('discord') == true ||
          block.firstValue('filter-l7')?.contains('stun') == true) {
        return 'stun,discord_ip_discovery';
      }

      return 'known,unknown';
    }

    final hasHttp = tcpPorts.contains('80');
    final hasTls = tcpPorts.any((port) => port != '80');
    if (hasHttp && hasTls) {
      return 'http_req,tls_client_hello';
    }
    if (hasHttp) {
      return 'http_req';
    }
    if (hasTls) {
      return 'tls_client_hello';
    }

    return null;
  }

  List<String> _buildLegacyCommonDesyncArgs(_LegacyOptionBag block) {
    final arguments = <String>[];

    final repeats = block.firstValue('dpi-desync-repeats');
    if (repeats != null && repeats.isNotEmpty) {
      arguments.add('repeats=$repeats');
    }

    final ipId = block.firstValue('ip-id');
    if (ipId != null && ipId.isNotEmpty) {
      arguments.add('ip_id=$ipId');
    }

    arguments.addAll(
      _translateLegacyFooling(block.firstValue('dpi-desync-fooling')),
    );

    final autoTtl = block.firstValue('dpi-desync-autottl');
    if (autoTtl != null && autoTtl.isNotEmpty) {
      final normalizedDelta = autoTtl.startsWith('-') || autoTtl.startsWith('+')
          ? autoTtl
          : '-$autoTtl';
      arguments.add('ip_autottl=$normalizedDelta,3-20');
      arguments.add('ip6_autottl=$normalizedDelta,3-20');
    }

    return arguments;
  }

  List<String> _translateLegacyFooling(String? fooling) {
    final translated = <String>[];

    for (final item in _normalizeCsvValues(fooling)) {
      switch (item) {
        case 'ts':
          translated.add('tcp_ts=-600000');
          break;
        case 'badseq':
          translated.add('tcp_seq=-10000');
          translated.add('tcp_ack=-66000');
          break;
        case 'md5sig':
          translated.add('tcp_md5');
          break;
        default:
          break;
      }
    }

    return translated;
  }

  List<String> _normalizeCsvValues(String? value) {
    if (value == null || value.trim().isEmpty) {
      return const [];
    }

    final values = value
        .split(',')
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty && item != '12')
        .toList();

    return List.unmodifiable(values);
  }

  String _withTrailingSeparator(String value) {
    final normalized = p.normalize(value);
    return normalized.endsWith(p.separator)
        ? normalized
        : '$normalized${p.separator}';
  }

  void _ensureCompanionFile(String filePath, String contents) {
    final file = File(filePath);
    if (file.existsSync()) {
      return;
    }

    file.parent.createSync(recursive: true);
    file.writeAsStringSync(contents, flush: true);
  }
}

class _ParsedLaunchCommand {
  const _ParsedLaunchCommand({
    required this.executablePath,
    required this.arguments,
  });

  final String executablePath;
  final List<String> arguments;
}

class _LegacyProfileLayout {
  const _LegacyProfileLayout({required this.global, required this.blocks});

  final _LegacyOptionBag global;
  final List<_LegacyOptionBag> blocks;
}

class _LegacyOptionBag {
  _LegacyOptionBag(Iterable<String> tokens) {
    for (final token in tokens) {
      if (!token.startsWith('--')) {
        continue;
      }

      final normalized = token.substring(2);
      final separatorIndex = normalized.indexOf('=');
      if (separatorIndex < 0) {
        _values.putIfAbsent(normalized, () => <String>[]);
        continue;
      }

      final key = normalized.substring(0, separatorIndex);
      final value = normalized.substring(separatorIndex + 1);
      _values.putIfAbsent(key, () => <String>[]).add(value);
    }
  }

  final Map<String, List<String>> _values = <String, List<String>>{};

  String? firstValue(String key) {
    final values = _values[key];
    if (values == null || values.isEmpty) {
      return null;
    }
    return values.first;
  }

  List<String> values(String key) {
    final values = _values[key];
    if (values == null) {
      return const [];
    }
    return List.unmodifiable(values);
  }
}

class _TranslatedLegacyStrategy {
  const _TranslatedLegacyStrategy({
    required this.payloadFilter,
    required this.desync,
  });

  final String payloadFilter;
  final String desync;
}

class _BlobRegistry {
  _BlobRegistry({required String installDirectory})
    : fakeDirectory = Directory(p.join(installDirectory, 'files', 'fake'));

  final Directory fakeDirectory;
  final Map<String, String> _sourceToName = <String, String>{};
  final Map<String, String> _nameToArgument = <String, String>{};

  String register(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty || normalized.startsWith('0x')) {
      return normalized;
    }

    final existing = _sourceToName[normalized];
    if (existing != null) {
      return existing;
    }

    final stem = p.basenameWithoutExtension(normalized);
    var candidate = stem
        .replaceAll(RegExp(r'[^A-Za-z0-9_]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    if (candidate.isEmpty) {
      candidate = 'blob';
    }

    var uniqueName = candidate;
    var suffix = 2;
    while (_nameToArgument.containsKey(uniqueName)) {
      uniqueName = '${candidate}_$suffix';
      suffix += 1;
    }

    _sourceToName[normalized] = uniqueName;
    _nameToArgument[uniqueName] = '--blob=$uniqueName:@$normalized';
    return uniqueName;
  }

  List<String> get arguments => _nameToArgument.values.toList(growable: false);
}
