import React, { useCallback, useEffect, useRef, useState } from 'react';
import {
  Animated,
  BackHandler,
  Easing,
  Keyboard,
  Platform,
  Pressable,
  StyleSheet,
  useWindowDimensions,
  View,
} from 'react-native';

type Props = React.PropsWithChildren<{
  accessibilityLabel?: string;
  accessibilityHidden?: boolean;
  closeAccessibilityLabel: string;
  side?: 'left' | 'right' | 'bottom';
  visible: boolean;
  widthRatio?: number;
  maxWidth?: number;
  scrim?: boolean;
  onClose: () => void;
  onDismiss?: () => void;
  onPresented?: () => void;
  docked?: boolean;
}>;

const disableAnimations = process.env.NODE_ENV === 'test';

/**
 * The keyboard's height on Android, and 0 elsewhere. The Android window
 * does not shrink for the keyboard here (edge-to-edge), so a surface that
 * fills the window keeps its full height and whatever sits under the
 * keyboard cannot be scrolled to. On iOS the screen's KeyboardAvoidingView
 * already pads the root the surface is laid over.
 */
function useKeyboardHeight(): number {
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

export function SlidingSurface({
  accessibilityLabel,
  accessibilityHidden = false,
  children,
  closeAccessibilityLabel,
  side = 'right',
  visible,
  widthRatio = 1,
  maxWidth = Number.POSITIVE_INFINITY,
  scrim = true,
  onClose,
  onDismiss,
  onPresented,
  docked = false,
}: Props) {
  const { width, height } = useWindowDimensions();
  const panelWidth = Math.min(width * widthRatio, maxWidth);
  const keyboardHeight = useKeyboardHeight();
  const progress = useRef(new Animated.Value(visible ? 1 : 0)).current;
  const presented = useRef(false);
  const onDismissRef = useRef(onDismiss);
  const onPresentedRef = useRef(onPresented);
  onDismissRef.current = onDismiss;
  onPresentedRef.current = onPresented;
  const [active, setActive] = useState(visible);

  const animateTo = useCallback(
    (value: 0 | 1, after?: () => void) => {
      progress.stopAnimation();
      if (disableAnimations) {
        progress.setValue(value);
        after?.();
        return;
      }
      Animated.timing(progress, {
        duration: value === 1 ? 210 : 175,
        easing:
          value === 1 ? Easing.out(Easing.cubic) : Easing.in(Easing.cubic),
        toValue: value,
        useNativeDriver: true,
      }).start(({ finished }) => {
        if (finished) after?.();
      });
    },
    [progress],
  );

  useEffect(() => {
    if (docked) return;
    if (visible) {
      if (presented.current) return;
      presented.current = true;
      setActive(true);
      if (disableAnimations) {
        animateTo(1, () => onPresentedRef.current?.());
        return;
      }
      const frame = requestAnimationFrame(() =>
        animateTo(1, () => onPresentedRef.current?.()),
      );
      return () => cancelAnimationFrame(frame);
    }
    if (!presented.current) return;
    presented.current = false;
    animateTo(0, () => {
      setActive(false);
      onDismissRef.current?.();
    });
  }, [animateTo, docked, visible]);

  useEffect(() => {
    if (docked) return;
    if (!visible) return;
    const subscription = BackHandler.addEventListener(
      'hardwareBackPress',
      () => {
        onClose();
        return true;
      },
    );
    return () => subscription.remove();
  }, [docked, onClose, visible]);

  useEffect(() => () => progress.stopAnimation(), [progress]);

  if (docked) {
    return (
      <View style={[styles.dockedContainer, { width: maxWidth }]}>
        {children}
      </View>
    );
  }

  const translateX = progress.interpolate({
    inputRange: [0, 1],
    outputRange: [side === 'left' ? -panelWidth : panelWidth, 0],
  });
  const translateY = progress.interpolate({
    inputRange: [0, 1],
    outputRange: [height, 0],
  });
  const transform = side === 'bottom' ? [{ translateY }] : [{ translateX }];

  const scrimView = (
    <Animated.View
      accessibilityElementsHidden={accessibilityHidden}
      importantForAccessibility={
        accessibilityHidden ? 'no-hide-descendants' : 'yes'
      }
      style={[styles.scrimWrap, { opacity: progress }]}
    >
      <Pressable
        accessibilityLabel={closeAccessibilityLabel}
        accessibilityRole="button"
        onPress={onClose}
        style={styles.scrim}
      />
    </Animated.View>
  );

  return (
    <View
      pointerEvents={active ? 'auto' : 'none'}
      style={[styles.container, keyboardHeight > 0 && { paddingBottom: keyboardHeight }]}
      testID="sliding-surface-container"
    >
      <View style={styles.row}>
        {side === 'right' && scrim && scrimView}
        <Animated.View
          accessibilityLabel={accessibilityLabel}
          accessibilityElementsHidden={!visible || accessibilityHidden}
          accessibilityViewIsModal={visible}
          importantForAccessibility={
            visible && !accessibilityHidden ? 'yes' : 'no-hide-descendants'
          }
          style={[styles.panel, { width: panelWidth, transform }]}
        >
          {!disableAnimations || active ? children : null}
        </Animated.View>
        {side === 'left' && scrim && scrimView}
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    position: 'absolute',
    top: 0,
    right: 0,
    bottom: 0,
    left: 0,
    zIndex: 100,
    elevation: 100,
  },
  row: { flex: 1, flexDirection: 'row' },
  panel: { height: '100%' },
  scrimWrap: { flex: 1 },
  scrim: { flex: 1, backgroundColor: 'rgba(0,0,0,0.54)' },
  dockedContainer: {
    position: 'absolute',
    top: 0,
    bottom: 0,
    left: 0,
    zIndex: 100,
  },
});
