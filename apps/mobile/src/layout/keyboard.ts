import { useEffect, useState } from 'react';
import { Keyboard, Platform } from 'react-native';

/**
 * The on-screen keyboard's height, or zero, on Android only.
 *
 * React Native 0.87 draws Android edge to edge, so `adjustResize` no longer
 * shrinks the window when the keyboard opens: the window stays full height
 * and whatever sits at the bottom -- a composer, a sheet's buttons -- is
 * simply covered. `KeyboardAvoidingView` cannot help, because it works from
 * the window frame that no longer changes. The height the keyboard reports
 * is measured from the bottom of the screen and already covers the
 * navigation bar, so a view that pads by it sits exactly above the keyboard
 * and must not add the bottom safe-area inset on top.
 *
 * iOS keeps its own `KeyboardAvoidingView` behaviour and gets zero here.
 */
export function useKeyboardHeight(): number {
  const [height, setHeight] = useState(0);
  useEffect(() => {
    if (Platform.OS !== 'android') return;
    const show = Keyboard.addListener('keyboardDidShow', event => {
      setHeight(Math.max(0, event.endCoordinates?.height ?? 0));
    });
    const hide = Keyboard.addListener('keyboardDidHide', () => setHeight(0));
    return () => {
      show.remove();
      hide.remove();
    };
  }, []);
  return height;
}
