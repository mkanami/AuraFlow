# macOS promotional image

`auraflow-four-wallpapers.png` is a 3420 × 2076 promotional collage made from real wallpaper media and AuraFlow terminal preview captures:

| Position | Source |
| --- | --- |
| Top left | Iuno Heart Rain, Wuthering Waves — local MoeWalls video frame |
| Top right | CMatrix — captured from AuraFlow's actual terminal preview |
| Bottom left | Asciiquarium — captured from AuraFlow's actual terminal preview |
| Bottom right | Summer Mountain Paradise — local MotionBGS video frame |

The four sources were cropped and resized into one background, opened in AuraFlow's preview, and captured with the app's single native speed control and playback panel. The capture cursor was removed by restoring the underlying source pixels. No AI image generation was used.

This artwork presents several supported wallpaper sources together; it is a promotional collage rather than a simultaneous four-wallpaper playback mode.

## Gold bonsai and sunset revision

`auraflow-four-wallpapers-gold-bonsai.png` keeps the same four-quadrant layout and one shared interface, replacing the aquarium and daytime landscape with these real sources:

- Bottom left: actual `cbonsai` PTY output, captured before ncurses exits its alternate screen and rasterized as terminal character cells. Command: `cbonsai -p -s 73 -M 8 -L 38 -b 1 -k 136,94,214,178`.
- Bottom right: [Sunset Reflections of the Matterhorn in the Alps](https://wall.alphacoders.com/big.php?i=720751), using the gallery's existing 2000 × 1333 photograph. The gallery lists this third-party photograph for private, personal use; its rights are separate from the project's source-code license.

The unchanged top half and the shared playback panel reuse pixels from real AuraFlow screenshots. The montage uses cropping, resizing, and compositing, with no AI image generation.

## Adaptive glass revision

`auraflow-four-wallpapers-adaptive-glass.png` keeps the same wallpapers and layout. Both controls use separate backdrop sampling on each side of the vertical seam: the speed control is light over the anime and dark over CMatrix, while the playback panel is dark over the bonsai and tinted by the sunset on the right. Native screenshot glyphs and control outlines are reused, with a single speed thumb and a single playback panel.

This is an image-only compositing adjustment. Verification checks that pixels outside the two control panels, image dimensions, and outer window transparency are unchanged.

## Clear lower-panel revision

`auraflow-four-wallpapers-clear-glass.png` retains the approved speed control pixel for pixel. The lower panel uses a clear refractive backdrop, a tight specular rim, and sharper native controls. Its terminal half retains the actual native dark controls; the photo half uses a light appearance with crisp dark lettering and individually defined transparent buttons.

Image checks verify that changes are limited to the lower panel and its shadow, preserving all wallpapers, their arrangement, and the outer window transparency.

## Native lower-panel capture

`auraflow-four-wallpapers-native-glass.png` replaces the reconstructed lower panel with an actual screenshot of AuraFlow's active window. The four-source montage was opened in the app's preview without applying it as wallpaper. The system Liquid Glass, its refraction, buttons, and lettering are captured pixels, with no material reconstruction, sharpening, or recoloring. The approved speed control and all pixels outside the lower-panel capture are retained exactly.

`auraflow-native-glass-detail.png` is an unaltered crop of the right side of that native window screenshot, showing the Change Wallpaper and Wallpaper Catalog controls over the Matterhorn photograph.

Pixel checks verify that the inserted panel matches the decoded screenshot exactly, the speed control is unchanged, and the full image retains its dimensions and outer transparency. The app's previous media preview was restored after capture; wallpaper playback and settings were not changed.
