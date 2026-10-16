import 'package:flutter/material.dart';
import 'package:ssh_app/models/server_config.dart';
import 'package:ssh_app/theme/tokens.dart';

/// The host's first letter on its own color, with an optional status dot.
class HostAvatar extends StatelessWidget {
  const HostAvatar({super.key, required this.server, this.dotColor});

  final ServerConfig server;

  /// Shows a status dot in the corner, for example green while connected.
  final Color? dotColor;

  @override
  Widget build(BuildContext context) {
    final label = server.label.trim();
    final letter = label.isEmpty ? '?' : label.characters.first.toUpperCase();
    final avatar = Container(
      width: AppSizes.avatar,
      height: AppSizes.avatar,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.avatarColorFor(server.id),
        borderRadius: BorderRadius.circular(AppSizes.avatarRadius),
      ),
      child: Text(
        letter,
        style: const TextStyle(
          fontFamily: AppFonts.ui,
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: AppColors.background,
        ),
      ),
    );
    final dot = dotColor;
    if (dot == null) {
      return avatar;
    }
    return Stack(
      clipBehavior: Clip.none,
      children: [
        avatar,
        Positioned(
          right: -3,
          bottom: -3,
          child: Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              color: dot,
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.surface, width: 2.5),
            ),
          ),
        ),
      ],
    );
  }
}

/// A small filled circle, for connection states.
class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.color, this.size = 8});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}
