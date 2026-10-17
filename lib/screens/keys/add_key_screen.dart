import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ssh_app/providers/vault_providers.dart';
import 'package:ssh_app/screens/keys/key_detail_screen.dart';
import 'package:ssh_app/services/ssh_key_material.dart';
import 'package:ssh_app/services/vault_exception.dart';
import 'package:ssh_app/theme/tokens.dart';

enum KeyAddMode { generate, generateRsa, paste, file }

/// Generates a key, or imports one by pasting it or reading a file.
class AddKeyScreen extends ConsumerStatefulWidget {
  const AddKeyScreen({super.key, required this.mode});

  final KeyAddMode mode;

  @override
  ConsumerState<AddKeyScreen> createState() => _AddKeyScreenState();
}

class _AddKeyScreenState extends ConsumerState<AddKeyScreen> {
  final _name = TextEditingController();
  final _privateKey = TextEditingController();
  final _passphrase = TextEditingController();
  final _confirm = TextEditingController();

  late var _algorithm = widget.mode == KeyAddMode.generateRsa
      ? KeyAlgorithm.rsa4096
      : KeyAlgorithm.ed25519;
  var _hidePassphrase = true;
  var _working = false;
  Map<String, String> _errors = {};

  bool get _generating =>
      widget.mode == KeyAddMode.generate ||
      widget.mode == KeyAddMode.generateRsa;

  @override
  void initState() {
    super.initState();
    if (widget.mode == KeyAddMode.file) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _chooseFile());
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _privateKey.dispose();
    _passphrase.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _message(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (!mounted) return;
    if (text == null || text.isEmpty) {
      _message('The clipboard is empty.');
      return;
    }
    setState(() {
      _privateKey.text = text;
      _errors.remove('privateKey');
    });
  }

  Future<void> _chooseFile() async {
    try {
      final text = await ref.read(keyFilePickerProvider)();
      if (!mounted || text == null) return;
      setState(() {
        _privateKey.text = text;
        _errors.remove('privateKey');
      });
    } on FormatException catch (error) {
      if (mounted) setState(() => _errors = {'privateKey': error.message});
    } catch (error) {
      if (mounted) _message('Could not read the file. $error');
    }
  }

  String get _defaultName {
    final base = _generating ? 'My ${_algorithm.label} key' : 'Imported key';
    return base;
  }

  Future<void> _submit() async {
    final name = _name.text.trim().isEmpty ? _defaultName : _name.text.trim();
    final passphrase = _passphrase.text;
    final errors = <String, String>{};
    if (_generating && passphrase != _confirm.text) {
      errors['confirm'] = 'The passphrases do not match.';
    }
    if (!_generating && _privateKey.text.trim().isEmpty) {
      errors['privateKey'] = 'Paste a private key or choose a file.';
    }
    if (errors.isNotEmpty) {
      setState(() => _errors = errors);
      return;
    }

    setState(() {
      _working = true;
      _errors = {};
    });
    try {
      final String pem;
      final KeyInfo info;
      if (_generating) {
        final key = await generateKeyInBackground(
          _algorithm,
          passphrase: passphrase,
          comment: name,
        );
        pem = key.privateKey;
        info = key.info;
      } else {
        pem = _privateKey.text.trim();
        info = await inspectPrivateKeyInBackground(
          pem,
          passphrase,
          comment: name,
        );
      }
      final record = await ref
          .read(keyListProvider.notifier)
          .add(
            name: name,
            privateKey: pem,
            passphrase: passphrase.isEmpty ? null : passphrase,
            info: info,
          );
      if (!mounted) return;
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => KeyDetailScreen(keyId: record.id, justCreated: true),
        ),
      );
    } on FormatException catch (error) {
      if (mounted) {
        setState(() {
          _errors = {
            error.message.contains('passphrase') ||
                        error.message.contains('encrypted')
                    ? 'passphrase'
                    : 'privateKey':
                error.message,
          };
        });
      }
    } on VaultValidationException catch (error) {
      if (mounted) setState(() => _errors = error.fieldErrors);
    } on VaultException catch (error) {
      if (mounted) _message(error.message);
    } catch (error) {
      if (mounted) _message('Could not save the key. $error');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canSave = ref.watch(secureStorageAvailableProvider);
    return Scaffold(
      appBar: AppBar(title: Text(_generating ? 'Generate key' : 'Import key')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          TextField(
            controller: _name,
            enabled: !_working,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              labelText: 'Name',
              hintText: _defaultName,
              errorText: _errors['name'],
            ),
          ),
          const SizedBox(height: 16),
          if (_generating) ...[
            SegmentedButton<KeyAlgorithm>(
              showSelectedIcon: false,
              segments: [
                for (final algorithm in KeyAlgorithm.values)
                  ButtonSegment(value: algorithm, label: Text(algorithm.label)),
              ],
              selected: {_algorithm},
              onSelectionChanged: _working
                  ? null
                  : (selection) => setState(() => _algorithm = selection.first),
            ),
            const SizedBox(height: 8),
            Text(
              _algorithm == KeyAlgorithm.ed25519
                  ? 'Ed25519 is the best choice for any recent server.'
                  : 'RSA 4096 works with old servers. Generating it can take up '
                        'to a minute on a phone.',
              style: theme.textTheme.bodySmall,
            ),
          ] else ...[
            TextField(
              controller: _privateKey,
              enabled: !_working,
              minLines: 5,
              maxLines: 8,
              autocorrect: false,
              enableSuggestions: false,
              style: const TextStyle(fontFamily: AppFonts.mono, fontSize: 12),
              decoration: InputDecoration(
                labelText: 'Private key',
                alignLabelWithHint: true,
                helperText: 'OpenSSH or PEM. RSA, Ed25519 and ECDSA.',
                errorText: _errors['privateKey'],
              ),
              onChanged: (_) => setState(() => _errors.remove('privateKey')),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _working ? null : _paste,
                  icon: const Icon(Icons.content_paste),
                  label: const Text('Paste'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _working ? null : _chooseFile,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Choose file'),
                ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          TextField(
            controller: _passphrase,
            enabled: !_working,
            obscureText: _hidePassphrase,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: _generating ? 'Passphrase (optional)' : 'Passphrase',
              helperText: _generating
                  ? 'Encrypts the private key. You will need it to connect.'
                  : 'Only if the key is encrypted.',
              errorText: _errors['passphrase'],
              suffixIcon: IconButton(
                tooltip: _hidePassphrase
                    ? 'Show passphrase'
                    : 'Hide passphrase',
                icon: Icon(
                  _hidePassphrase
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
                onPressed: () =>
                    setState(() => _hidePassphrase = !_hidePassphrase),
              ),
            ),
            onChanged: (_) => setState(() => _errors.remove('passphrase')),
          ),
          if (_generating) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _confirm,
              enabled: !_working,
              obscureText: _hidePassphrase,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'Confirm passphrase',
                errorText: _errors['confirm'],
              ),
              onChanged: (_) => setState(() => _errors.remove('confirm')),
            ),
          ],
          const SizedBox(height: 24),
          if (_working) ...[
            const LinearProgressIndicator(),
            const SizedBox(height: 8),
            Text(
              _generating ? 'Generating...' : 'Checking the key...',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ] else
            FilledButton(
              onPressed: canSave ? _submit : null,
              child: Text(_generating ? 'Generate' : 'Import'),
            ),
          if (!canSave)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Secure storage needs HTTPS. Saving is disabled.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppColors.error,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
