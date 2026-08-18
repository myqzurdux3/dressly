import 'dart:io';

import 'package:flutter/material.dart';

/// A tappable tile showing a picked image, or a placeholder prompting to pick.
class ImageSlot extends StatelessWidget {
  const ImageSlot({
    super.key,
    required this.label,
    this.path,
    required this.onTap,
    this.required = false,
    this.width = 140,
    this.height = 180,
  });

  final String label;
  final String? path;
  final VoidCallback onTap;
  final bool required;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: Colors.grey[900],
          border: Border.all(color: Colors.grey[700]!),
          borderRadius: BorderRadius.circular(12),
        ),
        child: path == null
            ? Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.add_a_photo, size: 36, color: Colors.grey),
                  const SizedBox(height: 8),
                  Text(label, style: const TextStyle(color: Colors.grey)),
                  if (required)
                    const Text('*', style: TextStyle(color: Colors.redAccent)),
                ],
              )
            : Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(11),
                    // Decode at tile size: a camera capture is ~12 MP, which
                    // would otherwise sit in memory in full for a 140 px box.
                    child: Image.file(File(path!), fit: BoxFit.cover,
                        width: width, height: height,
                        cacheWidth: (width *
                                (MediaQuery.maybeOf(context)
                                        ?.devicePixelRatio ??
                                    1.0))
                            .round()),
                  ),
                  Positioned(
                    top: 4,
                    right: 4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(label,
                          style: const TextStyle(
                              fontSize: 12, color: Colors.white)),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}