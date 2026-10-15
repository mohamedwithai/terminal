import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ssh_app/models/auth_type.dart';
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
    _loadingSecrets = true;
    _loadSecrets(server.id);
  }

  Future<void> _loadSecrets(String id) async {
    try {
      final credentials =
          await ref.read(vaultServiceProvider).readCredentials(id);
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
    return Scaffold(
      appBar: AppBar(
        title: Text(editing ? 'Edit server' : 'Add server'),
        actions: [
          TextButton(
            onPressed: _saving || _loadingSecrets ? null : _save,
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
                  onChanged: (_) => _clearError('host'),
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
                Text('Authentication', style: Theme.of(context).textTheme.titleSmall),
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
                        tooltip: _hidePassword ? 'Show password' : 'Hide password',
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
                      helperText: 'OpenSSH or PEM. RSA and Ed25519.',
                      errorText: _errors['privateKey'],
                      suffixIcon: IconButton(
                        tooltip: _hideKey ? 'Show private key' : 'Hide private key',
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
                      helperText: 'Leave empty when the key is not encrypted.',
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
            ),
    );
  }

  void _clearError(String field) {
    if (_errors.containsKey(field)) {
      setState(() => _errors.remove(field));
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
    final draft = ServerConfig.create(
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
    );
    errors.addAll(draft.fieldErrors);
    if (errors.isNotEmpty) {
      setState(() => _errors = errors);
      return;
    }

    final credentials = switch (_authType) {
      AuthType.password => ServerCredentials(password: _password.text),
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
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }
}
