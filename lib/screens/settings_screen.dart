import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ssh_app/models/app_settings.dart';
import 'package:ssh_app/providers/preferences_providers.dart';
import 'package:ssh_app/theme/terminal_themes.dart';
import 'package:ssh_app/theme/tokens.dart';
import 'package:xterm/xterm.dart';

/// Terminal look and feel, key bar options, and security.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    final notifier = ref.read(appSettingsProvider.notifier);
    final perHost = settings.hostFontSizes.length;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          TerminalPreview(settings: settings),
          const _Header('Theme'),
          SizedBox(
            height: 132,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: TerminalThemeId.values.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (context, index) {
                final id = TerminalThemeId.values[index];
                return _ThemeCard(
                  id: id,
                  selected: id == settings.terminalTheme,
                  onTap: () => notifier.update(
                    (current) => current.copyWith(terminalTheme: id),
                  ),
                );
              },
            ),
          ),
          const _Header('Font'),
          _Segments<TerminalFont>(
            values: TerminalFont.values,
            selected: settings.font,
            label: (font) => font.label,
            onChanged: (font) =>
                notifier.update((current) => current.copyWith(font: font)),
          ),
          _Header('Text size · ${settings.fontSize.round()}'),
          Slider(
            value: settings.fontSize,
            min: AppSettings.minFontSize,
            max: AppSettings.maxFontSize,
            divisions: (AppSettings.maxFontSize - AppSettings.minFontSize)
                .round(),
            label: '${settings.fontSize.round()}',
            onChanged: (size) =>
                notifier.update((current) => current.copyWith(fontSize: size)),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Pinch in a terminal to change the size for that host '
                    'only; it is remembered.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                if (perHost > 0)
                  TextButton(
                    onPressed: () => notifier.update(
                      (current) => current.copyWith(hostFontSizes: const {}),
                    ),
                    child: Text(
                      perHost == 1 ? 'Reset 1 host' : 'Reset $perHost hosts',
                    ),
                  ),
              ],
            ),
          ),
          const _Header('Cursor'),
          _Segments<CursorShape>(
            values: CursorShape.values,
            selected: settings.cursor,
            label: (cursor) => cursor.label,
            onChanged: (cursor) =>
                notifier.update((current) => current.copyWith(cursor: cursor)),
          ),
          const _Header('Key bar'),
          _Segments<KeyBarLayout>(
            values: KeyBarLayout.values,
            selected: settings.keyBar,
            label: (layout) => layout.label,
            onChanged: (layout) =>
                notifier.update((current) => current.copyWith(keyBar: layout)),
          ),
          const SizedBox(height: 8),
          _SwitchCard(
            children: [
              SwitchListTile(
                title: const Text('Volume keys'),
                subtitle: const Text('Volume down is CTRL, volume up is ↑'),
                value: settings.volumeKeys,
                onChanged: (on) => notifier.update(
                  (current) => current.copyWith(volumeKeys: on),
                ),
              ),
              const Divider(),
              SwitchListTile(
                title: const Text('Haptic feedback'),
                subtitle: const Text('A light tap on every key'),
                value: settings.haptics,
                onChanged: (on) =>
                    notifier.update((current) => current.copyWith(haptics: on)),
              ),
            ],
          ),
          const _Header('Security'),
          const _SwitchCard(
            children: [
              SwitchListTile(
                title: Text('App lock'),
                subtitle: Text('Fingerprint, face or PIN. Coming soon.'),
                value: false,
                onChanged: null,
              ),
              Divider(),
              ListTile(
                enabled: false,
                title: Text('Lock after'),
                trailing: Text('Immediately'),
              ),
            ],
          ),
          const _Header('About'),
          _SwitchCard(
            children: [
              ListTile(
                title: const Text('Open source licenses'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () =>
                    showLicensePage(context: context, applicationName: 'SSH'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A few lines of shell output in the chosen theme, font, size and cursor.
class TerminalPreview extends StatelessWidget {
  const TerminalPreview({super.key, required this.settings, this.height});

  final AppSettings settings;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final theme = settings.terminalTheme.theme;
    final style = TextStyle(
      fontFamily: settings.font.fontFamily,
      fontFamilyFallback: AppFonts.fallback,
      fontSize: settings.fontSize,
      height: 1.25,
      color: theme.foreground,
    );
    return Container(
      height: height,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.background,
        borderRadius: BorderRadius.circular(AppRadii.card),
        border: Border.all(color: AppColors.border),
      ),
      child: ClipRect(
        child: DefaultTextStyle(
          style: style,
          maxLines: 1,
          overflow: TextOverflow.clip,
          softWrap: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _line(theme, [
                ('ada@build', theme.green),
                (':', theme.foreground),
                ('~/app', theme.blue),
                (r'$ ', theme.foreground),
                ('ls', theme.foreground),
              ]),
              _line(theme, [
                ('src  ', theme.blue),
                ('build.sh  ', theme.green),
                ('README.md', theme.foreground),
              ]),
              _line(theme, [
                ('error: ', theme.red),
                ('3 warnings', theme.yellow),
              ]),
              Row(
                children: [
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: 'ada@build',
                          style: TextStyle(color: theme.green),
                        ),
                        TextSpan(
                          text: ':',
                          style: TextStyle(color: theme.foreground),
                        ),
                        TextSpan(
                          text: '~/app',
                          style: TextStyle(color: theme.blue),
                        ),
                        TextSpan(
                          text: r'$ ',
                          style: TextStyle(color: theme.foreground),
                        ),
                      ],
                    ),
                  ),
                  _Cursor(
                    style: settings.cursor,
                    color: theme.cursor,
                    fontSize: settings.fontSize,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _line(TerminalTheme theme, List<(String, Color)> parts) {
    return Text.rich(
      TextSpan(
        children: [
          for (final (text, color) in parts)
            TextSpan(
              text: text,
              style: TextStyle(color: color),
            ),
        ],
      ),
    );
  }
}

class _Cursor extends StatelessWidget {
  const _Cursor({
    required this.style,
    required this.color,
    required this.fontSize,
  });

  final CursorShape style;
  final Color color;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final width = fontSize * 0.6;
    final height = fontSize * 1.2;
    return SizedBox(
      width: width,
      height: height,
      child: Align(
        alignment: switch (style) {
          CursorShape.block => Alignment.center,
          CursorShape.bar => Alignment.centerLeft,
          CursorShape.line => Alignment.bottomCenter,
        },
        child: Container(
          width: style == CursorShape.bar ? 2 : width,
          height: style == CursorShape.line ? 2 : height,
          color: color,
        ),
      ),
    );
  }
}

class _ThemeCard extends StatelessWidget {
  const _ThemeCard({
    required this.id,
    required this.selected,
    required this.onTap,
  });

  final TerminalThemeId id;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = id.theme;
    const mono = TextStyle(
      fontFamily: AppFonts.mono,
      fontSize: 11,
      height: 1.3,
    );
    return Semantics(
      selected: selected,
      button: true,
      label: '${id.label} theme',
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 140,
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(AppRadii.card),
            border: Border.all(
              color: selected ? AppColors.accent : AppColors.border,
              width: selected ? 2 : 1,
            ),
          ),
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: theme.background,
                    borderRadius: BorderRadius.circular(AppRadii.key),
                  ),
                  child: Text.rich(
                    TextSpan(
                      style: mono.copyWith(color: theme.foreground),
                      children: [
                        TextSpan(
                          text: r'$ ',
                          style: TextStyle(color: theme.green),
                        ),
                        const TextSpan(text: 'git status\n'),
                        TextSpan(
                          text: 'modified',
                          style: TextStyle(color: theme.red),
                        ),
                        const TextSpan(text: ' app\n'),
                        TextSpan(
                          text: 'main',
                          style: TextStyle(color: theme.blue),
                        ),
                        TextSpan(
                          text: ' +2',
                          style: TextStyle(color: theme.yellow),
                        ),
                      ],
                    ),
                    maxLines: 3,
                    overflow: TextOverflow.clip,
                    softWrap: false,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      id.label,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: selected ? AppColors.accent : AppColors.text,
                      ),
                    ),
                  ),
                  if (selected)
                    const Icon(
                      Icons.check_circle,
                      size: 18,
                      color: AppColors.accent,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Segments<T> extends StatelessWidget {
  const _Segments({
    required this.values,
    required this.selected,
    required this.label,
    required this.onChanged,
  });

  final List<T> values;
  final T selected;
  final String Function(T value) label;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: SegmentedButton<T>(
        showSelectedIcon: false,
        segments: [
          for (final value in values)
            ButtonSegment(value: value, label: Text(label(value))),
        ],
        selected: {selected},
        onSelectionChanged: (selection) => onChanged(selection.first),
      ),
    );
  }
}

class _SwitchCard extends StatelessWidget {
  const _SwitchCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(children: children),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 20, 4, 10),
      child: Text(
        title.toUpperCase(),
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: AppColors.muted,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}
