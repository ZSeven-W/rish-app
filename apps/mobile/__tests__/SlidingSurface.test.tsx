import React from 'react';
import ReactTestRenderer, { act } from 'react-test-renderer';
import { Keyboard, Modal, Platform, Text } from 'react-native';

import { SlidingSurface } from '../src/components/SlidingSurface';

test('keeps navigation transitions out of React Native Modal', async () => {
  const onDismiss = jest.fn();
  let renderer: ReactTestRenderer.ReactTestRenderer | undefined;

  await act(async () => {
    renderer = ReactTestRenderer.create(
      <SlidingSurface
        closeAccessibilityLabel="Close surface"
        onClose={() => undefined}
        onDismiss={onDismiss}
        visible={false}
      >
        <Text>Settings surface</Text>
      </SlidingSurface>,
    );
  });

  expect(renderer!.root.findAllByType(Modal)).toHaveLength(0);
  expect(
    renderer!.root.findAllByProps({ children: 'Settings surface' }),
  ).toHaveLength(0);

  await act(async () => {
    renderer!.update(
      <SlidingSurface
        closeAccessibilityLabel="Close surface"
        onClose={() => undefined}
        onDismiss={onDismiss}
        visible
      >
        <Text>Settings surface</Text>
      </SlidingSurface>,
    );
  });
  expect(
    renderer!.root.findByProps({ children: 'Settings surface' }),
  ).toBeDefined();

  await act(async () => {
    renderer!.update(
      <SlidingSurface
        closeAccessibilityLabel="Close surface"
        onClose={() => undefined}
        onDismiss={onDismiss}
        visible={false}
      >
        <Text>Settings surface</Text>
      </SlidingSurface>,
    );
  });
  expect(onDismiss).toHaveBeenCalledTimes(1);
});

test('emits one presentation-complete event only after every open transition', async () => {
  const onPresented = jest.fn();
  const onDismiss = jest.fn();
  let renderer: ReactTestRenderer.ReactTestRenderer | undefined;
  const surface = (visible: boolean) => (
    <SlidingSurface
      closeAccessibilityLabel="Close surface"
      onClose={() => undefined}
      onDismiss={onDismiss}
      onPresented={onPresented}
      visible={visible}
    >
      <Text>Context surface</Text>
    </SlidingSurface>
  );

  await act(async () => {
    renderer = ReactTestRenderer.create(surface(true));
    expect(onPresented).not.toHaveBeenCalled();
  });
  expect(onPresented).toHaveBeenCalledTimes(1);

  await act(async () => {
    renderer!.update(surface(true));
  });
  expect(onPresented).toHaveBeenCalledTimes(1);

  await act(async () => {
    renderer!.update(surface(false));
  });
  expect(onDismiss).toHaveBeenCalledTimes(1);
  expect(onPresented).toHaveBeenCalledTimes(1);

  await act(async () => {
    renderer!.update(surface(true));
    expect(onPresented).toHaveBeenCalledTimes(1);
  });
  expect(onPresented).toHaveBeenCalledTimes(2);

  await act(async () => {
    renderer!.update(surface(false));
  });
  expect(onDismiss).toHaveBeenCalledTimes(2);
  expect(onPresented).toHaveBeenCalledTimes(2);
});

test('keeps a docked surface mounted when visible is false', async () => {
  let renderer: ReactTestRenderer.ReactTestRenderer | undefined;
  await act(async () => {
    renderer = ReactTestRenderer.create(
      <SlidingSurface
        closeAccessibilityLabel="Close navigation"
        docked
        onClose={() => undefined}
        visible={false}
        maxWidth={296}
      >
        <Text>Docked navigation</Text>
      </SlidingSurface>,
    );
  });
  expect(renderer!.root.findByProps({ children: 'Docked navigation' })).toBeDefined();
  expect(renderer!.root.findAllByType(Modal)).toHaveLength(0);
});

test('on Android the surface gives the keyboard its height so the bottom stays reachable', async () => {
  const platform = jest.replaceProperty(Platform, 'OS', 'android');
  const listeners = new Map<string, (event: { endCoordinates: { height: number } }) => void>();
  const addListener = jest.spyOn(Keyboard, 'addListener').mockImplementation(((name: string, listener: never) => {
    listeners.set(name, listener as never);
    return { remove: () => listeners.delete(name) };
  }) as never);
  let renderer: ReactTestRenderer.ReactTestRenderer | undefined;
  await act(async () => {
    renderer = ReactTestRenderer.create(
      <SlidingSurface closeAccessibilityLabel="Close surface" onClose={() => undefined} visible>
        <Text>Projects surface</Text>
      </SlidingSurface>,
    );
  });
  const container = () => renderer!.root.findByProps({ testID: 'sliding-surface-container' });
  const flat = (style: unknown): Record<string, unknown> =>
    Object.assign({}, ...(Array.isArray(style) ? style.flat(Infinity) : [style]).filter(Boolean));
  expect(flat(container().props.style).paddingBottom).toBeUndefined();
  await act(async () => { listeners.get('keyboardDidShow')?.({ endCoordinates: { height: 349 } }); });
  expect(flat(container().props.style).paddingBottom).toBe(349);
  await act(async () => { listeners.get('keyboardDidHide')?.({ endCoordinates: { height: 0 } }); });
  expect(flat(container().props.style).paddingBottom).toBeUndefined();
  await act(async () => { renderer!.unmount(); });
  expect(listeners.size).toBe(0);
  addListener.mockRestore();
  platform.restore();
});

test('on iOS the surface leaves the keyboard to the screen', async () => {
  const platform = jest.replaceProperty(Platform, 'OS', 'ios');
  const addListener = jest.spyOn(Keyboard, 'addListener');
  await act(async () => {
    ReactTestRenderer.create(
      <SlidingSurface closeAccessibilityLabel="Close surface" onClose={() => undefined} visible>
        <Text>Projects surface</Text>
      </SlidingSurface>,
    );
  });
  expect(addListener).not.toHaveBeenCalled();
  addListener.mockRestore();
  platform.restore();
});
