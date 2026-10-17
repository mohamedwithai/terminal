import 'dart:convert';

/// Appended to `~/.bashrc` or `~/.zshrc`. Makes the shell mark where its
/// prompt starts and ends (OSC 133), how the last command ended, and the
/// current directory (OSC 7), which the app uses to know what is being typed.
const shellIntegrationScript = r'''
# ssh_app_integration: prompt and directory marks for the SSH app
if [ -z "$__SSH_APP_INTEGRATION" ]; then
  __SSH_APP_INTEGRATION=1
  if [ -n "$ZSH_VERSION" ]; then
    __ssh_app_precmd() { printf '\033]133;D;%s\007\033]7;file://%s%s\007\033]133;A\007' "$?" "${HOST:-$HOSTNAME}" "${PWD// /%20}"; }
    autoload -Uz add-zsh-hook 2>/dev/null && add-zsh-hook precmd __ssh_app_precmd
    PS1="${PS1}%{"$'\033]133;B\007'"%}"
  elif [ -n "$BASH_VERSION" ]; then
    __ssh_app_precmd() { local ec=$?; printf '\033]133;D;%s\007\033]7;file://%s%s\007\033]133;A\007' "$ec" "$HOSTNAME" "${PWD// /%20}"; return $ec; }
    PROMPT_COMMAND="__ssh_app_precmd${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
    PS1="${PS1}\[\033]133;B\007\]"
  fi
fi
''';

/// The marker line `grep` looks for, so the script is added once.
const shellIntegrationMarker = 'ssh_app_integration';

/// One line to type into a shell that appends [shellIntegrationScript] to
/// the right rc file, once. Base64 keeps quotes and newlines out of the way.
String shellIntegrationInstallCommand() {
  final encoded = base64.encode(utf8.encode(shellIntegrationScript));
  return 'rc=~/.bashrc; [ -n "\$ZSH_VERSION" ] && rc=~/.zshrc; '
      'grep -q $shellIntegrationMarker "\$rc" 2>/dev/null '
      '&& echo "Shell integration is already in \$rc" '
      '|| { echo $encoded | base64 -d >> "\$rc" '
      '&& echo "Shell integration added to \$rc. Open a new shell to use it."; }';
}
