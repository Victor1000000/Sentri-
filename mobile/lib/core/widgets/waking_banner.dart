import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

/// A slim notice at the top of the screen while the app waits for the server to wake up.
/// Shown only while it is waiting, so people know the delay is not a fault.
class WakingBanner extends StatelessWidget {
  const WakingBanner({super.key, required this.waking, required this.message});
  final ValueListenable<bool> waking;
  final String message;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: waking,
      builder: (context, on, _) {
        if (!on) return const SizedBox.shrink();
        return SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Material(
              color: const Color(0xFF14134A),
              elevation: 4,
              borderRadius: BorderRadius.circular(14),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Row(
                  children: [
                    const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
                    const SizedBox(width: 12),
                    Expanded(child: Text(message, style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.3))),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
