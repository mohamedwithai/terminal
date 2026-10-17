import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ssh_app/models/auth_type.dart';
import 'package:ssh_app/models/host_validator.dart';
import 'package:ssh_app/models/server_config.dart';
import 'package:ssh_app/models/server_credentials.dart';
import 'package:ssh_app/providers/vault_providers.dart';
import 'package:ssh_app/services/vault_exception.dart';

/// Add or edit a server. Secrets are loaded from the vault, not from the route.
class ServerFormScreen extends ConsumerStatefulWidget {
  const ServerFormScreen({super.key, this.server});

  /// Null when the user is adding a server.
  final ServerConfig? server;

  @override
  ConsumerState<ServerFormScreen> createState() => _ServerFormScreenState();
}

class _ServerFormScreenState extends ConsumerState<ServerFormScreen> {
  final _label = TextEditingController();
  final _host = TextEditingController();
  final _port = TextEditingController(text: '22');
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _privateKey = TextEditingController();
  final _passphrase = TextEditingController();

  AuthType _authType = AuthType.password;

  /// The saved key this host uses, or null to paste one for this host only.
  String? _keyId;
  var _hidePassword = true;
  var _hideKey = true;
  var _hidePassphrase = true;
  var _loadingSecrets = false;
  var _saving = false;
  Map<String, String> _errors = {};

  @override
  void initState() {
    super.initState();
    final server = widget.server;
    if (server == null) {
      return;
    }
    _label.text = server.label;
    _host.text = server.host;
    _port.text = '${server.port}';
    _username.text = server.username;
    _authType = server.authType;
    _keyId = server.keyId;
    _loadingSecrets = true;
    _loadSecrets(server.id);
  }

  Future<void> _loadSecrets(String id) async {
    try {
      final credentials = await ref
          .read(vaultServiceProvider)
          .readOwnCredentials(id);
      if (!mounted) {
        return;
      }
      _password.text = credentials?.password ?? '';
      _privateKey.text = credentials?.privateKey ?? '';
      _passphrase.text = credentials?.passphrase ?? '';
    } on VaultException catch (error) {
      if (!mounted) {
        return;
      }
      _showMessage(error.message);
    } finally {
      if (mounted) {
        setState(() => _loadingSecrets = false);
      }
    }
  }

  @override
  void dispose() {
    _label.dispose();
    _host.dispose();
    _port.dispose();
    _username.dispose();
    _password.dispose();
    _privateKey.dispose();
    _passphrase.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.server != null;
    final canSave = ref.watch(secureStorageAvailableProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(editing ? 'Edit server' : 'Add server'),
        actions: [
          TextButton(
            onPressed: !canSave || _saving || _loadingSecrets ? null : _save,
            child: _saving
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Save'),
          ),
        ],
      ),
      body: _loadingSecrets
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              children: [
                TextField(
                  controller: _label,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: 'Name',
                    errorText: _errors['label'],
                  ),
                  onChanged: (_) => _clearError('label'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _host,
                  textInputAction: TextInputAction.next,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: 'Host',
                    errorText: _errors['host'],
                  ),
                  onChanged: _onHostChanged,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _port,
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: 'Port',
                    errorText: _errors['port'],
                  ),
                  onChanged: (_) => _clearError('port'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _username,
                  textInputAction: TextInputAction.next,
                  autocorrect: false,
                  autofillHints: const [AutofillHints.username],
                  decoration: InputDecoration(
                    labelText: 'Username',
                    errorText: _errors['username'],
                  ),
                  onChanged: (_) => _clearError('username'),
                ),
                const SizedBox(height: 20),
                Text(
                  'Authentication',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                SegmentedButton<AuthType>(
                  segments: const [
                    ButtonSegment(
                      value: AuthType.password,
                      label: Text('Password'),
                      icon: Icon(Icons.password),
                    ),
                    ButtonSegment(
                      value: AuthType.privateKey,
                      label: Text('Private key'),
                      icon: Icon(Icons.key),
                    ),
                  ],
                  selected: {_authType},
                  onSelectionChanged: (selection) {
                    setState(() => _authType = selection.first);
                  },
                ),
                const SizedBox(height: 16),
                if (_authType == AuthType.password)
                  TextField(
                    controller: _password,
                    obscureText: _hidePassword,
                    autocorrect: false,
                    enableSuggestions: false,
                    autofillHints: const [AutofillHints.password],
                    decoration: InputDecoration(
                      labelText: 'Password',
                      errorText: _errors['password'],
                      suffixIcon: IconButton(
                        tooltip: _hidePassword
                            ? 'Show password'
                            : 'Hide password',
                        onPressed: () =>
                            setState(() => _hidePassword = !_hidePassword),
                        icon: Icon(
                          _hidePassword
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                      ),
                    ),
                    onChanged: (_) => _clearError('password'),
                  )
                else ...[
                  _KeyPicker(
                    keyId: _keyId,
                    error: _errors['keyId'],
                    onChanged: (id) => setState(() {
                      _keyId = id;
                      _errors.remove('keyId');
                    }),
                  ),
                  const SizedBox(height: 16),
                  if (_keyId == null) ...[
                    TextField(
                      controller: _privateKey,
                      obscureText: _hideKey,
                      maxLines: _hideKey ? 1 : 8,
                      minLines: _hideKey ? 1 : 4,
                      autocorrect: false,
                      enableSuggestions: false,
                      style: const TextStyle(fontFamily: 'monospace'),
                      decoration: InputDecoration(
                        labelText: 'Private key',
                        alignLabelWithHint: true,
                        helperText: 'OpenSSH or PEM. RSA, Ed25519, and ECDSA.',
                        errorText: _errors['privateKey'],
                        suffixIcon: IconButton(
                          tooltip: _hideKey
                              ? 'Show private key'
                              : 'Hide private key',
                          onPressed: () => setState(() => _hideKey = !_hideKey),
                          icon: Icon(
                            _hideKey
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                          ),
                        ),
                      ),
                      onChanged: (_) => _clearError('privateKey'),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        onPressed: _pasteKey,
                        icon: const Icon(Icons.content_paste),
                        label: const Text('Paste key'),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _passphrase,
                      obscureText: _hidePassphrase,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: InputDecoration(
                        labelText: 'Key passphrase',
                        helperText:
                            'Leave empty when the key is not encrypted.',
                        errorText: _errors['passphrase'],
                        suffixIcon: IconButton(
                          tooltip: _hidePassphrase
                              ? 'Show passphrase'
                              : 'Hide passphrase',
                          onPressed: () => setState(
                            () => _hidePassphrase = !_hidePassphrase,
                          ),
                          icon: Icon(
                            _hidePassphrase
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                          ),
                        ),
                      ),
                      onChanged: (_) => _clearError('passphrase'),
                    ),
                  ],
                ],
              ],
            ),
    );
  }

  void _clearError(String field) {
    if (_errors.containsKey(field)) {
      setState(() => _errors.remove(field));
    }
  }

  void _onHostChanged(String value) {
    _clearError('host');
    final parsed = parseHostInput(value);
    if (parsed == null) {
      return;
    }
    if (parsed.username != null && parsed.username!.isNotEmpty) {
      _username.text = parsed.username!;
      _clearError('username');
    }
    if (parsed.port != null) {
      _port.text = '${parsed.port}';
      _clearError('port');
    }
    if (parsed.host != value) {
      _host.value = TextEditingValue(
        text: parsed.host,
        selection: TextSelection.collapsed(offset: parsed.host.length),
      );
    }
  }

  Future<void> _pasteKey() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (!mounted) {
      return;
    }
    if (text == null || text.isEmpty) {
      _showMessage('The clipboard is empty.');
      return;
    }
    setState(() {
      _privateKey.text = text;
      _errors.remove('privateKey');
      _hideKey = false;
    });
  }

  Future<void> _save() async {
    final errors = <String, String>{};
    final port = int.tryParse(_port.text.trim());
    if (port == null) {
      errors['port'] = 'Enter a port from 1 to 65535.';
    }
    final existing = widget.server;
    final draft =
        ServerConfig.create(
          id: existing?.id,
          label: _label.text,
          host: _host.text,
          port: port ?? 0,
          username: _username.text,
          authType: _authType,
          now: existing?.createdAt,
        ).copyWith(
          createdAt: existing?.createdAt,
          updatedAt: existing?.updatedAt,
          tags: existing?.tags,
          lastConnectedAt: existing?.lastConnectedAt,
          keyId: _authType == AuthType.privateKey ? _keyId : null,
          clearKeyId: _authType != AuthType.privateKey || _keyId == null,
        );
    errors.addAll(draft.fieldErrors);
    if (errors.isNotEmpty) {
      setState(() => _errors = errors);
      return;
    }

    final credentials = switch (_authType) {
      AuthType.password => ServerCredentials(password: _password.text),
      AuthType.privateKey when _keyId != null => const ServerCredentials(),
      AuthType.privateKey => ServerCredentials(
        privateKey: _privateKey.text,
        passphrase: _passphrase.text,
      ),
    };

    setState(() => _saving = true);
    try {
      await ref.read(serverListProvider.notifier).save(draft, credentials);
      if (mounted) {
        Navigator.of(context).pop();
      }
    } on VaultValidationException catch (error) {
      if (mounted) {
        setState(() => _errors = error.fieldErrors);
      }
    } on VaultException catch (error) {
      if (mounted) {
        _showMessage(error.message);
      }
    } catch (error) {
      // Anything the vault did not translate, such as a metadata store
      // failure. The form stays open so the user can retry.
      if (mounted) {
        _showMessage('Could not save the server. $error');
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}

/// Chooses a saved key, or "paste a key for this host only".
class _KeyPicker extends ConsumerWidget {
  const _KeyPicker({required this.keyId, required this.onChanged, this.error});

  final String? keyId;
  final ValueChanged<String?> onChanged;
  final String? error;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final keys = ref.watch(keyListProvider).asData?.value ?? const [];
    final known = keys.any((key) => key.id == keyId);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButtonFormField<String?>(
          key: ValueKey('key-picker-${keys.length}-$keyId'),
          initialValue: known ? keyId : null,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: 'Key',
            errorText:
                error ??
                (keyId != null && !known && keys.isNotEmpty
                    ? 'That saved key no longer exists. Pick another.'
                    : null),
          ),
          items: [
            for (final key in keys)
              DropdownMenuItem<String?>(
                value: key.id,
                child: Text(
                  '${key.name} · ${key.type}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            const DropdownMenuItem<String?>(
              value: null,
              child: Text('Paste a key for this host only'),
            ),
          ],
          onChanged: onChanged,
        ),
        if (keys.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 4),
            child: Text(
              'Generate or import keys in the Keys tab to reuse them here.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}
