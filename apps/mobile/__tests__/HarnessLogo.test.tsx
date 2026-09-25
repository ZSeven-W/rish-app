import React from 'react';
import { StyleSheet, Text, View } from 'react-native';
import Svg, { LinearGradient, Path, Stop, SvgXml } from 'react-native-svg';
import ReactTestRenderer, {
  act,
  type ReactTestRenderer as Renderer,
} from 'react-test-renderer';

import { HarnessLogo } from '../src/components/HarnessLogo';
import { HarnessPicker } from '../src/components/HarnessPicker';
import { BUILTIN_HARNESSES } from '../src/harness';
import { AppPresentationProvider } from '../src/presentation/AppPresentation';
import {
  createDefaultPreferences,
  createPreferencesStore,
} from '../src/preferences';

jest.mock('react-native-safe-area-context', () => ({
  useSafeAreaInsets: () => ({ top: 0, right: 0, bottom: 0, left: 0 }),
}));

async function render(children: React.ReactElement): Promise<Renderer> {
  let renderer: Renderer | undefined;
  await act(async () => {
    renderer = ReactTestRenderer.create(children);
  });
  if (renderer === undefined) throw new Error('renderer was not created');
  return renderer;
}

test.each([
  ['dsh', 'DeepSeek', '#4D6BFE'],
  ['claude-code', 'Claude Code', '#D97757'],
])(
  'renders %s as a native SVG with its original brand fill',
  async (id, name, fill) => {
    const renderer = await render(<HarnessLogo harnessId={id} name={name} />);
    expect(renderer.root.findByType(Path).props.fill).toBe(fill);
    expect(renderer.root.findByType(Svg).props).toMatchObject({
      width: 30,
      height: 30,
      viewBox: '0 0 24 24',
      accessible: false,
      focusable: false,
    });
    expect(renderer.root.findByType(View).props).toMatchObject({
      accessible: false,
      accessibilityElementsHidden: true,
      importantForAccessibility: 'no-hide-descendants',
      pointerEvents: 'none',
    });
  },
);

test('renders the original Codex white backing and three-stop gradient', async () => {
  const renderer = await render(<HarnessLogo harnessId="codex" name="Codex" />);
  const paths = renderer.root.findAllByType(Path);
  expect(paths).toHaveLength(2);
  expect(paths[0].props.fill).toBe('#fff');
  expect(paths[1].props.fill).toBe('url(#lobe-icons-codex-_R_0_)');
  expect(renderer.root.findByType(LinearGradient).props).toMatchObject({
    id: 'lobe-icons-codex-_R_0_',
    gradientUnits: 'userSpaceOnUse',
    x1: 12,
    x2: 12,
    y1: 3,
    y2: 21,
  });
  expect(
    renderer.root.findAllByType(Stop).map(stop => stop.props.stopColor),
  ).toEqual(['#B1A7FF', '#7A9DFF', '#3941FF']);
});

test('resolves Z.ai currentColor to an explicit dark foreground', async () => {
  const renderer = await render(<HarnessLogo harnessId="glm" name="GLM" />);
  expect(renderer.root.findByType(Svg).props).toMatchObject({
    fill: '#242424',
    color: '#242424',
    fillRule: 'evenodd',
  });
});

test('keeps a monogram for custom manifests even when their name matches a brand', async () => {
  const renderer = await render(
    <HarnessLogo harnessId="custom" name="DeepSeek" />,
  );
  expect(renderer.root.findAllByType(SvgXml)).toHaveLength(0);
  expect(renderer.root.findByType(Text).props.children).toBe('DE');
  expect(
    StyleSheet.flatten(renderer.root.findByType(Text).props.style).color,
  ).toBe('#242424');
});

test.each(['light', 'dark'] as const)(
  'keeps all picker logo tiles readable and card behavior intact in %s mode',
  async theme => {
    const onSelect = jest.fn();
    const store = createPreferencesStore({
      initialPreferences: {
        ...createDefaultPreferences(),
        locale: 'en-US',
        themeMode: theme,
      },
    });
    const renderPicker = (disabled: boolean) => (
      <AppPresentationProvider store={store}>
        <HarnessPicker
          disabled={disabled}
          manifests={BUILTIN_HARNESSES.list()}
          onClose={jest.fn()}
          onSelect={onSelect}
          selectedId="glm"
          visible
        />
      </AppPresentationProvider>
    );
    const renderer = await render(renderPicker(false));
    const logos = renderer.root.findAllByType(HarnessLogo);
    expect(logos.map(logo => logo.props.harnessId)).toEqual([
      'dsh',
      'claude-code',
      'codex',
      'glm',
    ]);
    for (const logo of logos) {
      expect(StyleSheet.flatten(logo.parent?.props.style)).toMatchObject({
        width: 44,
        height: 44,
        borderRadius: 14,
        backgroundColor: '#F7F7F5',
      });
    }
    const cards = () =>
      BUILTIN_HARNESSES.list().map(manifest => {
        const card = renderer.root
          .findAllByProps({ accessibilityLabel: `Use ${manifest.name}` })
          .find(node => typeof node.props.onPress === 'function');
        if (card === undefined)
          throw new Error(`missing card for ${manifest.id}`);
        return card;
      });
    expect(cards()).toHaveLength(4);
    for (const [index, card] of cards().entries()) {
      const manifest = BUILTIN_HARNESSES.list()[index];
      expect(card.props.accessibilityRole).toBe('radio');
      expect(card.props.accessibilityLabel).toBe(`Use ${manifest.name}`);
      expect(card.props.accessibilityState).toEqual({
        checked: manifest.id === 'glm',
        disabled: false,
      });
      await act(async () => card.props.onPress());
      expect(onSelect).toHaveBeenLastCalledWith(manifest.id);
    }

    await act(async () => renderer.update(renderPicker(true)));
    for (const card of cards()) {
      expect(card.props.disabled).toBe(true);
      expect(card.props.accessibilityState.disabled).toBe(true);
    }
  },
);

// Tapping a card while a turn was unsettled did nothing and said nothing
// (beta report, 2026-09-24). The picker now says why, and the cards are
// inert with it.
test('the picker says why a switch is not possible', async () => {
  const onSelect = jest.fn();
  const store = createPreferencesStore({
    initialPreferences: { ...createDefaultPreferences(), locale: 'en-US' },
  });
  const notice = 'This chat has a turn that did not finish.';
  const renderer = await render(
    <AppPresentationProvider store={store}>
      <HarnessPicker
        disabled
        notice={notice}
        manifests={BUILTIN_HARNESSES.list()}
        onClose={jest.fn()}
        onSelect={onSelect}
        selectedId="glm"
        visible
      />
    </AppPresentationProvider>,
  );
  expect(renderer.root.findAll(node => node.props.accessibilityRole === 'alert' && node.props.children === notice).length).toBeGreaterThan(0);
  const card = renderer.root.findAll(node => node.props.accessibilityLabel === 'Use DSH' && typeof node.props.onPress === 'function')[0];
  expect(card.props.disabled).toBe(true);
});
